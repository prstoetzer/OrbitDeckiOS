import SwiftUI

private struct FleetPass: Identifiable, Sendable {
    let id: UInt
    let name: String
    let pass: PredictedPass
}

struct HomeView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var nextPass: PredictedPass?
    @State private var passError: String?
    @State private var fleetPasses: [FleetPass] = []
    @State private var fleetLoading = false
    @State private var trackArc: [SkyPoint] = []
    @State private var currentPass: PredictedPass?
    @StateObject private var location = LocationProvider()
    @State private var compassUp = false
    @State private var selectedTransponderID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SelectedSatelliteHeader()

                if let satellite = store.selectedSatellite {
                    liveTrack(satellite)
                    transponderCard(satellite)
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
        .task(id: passTaskKey) {
            trackArc = []
            currentPass = nil
            while !Task.isCancelled {
                await loadTrack()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .task(id: fleetKey) {
            await loadFleet()
        }
        .onDisappear { location.stopHeading() }
        .onChange(of: store.preferences.selectedNorad) { _, _ in selectedTransponderID = nil }
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
            TimelineView(.periodic(from: .now, by: 5)) { context in
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
                        Button { store.select(fleet.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fleet.name)
                                        .foregroundStyle(fleet.id == store.selectedSatellite?.id ? ODTheme.accent : .primary)
                                    Text("AOS \(ODFormat.utcShort.string(from: fleet.pass.aos))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
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
                        .buttonStyle(.plain)
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
        let o = store.preferences.observer
        return "\(favorites)-\(o.latitude)-\(o.longitude)-\(store.preferences.minElevation)"
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
        if Task.isCancelled { return }
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let look = try? OrbitPredictor.look(satellite, observer: store.preferences.observer, at: context.date)
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    PolarSkyPlot(
                        points: trackArc,
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

                nextEventBanner(now: context.date)

                liveCards(satellite: satellite, look: look)

                if let look, let transponder = selectedTransponder(satellite) {
                    dopplerCard(transponder: transponder, rangeRateKmS: look.rangeRateKmS)
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
    private func nextEventBanner(now: Date) -> some View {
        if let pass = currentPass {
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

    private func dopplerCard(transponder: TransponderRecord, rangeRateKmS: Double) -> some View {
        let downlink = transponder.downlinkCenter
        let uplink = transponder.uplinkCenter
        let corrected = OrbitPredictor.dopplerFrequencies(downlinkHz: downlink, uplinkHz: uplink, rangeRateKmS: rangeRateKmS)
        let title = transponder.description.isEmpty ? "Live Doppler · \(transponder.kind)" : "Live Doppler · \(transponder.description)"
        return SectionCard(title) {
            MetricRow("Downlink", ODFormat.frequency(downlink))
            MetricRow("RX (tune)", ODFormat.frequency(corrected.rx), valueColor: ODTheme.good)
            MetricRow("Doppler (DN)", String(format: "%+lld Hz", corrected.rx - downlink))
            if uplink > 0 {
                MetricRow("Uplink", ODFormat.frequency(uplink))
                MetricRow("TX (tune)", ODFormat.frequency(corrected.tx), valueColor: ODTheme.warning)
                MetricRow("Doppler (UP)", String(format: "%+lld Hz", corrected.tx - uplink))
            }
        }
    }

    @MainActor
    private func loadTrack() async {
        guard let satellite = store.selectedSatellite else { trackArc = []; currentPass = nil; return }
        let observer = store.preferences.observer
        let computed = await Task.detached(priority: .userInitiated) { () -> (path: [SkyPoint], pass: PredictedPass?) in
            let pass = (try? OrbitPredictor.currentOrNextPass(satellite, observer: observer))
                ?? (try? OrbitPredictor.predictPasses(satellite, observer: observer, minElevation: 0, maxCount: 1))?.first
            guard let pass else { return ([], nil) }
            let path = (try? OrbitPredictor.skyPath(satellite, observer: observer, pass: pass)) ?? []
            return (path, pass)
        }.value
        if Task.isCancelled { return }
        trackArc = computed.path
        currentPass = computed.pass
    }

    private var passTaskKey: String {
        let o = store.preferences.observer
        return "\(store.selectedSatellite?.id ?? 0)-\(o.latitude)-\(o.longitude)-\(store.preferences.minElevation)"
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
