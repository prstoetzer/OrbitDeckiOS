import SwiftUI
import CoreLocation

private struct FleetPass: Identifiable, Sendable {
    let id: UInt
    let name: String
    let pass: PredictedPass
}

/// A reference-type memo for the Home sky-track arc, held in `@State` so it
/// persists across renders. Mutating its fields does not invalidate the view
/// (that's intentional — the live TimelineView already re-renders each second),
/// so it's a safe render-time cache that avoids recomputing the arc every tick.
private final class TrackArcCache {
    var key = ""
    var arc: [SkyPoint] = []
    var pass: PredictedPass?
}

struct HomeView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var nextPass: PredictedPass?
    @State private var passError: String?
    @State private var fleetPasses: [FleetPass] = []
    @State private var fleetLoading = false
    // The sky-track arc and its pass are memoized inline by the live TimelineView
    // (see resolveTrack) rather than loaded via a `.task`. On this device a `.task`
    // can be cancelled by the split-view navigation transition, which left the arc
    // empty (the satellite dot still drew, from the inline look, but the polar path
    // did not). Computing it in the reliably-firing TimelineView fixes that.
    @State private var arcCache = TrackArcCache()
    @StateObject private var location = LocationProvider()
    // Persist the sky-plot orientation choice (north-up vs compass-up) until the
    // operator changes it.
    @AppStorage("homeCompassUp") private var compassUp = false
    // A fixed schedule anchor so frequent re-renders (e.g. compass heading updates)
    // don't re-anchor the periodic TimelineView to "now" and fire it faster than
    // once per second.
    @State private var clockAnchor = Date()
    @State private var selectedTransponderID: String?
    // Offset (Hz) from the transponder center for the passband tuning slider on a
    // linear bird; 0 = center (the default). Reset whenever the satellite or
    // transponder changes.
    @State private var passbandOffsetHz: Double = 0
    // Whether the unobtrusive per-satellite calibration sliders are expanded.
    @State private var showCalibration = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SelectedSatelliteHeader()

                if let satellite = store.selectedSatellite {
                    liveTrack(satellite)
                    transponderCard(satellite)
                    HomeRigControlCard(satellite: satellite,
                                       selectedTransponderID: selectedTransponder(satellite)?.id,
                                       passbandOffsetHz: $passbandOffsetHz)
                    HomeRotatorCard(satellite: satellite)
                    HomeQuickLogCard(satellite: satellite)
                    HomeRemoteAudioCard(satellite: satellite)
                    HomeRecordingCard(satellite: satellite)
                    HomeSSTVCard(satellite: satellite)
                    HomeFT4Card(satellite: satellite)
                    HomeAmsatQuickReport(satellite: satellite)
                }

                fleetDashboard

                if let satellite = store.selectedSatellite {
                    SectionCard("Station") {
                        MetricRow("Name", store.preferences.observer.name)
                        MetricRow(
                            "Coordinates",
                            String(
                                format: "%.5f°, %.5f°",
                                store.preferences.observer.latitude,
                                store.preferences.observer.longitude
                            )
                        )
                        MetricRow("Grid", store.operatorGrid6)
                        let vucc = store.operatorVuccGrids
                        if vucc.count > 1 {
                            MetricRow(
                                vucc.count >= 4 ? "On grid corner — VUCC grids" : "On grid line — VUCC grids",
                                vucc.joined(separator: ", "),
                                valueColor: ODTheme.good
                            )
                        }
                        // In current-location mode, annotate with the reverse-geocoded
                        // DXCC entity and administrative subdivisions.
                        CurrentLocationEntityInfo { info in
                            MetricRow("DXCC", info.dxccLabel ?? "—", valueColor: ODTheme.good)
                            if let primary = info.primarySubdivision {
                                MetricRow("Primary subdivision", primary)
                            }
                            if let secondary = info.secondarySubdivision {
                                MetricRow("Secondary subdivision", secondary)
                            }
                        }
                        MetricRow("Altitude", String(format: "%.0f m", store.preferences.observer.altitudeMeters))
                        MetricRow("Minimum elevation", ODFormat.angle(store.preferences.minElevation))
                    }

                    SectionCard("Next qualifying pass") {
                        if let pass = nextPass {
                            MetricRow("AOS", ODFormat.utc.string(from: pass.aos), valueColor: ODTheme.good)
                            MetricRow("TCA", ODFormat.utc.string(from: pass.tca))
                            MetricRow("LOS", ODFormat.utc.string(from: pass.los), valueColor: ODTheme.warning)
                            MetricRow("Maximum elevation", ODFormat.angle(pass.maxElevation, decimals: 1))
                            MetricRow(
                                "AOS → LOS",
                                "\(ODFormat.compass(pass.aosAzimuth)) \(ODFormat.angle(pass.aosAzimuth, decimals: 0)) → \(ODFormat.compass(pass.losAzimuth)) \(ODFormat.angle(pass.losAzimuth, decimals: 0))"
                            )
                            if pass.aos > Date() {
                                HStack {
                                    Spacer()
                                    PassAlarmButton(satellite: satellite, pass: pass,
                                                    observer: store.preferences.observer,
                                                    leadMinutes: store.preferences.passAlarmLeadMinutes ?? 10)
                                }
                            }
                        } else if let passError {
                            Text(passError)
                                .foregroundStyle(ODTheme.warning)
                        } else {
                            ProgressView()
                        }
                    }

                    SectionCard("Elements") {
                        MetricRow("NORAD", "\(satellite.id)")
                        MetricRow("International", satellite.internationalDesignator.isEmpty ? "—" : satellite.internationalDesignator)
                        MetricRow("Epoch", ODFormat.utc.string(from: satellite.epoch))
                        MetricRow("Period", String(format: "%.2f min", satellite.periodMinutes))
                        MetricRow("Inclination", ODFormat.angle(satellite.inclinationDeg, decimals: 3))
                        MetricRow("Perigee", String(format: "%.0f km", satellite.perigeeKm))
                        MetricRow("Apogee", String(format: "%.0f km", satellite.apogeeKm))
                    }
                } else {
                    LoadingOrError(
                        isLoading: store.isRefreshingGP,
                        error: store.lastError,
                        emptyText: "No satellite catalog"
                    )
                }
            }
            .padding(.bottom, 24)
        }
        .task { await store.refreshSpaceWeatherIfNeeded() }
        .task(id: passTaskKey) {
            await loadNextPass()
        }
        .task(id: fleetKey) {
            await loadFleet()
        }
        .onAppear { if compassUp { location.startHeading() } }
        .onDisappear { location.stopHeading() }
        .onChange(of: store.preferences.selectedNorad) { _, _ in
            selectedTransponderID = nil
            passbandOffsetHz = 0
        }
        .onChange(of: selectedTransponderID) { _, _ in passbandOffsetHz = 0 }
    }

    @ViewBuilder
    private var fleetDashboard: some View {
        let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
        if !favorites.isEmpty {
            if let wx = store.spaceWeather {
                SectionCard("Space weather") {
                    MetricRow("Solar flux (SFI)", wx.flux.map { String(format: "%.0f · \(wx.fluxLabel)", $0) } ?? "—")
                    MetricRow("Planetary Kp", wx.kp.map { String(format: "%.1f · \(wx.kpLabel)", $0) } ?? "—")
                }
            }
            TimelineView(.periodic(from: clockAnchor, by: 5)) { context in
                let overhead = overheadNow(favorites: favorites, at: context.date)
                SectionCard("Overhead now (\(overhead.count))") {
                    if overhead.isEmpty {
                        Text("No favorites above the horizon right now.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    } else {
                        ForEach(overhead, id: \.0.id) { entry in
                            Button { store.select(entry.0.id) } label: {
                                HStack {
                                    Text(entry.0.name)
                                        .foregroundStyle(entry.0.id == store.selectedSatellite?.id ? ODTheme.accent : .primary)
                                    Spacer()
                                    Text("el \(ODFormat.angle(entry.1.elevation)) · \(ODFormat.compass(entry.1.azimuth))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            SectionCard("Upcoming favorite passes") {
                if fleetPasses.isEmpty {
                    Text(fleetLoading ? "Computing…" : "No upcoming favorite passes above \(ODFormat.angle(store.preferences.minElevation)).")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                } else {
                    ForEach(fleetPasses.prefix(12)) { fleet in
                        HStack(spacing: 8) {
                            Button { store.select(fleet.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fleet.name)
                                            .foregroundStyle(fleet.id == store.selectedSatellite?.id ? ODTheme.accent : .primary)
                                        Text("AOS \(ODFormat.utcShort.string(from: fleet.pass.aos)) · \(ODFormat.secondaryClock(fleet.pass.aos))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                                            .lineLimit(1).minimumScaleFactor(0.7)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("in \(ODFormat.duration(max(0, fleet.pass.aos.timeIntervalSinceNow)))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.good)
                                        Text("max \(ODFormat.angle(fleet.pass.maxElevation))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)

                            if fleet.pass.aos > Date(), let satellite = store.satellites.first(where: { $0.id == fleet.id }) {
                                PassAlarmButton(satellite: satellite, pass: fleet.pass,
                                                observer: store.preferences.observer,
                                                leadMinutes: store.preferences.passAlarmLeadMinutes ?? 10)
                            } else {
                                PassAlarmUnavailable()   // keep rows aligned
                            }
                        }
                    }
                }
            }
        }
    }

    private func overheadNow(favorites: [SatelliteRecord], at date: Date) -> [(SatelliteRecord, LiveLook)] {
        favorites.compactMap { sat in
            guard let look = try? OrbitPredictor.look(sat, observer: store.preferences.observer, at: date),
                  look.elevation >= 0 else { return nil }
            return (sat, look)
        }
        .sorted { $0.1.elevation > $1.1.elevation }
    }

    private var fleetKey: String {
        let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
            .map { String($0.id) }.sorted().joined(separator: ",")
        return "\(favorites)-\(store.preferences.observer.stableKey)-\(store.preferences.minElevation)"
    }

    @MainActor
    private func loadFleet() async {
        let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
        guard !favorites.isEmpty else { fleetPasses = []; return }
        let observer = store.preferences.observer
        let minimum = store.preferences.minElevation
        fleetLoading = true
        let result = await Task.detached(priority: .userInitiated) { () -> [FleetPass] in
            var output: [FleetPass] = []
            for sat in favorites {
                if let pass = try? OrbitPredictor.predictPasses(sat, observer: observer, minElevation: minimum, maxCount: 1).first {
                    output.append(FleetPass(id: sat.id, name: sat.name, pass: pass))
                }
            }
            return output.sorted { $0.pass.aos < $1.pass.aos }
        }.value
        // Always publish the result. The detached computation runs to completion
        // regardless of parent-task cancellation, so bailing on `Task.isCancelled`
        // here (as before) could leave the list stuck on "Computing…" when a coarse
        // location update restarted the task. The stable observer key above means
        // restarts are now rare, so a last-writer-wins update is safe.
        fleetLoading = false
        fleetPasses = result
    }

    @ViewBuilder
    private func liveCards(satellite: SatelliteRecord, look: LiveLook?) -> some View {
        if let look {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    compactCard("AZIMUTH", "\(ODFormat.angle(look.azimuth)) \(ODFormat.compass(look.azimuth))")
                    compactCard("ELEVATION", ODFormat.angle(look.elevation))
                    compactCard("RANGE", ODFormat.distance(look.rangeKm))
                    compactCard("RANGE RATE", ODFormat.velocity(look.rangeRateKmS))
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        compactCard("AZIMUTH", "\(ODFormat.angle(look.azimuth)) \(ODFormat.compass(look.azimuth))")
                        compactCard("ELEVATION", ODFormat.angle(look.elevation))
                    }
                    HStack(spacing: 10) {
                        compactCard("RANGE", ODFormat.distance(look.rangeKm))
                        compactCard("RANGE RATE", ODFormat.velocity(look.rangeRateKmS))
                    }
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Label(
                    look.elevation > 0 ? "Above horizon" : "Below horizon",
                    systemImage: look.elevation > 0 ? "eye.fill" : "eye.slash"
                )
                .foregroundStyle(look.elevation > 0 ? ODTheme.good : ODTheme.muted)

                Label(
                    look.sunlit ? "Sunlit" : "Eclipsed",
                    systemImage: look.sunlit ? "sun.max.fill" : "moon.fill"
                )
                .foregroundStyle(look.sunlit ? ODTheme.warning : ODTheme.muted)

                Spacer()

                Text(ODFormat.utc.string(from: look.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ODTheme.muted)
            }
            .padding(.horizontal)
        } else {
            SectionCard("Live tracking") {
                Text("Propagation is unavailable for the selected element set.")
                    .foregroundStyle(ODTheme.warning)
            }
        }
    }

    private func compactCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ODTheme.accent)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func liveTrack(_ satellite: SatelliteRecord) -> some View {
        TimelineView(.periodic(from: clockAnchor, by: 1)) { context in
            let observer = store.preferences.observer
            let look = try? OrbitPredictor.look(satellite, observer: observer, at: context.date)
            let track = resolveTrack(satellite: satellite, observer: observer, now: context.date)
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    PolarSkyPlot(
                        points: track.arc,
                        currentPoint: look.map {
                            SkyPoint(id: context.date, date: context.date, azimuth: $0.azimuth, elevation: $0.elevation)
                        },
                        minimumElevation: store.preferences.minElevation,
                        orientation: compassUp ? (location.heading ?? 0) : 0
                    )
                    Button {
                        compassUp.toggle()
                        if compassUp { location.startHeading() } else { location.stopHeading() }
                    } label: {
                        Label(compassUp ? "Compass up" : "North up", systemImage: "location.north.line")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .tint(compassUp ? ODTheme.accent : ODTheme.muted)
                    .foregroundStyle(compassUp ? ODTheme.accent : ODTheme.muted)
                    .padding(4)
                }
                .frame(maxHeight: 380)
                .padding(.horizontal)

                nextEventBanner(now: context.date, pass: track.pass)

                liveCards(satellite: satellite, look: look)

                if let look, let transponder = selectedTransponder(satellite) {
                    dopplerCard(satellite: satellite, transponder: transponder, rangeRateKmS: look.rangeRateKmS)
                }
            }
        }
    }

    private func selectedTransponder(_ satellite: SatelliteRecord) -> TransponderRecord? {
        satellite.transponders.first { $0.id == selectedTransponderID } ?? satellite.transponders.first
    }

    @ViewBuilder
    private func transponderCard(_ satellite: SatelliteRecord) -> some View {
        SectionCard("Transponder") {
            if let transponder = selectedTransponder(satellite) {
                if satellite.transponders.count > 1 {
                    Picker("Transponder", selection: Binding(
                        get: { selectedTransponderID ?? satellite.transponders.first?.id },
                        set: { selectedTransponderID = $0 }
                    )) {
                        ForEach(satellite.transponders) { tp in
                            Text(tp.description.isEmpty ? tp.kind : tp.description).tag(Optional(tp.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
                MetricRow("Type", transponder.kind)
                if !transponder.mode.isEmpty { MetricRow("Mode", transponder.mode) }
                MetricRow("Downlink", passband(transponder.downlinkLow, transponder.downlinkHigh))
                if transponder.uplinkLow > 0 {
                    MetricRow("Uplink", passband(transponder.uplinkLow, transponder.uplinkHigh))
                }
                if transponder.isLinear {
                    MetricRow("Passband", "\(String(format: "%.0f", Double(transponder.bandwidth) / 1000)) kHz\(transponder.invert ? " · inverting" : "")")
                }
            } else {
                Text("No transmitter data for \(satellite.name). Cache the SatNOGS database to populate transponders for the whole catalog.")
                    .font(.caption)
                    .foregroundStyle(ODTheme.muted)
                Button {
                    Task { await store.refreshAllTransponders() }
                } label: {
                    HStack {
                        Label("Cache all transponders (SatNOGS)", systemImage: "square.and.arrow.down.on.square")
                        if store.isRefreshingTransponders {
                            Spacer()
                            ProgressView().accessibilityLabel("Fetching transmitters")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshingTransponders)
            }
        }
    }

    private func passband(_ low: Int64, _ high: Int64) -> String {
        if high > low {
            return "\(ODFormat.frequency(low)) – \(ODFormat.frequency(high))"
        }
        return ODFormat.frequency(low)
    }

    @ViewBuilder
    private func nextEventBanner(now: Date, pass: PredictedPass?) -> some View {
        if let pass {
            if now < pass.aos {
                Label("AOS in \(ODFormat.duration(pass.aos.timeIntervalSince(now))) · max \(ODFormat.angle(pass.maxElevation))", systemImage: "arrow.up.right")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(ODTheme.accent)
            } else if now <= pass.los {
                Label("LOS in \(ODFormat.duration(pass.los.timeIntervalSince(now)))", systemImage: "dot.radiowaves.up.forward")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(ODTheme.good)
            }
        }
    }

    private func dopplerCard(satellite: SatelliteRecord, transponder: TransponderRecord, rangeRateKmS: Double) -> some View {
        // Passband tuning: move the operating frequency off the transponder center on
        // a linear bird. An inverting transponder walks the uplink the opposite way.
        let offset = transponder.isLinear ? Int64(passbandOffsetHz.rounded()) : 0
        let downlink = transponder.downlinkCenter + offset
        let uplink: Int64 = {
            let u = transponder.uplinkCenter
            guard transponder.isLinear, u > 0 else { return u }
            return transponder.invert ? u - offset : u + offset
        }()
        let cal = store.downlinkCalibrationHz(for: satellite.id, invert: transponder.invert)
        // Calibrated dials for the tune readouts; the uncalibrated pair gives the
        // true Doppler shift shown on the Doppler (DN/UP) rows.
        let corrected = OrbitPredictor.dopplerFrequencies(downlinkHz: downlink, uplinkHz: uplink, rangeRateKmS: rangeRateKmS,
                                                          downlinkCalibrationHz: cal, uplinkCalibrationHz: 0)
        let trueShift = OrbitPredictor.dopplerFrequencies(downlinkHz: downlink, uplinkHz: uplink, rangeRateKmS: rangeRateKmS)
        let title = transponder.description.isEmpty ? "Live Doppler · \(transponder.kind)" : "Live Doppler · \(transponder.description)"
        return SectionCard(title) {
            MetricRow("Downlink", ODFormat.frequency(downlink))
            MetricRow("RX (tune)", ODFormat.frequency(corrected.rx), valueColor: ODTheme.good)
            MetricRow("Doppler (DN)", String(format: "%+lld Hz", trueShift.rx - downlink))
            if uplink > 0 {
                MetricRow("Uplink", ODFormat.frequency(uplink))
                MetricRow("TX (tune)", ODFormat.frequency(corrected.tx), valueColor: ODTheme.warning)
                MetricRow("Doppler (UP)", String(format: "%+lld Hz", trueShift.tx - uplink))
            }
            if transponder.isLinear, transponder.bandwidth > 0 {
                passbandSlider(bandwidth: transponder.bandwidth)
            }
            if cal != 0 { calibratedNote }
            calibrationDisclosure(satellite: satellite)
        }
    }

    /// Passband tuning slider for a linear transponder — walks the operating point
    /// ±half-bandwidth around center (0 = center, the default).
    @ViewBuilder private func passbandSlider(bandwidth: Int64) -> some View {
        let half = Double(bandwidth) / 2
        Divider().padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Passband").font(.caption.weight(.semibold)).foregroundStyle(ODTheme.accent)
                Spacer()
                Text(passbandOffsetHz == 0 ? "center" : String(format: "%+.1f kHz", passbandOffsetHz / 1000))
                    .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                if passbandOffsetHz != 0 {
                    Button { passbandOffsetHz = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .font(.caption).buttonStyle(.borderless)
                        .accessibilityLabel("Recenter passband")
                }
            }
            // Clamp the bound value into range: switching to a narrower transponder
            // can momentarily leave a wider offset in place before the reset fires,
            // and a Slider whose value is out of range logs a runtime error.
            let clamped = Binding(
                get: { min(half, max(-half, passbandOffsetHz)) },
                set: { passbandOffsetHz = $0 }
            )
            Slider(value: clamped.snapping(to: 0, within: 200), in: -half...half, step: 100)
        }
    }

    /// An unobtrusive expander that reveals per-satellite calibration sliders.
    @ViewBuilder private func calibrationDisclosure(satellite: SatelliteRecord) -> some View {
        Divider().padding(.vertical, 2)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showCalibration.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showCalibration ? "chevron.down" : "chevron.right")
                Label("Calibrate this satellite", systemImage: "tuningfork")
                Spacer()
            }
            .font(.caption).foregroundStyle(ODTheme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showCalibration {
            calibrationSlider(title: "Downlink", value: calibrationBinding(satellite.id, uplink: false))
            calibrationSlider(title: "Uplink", value: calibrationBinding(satellite.id, uplink: true))
            Text("Combined oscillator correction folded into the receive dial (uplink sign-flipped on inverting transponders). Shared with every Doppler screen and the Calibrations editor.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    private static let calibrationLimitHz = 10_000.0

    @ViewBuilder private func calibrationSlider(title: String, value: Binding<Double>) -> some View {
        let limit = Self.calibrationLimitHz
        // Clamp so a calibration entered elsewhere beyond ±limit doesn't drive the
        // Slider out of range (which logs a runtime error).
        let clamped = Binding(
            get: { min(limit, max(-limit, value.wrappedValue)) },
            set: { value.wrappedValue = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(ODTheme.muted)
                Spacer()
                Text(String(format: "%+.0f Hz", value.wrappedValue))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: clamped.snapping(to: 0, within: 30), in: -limit...limit, step: 10)
        }
    }

    private func calibrationBinding(_ norad: UInt, uplink: Bool) -> Binding<Double> {
        Binding(
            get: { uplink ? store.calibration(for: norad).uplinkHz : store.calibration(for: norad).downlinkHz },
            set: {
                var c = store.calibration(for: norad)
                if uplink { c.uplinkHz = $0 } else { c.downlinkHz = $0 }
                store.setCalibration(c, for: norad)
            }
        )
    }

    /// Unobtrusive note shown when a per-satellite calibration is folded into the
    /// displayed frequencies.
    private var calibratedNote: some View {
        Label("Includes your calibration for this satellite.", systemImage: "tuningfork")
            .font(.caption2).foregroundStyle(ODTheme.muted)
    }

    /// Resolve (and cache) the sky-track arc and its pass for the current
    /// satellite/observer. Recomputes only when the satellite, observer or minimum
    /// elevation changes, or when the cached pass has ended (rollover to the next
    /// pass). Runs synchronously inside the live TimelineView — SGP4 is fast and
    /// this only does real work occasionally — so the arc is always drawn without
    /// depending on a `.task` that navigation transitions can cancel.
    private func resolveTrack(satellite: SatelliteRecord, observer: ObserverSite, now: Date) -> (arc: [SkyPoint], pass: PredictedPass?) {
        let key = "\(satellite.id)-\(observer.coarseKey)-\(store.preferences.minElevation)"
        let stale = arcCache.pass.map { now > $0.los } ?? false
        if arcCache.key != key || stale {
            let pass = (try? OrbitPredictor.currentOrNextPass(satellite, observer: observer))
                ?? (try? OrbitPredictor.predictPasses(satellite, observer: observer, minElevation: 0, maxCount: 1))?.first
            arcCache.key = key
            arcCache.pass = pass
            arcCache.arc = pass.flatMap { try? OrbitPredictor.skyPath(satellite, observer: observer, pass: $0) } ?? []
        }
        return (arcCache.arc, arcCache.pass)
    }

    private var passTaskKey: String {
        "\(store.selectedSatellite?.id ?? 0)-\(store.preferences.observer.stableKey)-\(store.preferences.minElevation)"
    }

    @MainActor
    private func loadNextPass() async {
        nextPass = nil
        passError = nil
        guard let satellite = store.selectedSatellite else { return }
        let observer = store.preferences.observer
        let minimum = store.preferences.minElevation
        do {
            let passes = try await Task.detached(priority: .userInitiated) {
                try OrbitPredictor.predictPasses(
                    satellite,
                    observer: observer,
                    minElevation: minimum,
                    maxCount: 1
                )
            }.value
            nextPass = passes.first
            if nextPass == nil {
                passError = "No qualifying pass was found in the next 10 days."
            }
        } catch {
            passError = error.localizedDescription
        }
    }
}

// MARK: - Home AMSAT quick report

/// One-tap AMSAT status reporting from Home for the selected satellite, covering
/// every status type. Resolves the AMSAT catalog/operating name (session-cached)
/// and posts an attributed report through the same path as the full AMSAT status
/// screen — always behind an explicit confirmation.
struct HomeAmsatQuickReport: View {
    @EnvironmentObject private var store: OrbitStore
    let satellite: SatelliteRecord

    @State private var apiMatches: [String] = []
    @State private var apiName = ""
    @State private var pendingStatus: String?
    @State private var isSending = false
    @State private var message = ""
    @State private var succeeded = false

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } })
    }

    var body: some View {
        SectionCard("Report AMSAT status") {
            let call = store.preferences.callsign ?? ""
            if call.isEmpty {
                Text("Set your callsign in Settings to file an AMSAT status report.")
                    .font(.caption).foregroundStyle(ODTheme.warning)
            } else {
                if apiMatches.count > 1 {
                    Picker("AMSAT name", selection: $apiName) {
                        ForEach(apiMatches, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                } else if !apiName.isEmpty {
                    MetricRow("AMSAT name", apiName)
                }
                MetricRow("Attribution", "\(call.uppercased()) · \(store.operatorGrid)")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(AmsatStatusService.reportStatuses, id: \.self) { status in
                        Button {
                            pendingStatus = status
                        } label: {
                            Text(status).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSending || apiName.isEmpty)
                    }
                }
                .padding(.top, 2)

                if isSending { ProgressView("Posting…") }
                if !message.isEmpty {
                    Text(message).font(.caption)
                        .foregroundStyle(succeeded ? ODTheme.good : ODTheme.warning)
                }
                Text("Public, attributed report. OrbitDeck posts only after you confirm.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
        .task(id: satellite.id) { await resolve() }
        .confirmationDialog("Post public AMSAT status report?",
                            isPresented: confirmBinding, titleVisibility: .visible) {
            if let status = pendingStatus {
                Button("Post “\(status)”") { submit(status) }
            }
            Button("Cancel", role: .cancel) { pendingStatus = nil }
        } message: {
            Text("This publicly posts \(pendingStatus ?? "") for \(apiName) as \((store.preferences.callsign ?? "").uppercased()) / \(store.operatorGrid) on amsat.org.")
        }
    }

    private func resolve() async {
        // Retry quietly on cold networks; the catalog is session-cached once it
        // succeeds. Fall back to the satellite name so manual reporting still works.
        for attempt in 0..<5 {
            if Task.isCancelled { return }
            do {
                let matches = try await AmsatStatusService.catalogMatches(commonName: satellite.name)
                apiMatches = matches
                if let first = matches.first { apiName = first }
                else if apiName.isEmpty { apiName = satellite.name }
                return
            } catch {
                if attempt < 4 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
        if apiName.isEmpty { apiName = satellite.name }
    }

    private func submit(_ status: String) {
        let name = apiName
        let call = store.preferences.callsign ?? ""
        let grid = store.operatorGrid
        pendingStatus = nil
        isSending = true; message = ""; succeeded = false
        Task {
            do {
                message = try await AmsatStatusService.submitReport(apiName: name, status: status, callsign: call, grid: grid)
                succeeded = true
            } catch {
                message = error.localizedDescription
            }
            isSending = false
        }
    }
}

// MARK: - Grid Finder

/// Live GPS tool that helps an operator walk onto a Maidenhead grid line or the
/// corner where four grids meet (for VUCC rove operating). Shows a precise
/// position/grid readout, VUCC line/corner status, compass dials guiding to the
/// nearest corner and nearest line, a north-up proximity map, and fix telemetry.
/// The compass is enabled automatically while the screen is visible, and location
/// runs at best-for-navigation precision so the operator can walk to within a
/// VUCC-quality fix of the boundary while being guided.
struct GridFinderView: View {
    @StateObject private var location = LocationProvider()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let fix = location.location, fix.horizontalAccuracy >= 0 {
                    content(fix)
                } else {
                    SectionCard("Acquiring fix") {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Waiting for a GPS fix…").foregroundStyle(ODTheme.muted)
                        }
                        if let err = location.errorMessage {
                            Text(err).font(.caption).foregroundStyle(ODTheme.warning)
                        }
                    }
                }
            }
            .padding()
        }
        // Drive location + heading for the whole time the view is alive. Using
        // `.task` (not onAppear/onDisappear) avoids a spurious onDisappear during
        // the iPhone split-view push transition tearing the compass down while the
        // screen is still visible; the updates stop cleanly when the view is
        // actually dismissed and the provider is released.
        .task {
            location.setPrecise(true)
            location.geocodeEnabled = true
            location.startHeading()
        }
    }

    @ViewBuilder private func content(_ fix: CLLocation) -> some View {
        let lat = fix.coordinate.latitude
        let lon = fix.coordinate.longitude
        let g = GridGeometry(latitude: lat, longitude: lon)
        let vucc = FeatureEngine.vuccGrids(latitude: lat, longitude: lon)

        statusBanner(vucc: vucc)

        SectionCard("Location") {
            MetricRow("Grid (6)", FeatureEngine.latLonToGrid6(latitude: lat, longitude: lon), valueColor: ODTheme.good)
            MetricRow("Grid (8)", g.grid8)
            MetricRow("Latitude", String(format: "%+.6f°", lat))
            MetricRow("Longitude", String(format: "%+.6f°", lon))
            MetricRow("Altitude", fix.verticalAccuracy >= 0 ? String(format: "%.0f m", fix.altitude) : "—")
            if let entity = location.entity, entity.hasAnything {
                MetricRow("DXCC", entity.dxccLabel ?? "—", valueColor: ODTheme.good)
                if let primary = entity.primarySubdivision {
                    MetricRow("Primary subdivision", primary)
                }
                if let secondary = entity.secondarySubdivision {
                    MetricRow("Secondary subdivision", secondary)
                }
            }
        }

        SectionCard("Guide to nearest grid corner") {
            CompassDial(heading: location.heading, bearing: g.cornerBearing,
                        distance: metersString(g.cornerDistance), tint: ODTheme.good)
            MetricRow("Corner grids", g.cornerGrids.joined(separator: " / "))
            MetricRow("Distance", metersString(g.cornerDistance), valueColor: ODTheme.good)
            MetricRow("Bearing", String(format: "%.0f° %@", g.cornerBearing, cardinal(g.cornerBearing)))
            walkHint
        }

        SectionCard("Guide to nearest grid line") {
            CompassDial(heading: location.heading, bearing: g.nearestLineBearing,
                        distance: metersString(g.nearestLineDistance), tint: ODTheme.accent)
            MetricRow("Line", g.nearestLineLabel)
            MetricRow("Grids across it", g.nearestLineGrids.joined(separator: " / "))
            MetricRow("Distance", metersString(g.nearestLineDistance), valueColor: ODTheme.accent)
            MetricRow("Bearing", String(format: "%.0f° %@", g.nearestLineBearing, cardinal(g.nearestLineBearing)))
            walkHint
        }

        SectionCard("Both boundary lines") {
            MetricRow("Latitude line (\(g.latLineDirection))", metersString(g.latLineDistance))
            MetricRow("Longitude line (\(g.lonLineDirection))", metersString(g.lonLineDistance))
            Text(String(format: "VUCC counts a fix within %.1f m of a line as on it (ARRL 20-ft rule).",
                        FeatureEngine.vuccBoundaryToleranceMeters))
                .font(.caption).foregroundStyle(ODTheme.muted)
        }

        SectionCard("Grid proximity map") {
            polarMap(g: g)
                .frame(height: 300)
                .frame(maxWidth: .infinity)
            Text("North-up. The center is you; dashed lines are the nearest grid boundaries, the green dot is the corner and the blue ring is the nearest point on the closest line. The amber needle is your heading.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }

        SectionCard("Fix quality") {
            MetricRow("Horizontal accuracy",
                      String(format: "± %.1f m", fix.horizontalAccuracy),
                      valueColor: accuracyColor(fix.horizontalAccuracy))
            MetricRow("Vertical accuracy", fix.verticalAccuracy >= 0 ? String(format: "± %.1f m", fix.verticalAccuracy) : "—")
            MetricRow("Speed", fix.speed >= 0 ? String(format: "%.1f m/s", fix.speed) : "—")
            MetricRow("Heading", location.heading.map { String(format: "%.0f° %@", $0, cardinal($0)) } ?? "—")
            let vuccGrade = fix.horizontalAccuracy <= FeatureEngine.vuccBoundaryToleranceMeters
            MetricRow("VUCC-grade fix", vuccGrade ? "Yes (≤ 6.1 m)" : "No",
                      valueColor: vuccGrade ? ODTheme.good : ODTheme.warning)
            MetricRow("Fix age", String(format: "%.0f s", max(0, -fix.timestamp.timeIntervalSinceNow)))
        }
    }

    @ViewBuilder private var walkHint: some View {
        Text(location.heading == nil
             ? "North-up: the arrow points to the true bearing. (Device compass not reporting — a magnetometer is required, e.g. this won't work in the Simulator.)"
             : "Hold the phone flat and walk the way the arrow points.")
            .font(.caption).foregroundStyle(ODTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sub-views

    @ViewBuilder private func statusBanner(vucc: [String]) -> some View {
        let onCorner = vucc.count >= 4
        let onLine = vucc.count >= 2
        let color: Color = onLine ? ODTheme.good : ODTheme.muted
        VStack(spacing: 4) {
            Text(onCorner ? "ON GRID CORNER" : (onLine ? "ON GRID LINE" : "INSIDE GRID"))
                .font(.title3.bold()).foregroundStyle(color)
            Text(vucc.joined(separator: " · "))
                .font(.subheadline.monospaced()).foregroundStyle(ODTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.5)))
    }

    @ViewBuilder private func polarMap(g: GridGeometry) -> some View {
        let heading = location.heading
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) / 2 - 10
            let range = max(g.cornerDistance * 1.35, 25)
            let scale = R / range

            for f in [0.25, 0.5, 0.75, 1.0] {
                let rr = R * f
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(ODTheme.grid), lineWidth: f == 1.0 ? 1.5 : 0.6)
                ctx.draw(Text(metersString(range * f)).font(.system(size: 8)).foregroundStyle(ODTheme.muted),
                         at: CGPoint(x: c.x, y: c.y - rr + 7))
            }

            // Nearest grid boundaries (north = up = -y, east = +x), drawn as chords
            // so they stay contained within the circular map.
            let oyLat = -g.dNorthCorner * scale           // vertical offset of the lat line
            if abs(oyLat) < R {
                let half = (R * R - oyLat * oyLat).squareRoot()
                let y = c.y + oyLat
                var p = Path(); p.move(to: CGPoint(x: c.x - half, y: y)); p.addLine(to: CGPoint(x: c.x + half, y: y))
                ctx.stroke(p, with: .color(ODTheme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            let oxLon = g.dEastCorner * scale              // horizontal offset of the lon line
            if abs(oxLon) < R {
                let half = (R * R - oxLon * oxLon).squareRoot()
                let x = c.x + oxLon
                var p = Path(); p.move(to: CGPoint(x: x, y: c.y - half)); p.addLine(to: CGPoint(x: x, y: c.y + half))
                ctx.stroke(p, with: .color(ODTheme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }

            // Corner dot (clamped into the outer ring for safety).
            var corner = CGPoint(x: c.x + g.dEastCorner * scale, y: c.y - g.dNorthCorner * scale)
            let dx = corner.x - c.x, dy = corner.y - c.y, d = hypot(dx, dy)
            let cornerClamped = d > R
            if cornerClamped { corner = CGPoint(x: c.x + dx / d * R, y: c.y + dy / d * R) }
            ctx.fill(Path(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)),
                     with: .color(cornerClamped ? ODTheme.warning : ODTheme.good))

            // Nearest point on the closest line (blue ring), clamped into the ring.
            var lineTarget = CGPoint(x: c.x + g.dEastLine * scale, y: c.y - g.dNorthLine * scale)
            let ldx = lineTarget.x - c.x, ldy = lineTarget.y - c.y, ld = hypot(ldx, ldy)
            if ld > R { lineTarget = CGPoint(x: c.x + ldx / ld * R, y: c.y + ldy / ld * R) }
            ctx.stroke(Path(ellipseIn: CGRect(x: lineTarget.x - 5, y: lineTarget.y - 5, width: 10, height: 10)),
                       with: .color(ODTheme.accent), lineWidth: 2.5)

            // Heading needle.
            if let h = heading {
                let a = h * .pi / 180
                let tip = CGPoint(x: c.x + sin(a) * R * 0.9, y: c.y - cos(a) * R * 0.9)
                var needle = Path(); needle.move(to: c); needle.addLine(to: tip)
                ctx.stroke(needle, with: .color(ODTheme.warning), lineWidth: 2)
            }

            // Operator at center and the N marker.
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
            ctx.draw(Text("N").font(.system(size: 10, weight: .bold)).foregroundStyle(ODTheme.muted),
                     at: CGPoint(x: c.x, y: c.y - R + 8))
        }
    }

    // MARK: Formatting helpers

    private func metersString(_ m: Double) -> String {
        m < 1000 ? String(format: "%.0f m", m) : String(format: "%.2f km", m / 1000)
    }

    private func cardinal(_ deg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int((deg / 45).rounded()) % 8
        return dirs[(i + 8) % 8]
    }

    private func accuracyColor(_ acc: Double) -> Color {
        if acc <= FeatureEngine.vuccBoundaryToleranceMeters { return ODTheme.good }
        if acc <= 15 { return ODTheme.accent }
        return ODTheme.warning
    }
}

/// A compass rose that points to a target bearing relative to the device heading,
/// with N/E/S/W labels and tick marks rotating to true north, and the distance
/// shown neatly inside the ring. Falls back to north-up when no heading is
/// available yet.
private struct CompassDial: View {
    let heading: Double?
    let bearing: Double
    let distance: String
    var tint: Color = ODTheme.accent

    var body: some View {
        let h = heading ?? 0
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 2
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(ODTheme.grid), lineWidth: 2)

                // Tick marks every 15°, majors + cardinal labels every 90°, rotated
                // so the labels track true north relative to the phone.
                for k in 0..<24 {
                    let a = (Double(k) * 15 - h) * .pi / 180
                    let dir = CGPoint(x: sin(a), y: -cos(a))
                    let major = k % 6 == 0
                    let len = major ? 10.0 : 5.0
                    var tick = Path()
                    tick.move(to: CGPoint(x: c.x + dir.x * r, y: c.y + dir.y * r))
                    tick.addLine(to: CGPoint(x: c.x + dir.x * (r - len), y: c.y + dir.y * (r - len)))
                    ctx.stroke(tick, with: .color(major ? ODTheme.muted : ODTheme.grid), lineWidth: major ? 1.6 : 0.8)
                    if major {
                        let label = ["N", "E", "S", "W"][(k / 6) % 4]
                        ctx.draw(Text(label).font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(label == "N" ? ODTheme.warning : ODTheme.muted),
                                 at: CGPoint(x: c.x + dir.x * (r - 22), y: c.y + dir.y * (r - 22)))
                    }
                }

                // Target arrow at (bearing − heading).
                let a = (bearing - h) * .pi / 180
                let dir = CGPoint(x: sin(a), y: -cos(a))
                let perp = CGPoint(x: -dir.y, y: dir.x)
                let tip = CGPoint(x: c.x + dir.x * (r - 14), y: c.y + dir.y * (r - 14))
                let base = CGPoint(x: c.x + dir.x * (r * 0.30), y: c.y + dir.y * (r * 0.30))
                var shaft = Path(); shaft.move(to: base); shaft.addLine(to: tip)
                ctx.stroke(shaft, with: .color(tint), lineWidth: 4)
                let back = CGPoint(x: tip.x - dir.x * 12, y: tip.y - dir.y * 12)
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(x: back.x + perp.x * 7, y: back.y + perp.y * 7))
                head.addLine(to: CGPoint(x: back.x - perp.x * 7, y: back.y - perp.y * 7))
                head.closeSubpath()
                ctx.fill(head, with: .color(tint))
            }
            // Distance readout, contained within the circle (its opaque hub also
            // masks the arrow's base so the needle reads as pointing outward).
            Text(distance)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(ODTheme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(ODTheme.grid))
        }
        .frame(width: 190, height: 190)
        .frame(maxWidth: .infinity)
    }
}

/// Geometry of the nearest Maidenhead 4-character (VUCC) grid boundaries to a
/// position: distances/directions to the nearest latitude and longitude lines,
/// and the bearing/distance to the corner where they meet.
private struct GridGeometry {
    let latLineDistance: Double
    let lonLineDistance: Double
    let latLineDirection: String
    let lonLineDirection: String
    let cornerDistance: Double
    let cornerBearing: Double
    let dNorthCorner: Double
    let dEastCorner: Double
    let cornerGrids: [String]
    let grid8: String
    // Nearest single boundary line (whichever of the lat/lon lines is closer).
    let nearestLineDistance: Double
    let nearestLineBearing: Double
    let nearestLineLabel: String
    let nearestLineGrids: [String]
    let dNorthLine: Double
    let dEastLine: Double

    init(latitude: Double, longitude: Double) {
        // 4-char grids are 1° tall (integer-degree lat lines) and 2° wide (even-
        // degree lon lines measured from the −180° antimeridian).
        let latBoundary = latitude.rounded()
        let lonBoundary = ((longitude + 180.0) / 2.0).rounded() * 2.0 - 180.0
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(latitude * .pi / 180.0)
        let dNorth = (latBoundary - latitude) * mPerDegLat   // + = boundary is north
        let dEast = (lonBoundary - longitude) * mPerDegLon    // + = boundary is east

        latLineDistance = abs(dNorth)
        lonLineDistance = abs(dEast)
        latLineDirection = dNorth >= 0 ? "north" : "south"
        lonLineDirection = dEast >= 0 ? "east" : "west"
        dNorthCorner = dNorth
        dEastCorner = dEast
        cornerDistance = (dNorth * dNorth + dEast * dEast).squareRoot()
        var bearing = atan2(dEast, dNorth) * 180.0 / .pi
        if bearing < 0 { bearing += 360 }
        cornerBearing = bearing

        // The four grids that meet at that corner (nudge across each boundary).
        let otherLat = latBoundary - (latitude >= latBoundary ? 0.0005 : -0.0005)
        let otherLon = lonBoundary - (longitude >= lonBoundary ? 0.0005 : -0.0005)
        let grids: Set<String> = [
            FeatureEngine.latLonToGrid4(latitude: latitude, longitude: longitude),
            FeatureEngine.latLonToGrid4(latitude: otherLat, longitude: longitude),
            FeatureEngine.latLonToGrid4(latitude: latitude, longitude: otherLon),
            FeatureEngine.latLonToGrid4(latitude: otherLat, longitude: otherLon)
        ]
        cornerGrids = grids.sorted()

        // The closer of the two boundary lines, and the perpendicular route onto it.
        let currentGrid = FeatureEngine.latLonToGrid4(latitude: latitude, longitude: longitude)
        if latLineDistance <= lonLineDistance {
            nearestLineDistance = latLineDistance
            nearestLineBearing = dNorth >= 0 ? 0 : 180
            nearestLineLabel = "Latitude line to the \(latLineDirection)"
            nearestLineGrids = [currentGrid, FeatureEngine.latLonToGrid4(latitude: otherLat, longitude: longitude)].sorted()
            dNorthLine = dNorth; dEastLine = 0
        } else {
            nearestLineDistance = lonLineDistance
            nearestLineBearing = dEast >= 0 ? 90 : 270
            nearestLineLabel = "Longitude line to the \(lonLineDirection)"
            nearestLineGrids = [currentGrid, FeatureEngine.latLonToGrid4(latitude: latitude, longitude: otherLon)].sorted()
            dNorthLine = 0; dEastLine = dEast
        }

        // Extend the 6-char locator with a numeric (0–9) extended-square pair.
        let base = FeatureEngine.latLonToGrid6(latitude: latitude, longitude: longitude)
        let la = max(-90.0, min(89.999999, latitude)) + 90.0
        let lo = max(-180.0, min(179.999999, longitude)) + 180.0
        let subLon = 2.0 / 24.0, subLat = 1.0 / 24.0
        let d1 = min(9, Int((lo.truncatingRemainder(dividingBy: subLon)) / subLon * 10))
        let d2 = min(9, Int((la.truncatingRemainder(dividingBy: subLat)) / subLat * 10))
        grid8 = "\(base)\(d1)\(d2)"
    }
}
