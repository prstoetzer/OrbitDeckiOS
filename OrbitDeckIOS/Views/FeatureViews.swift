import SwiftUI
import Charts

// MARK: - Shared celestial plot

private struct CelestialPolarPlot: View {
    let points: [CelestialPoint]

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(1, side / 2 - 28)

            for elevation in stride(from: 0.0, through: 90.0, by: 30.0) {
                let r = radius * (90.0 - elevation) / 90.0
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(ODTheme.grid), lineWidth: 1)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: center.x, y: center.y - radius))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            cross.move(to: CGPoint(x: center.x - radius, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            context.stroke(cross, with: .color(ODTheme.grid.opacity(0.75)), lineWidth: 1)

            // Track occupied label rectangles so nearby objects don't stack
            // their names on top of one another.
            var placedLabels: [CGRect] = []
            func placeLabel(_ resolved: GraphicsContext.ResolvedText, near anchorPoint: CGPoint) -> CGPoint {
                let size = resolved.measure(in: CGSize(width: 240, height: 40))
                let candidates: [CGPoint] = [
                    anchorPoint,
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y + 12),
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y - 12),
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y + 24),
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y - 24),
                    // Flip to the left of the marker when the right side is full.
                    CGPoint(x: anchorPoint.x - size.width - 16, y: anchorPoint.y),
                    CGPoint(x: anchorPoint.x - size.width - 16, y: anchorPoint.y + 12),
                    CGPoint(x: anchorPoint.x - size.width - 16, y: anchorPoint.y - 12)
                ]
                for candidate in candidates {
                    let rect = CGRect(x: candidate.x, y: candidate.y - size.height / 2,
                                      width: size.width, height: size.height)
                    if !placedLabels.contains(where: { $0.intersects(rect) }) {
                        placedLabels.append(rect)
                        return candidate
                    }
                }
                let fallback = candidates[0]
                placedLabels.append(CGRect(x: fallback.x, y: fallback.y - size.height / 2,
                                           width: size.width, height: size.height))
                return fallback
            }

            for (label, location) in [
                ("N", CGPoint(x: center.x, y: center.y - radius - 12)),
                ("E", CGPoint(x: center.x + radius + 12, y: center.y)),
                ("S", CGPoint(x: center.x, y: center.y + radius + 12)),
                ("W", CGPoint(x: center.x - radius - 12, y: center.y))
            ] {
                let resolved = context.resolve(Text(label).font(.caption2.monospaced()).foregroundStyle(ODTheme.muted))
                let size = resolved.measure(in: CGSize(width: 40, height: 40))
                placedLabels.append(CGRect(x: location.x - size.width / 2, y: location.y - size.height / 2,
                                           width: size.width, height: size.height))
                context.draw(resolved, at: location)
            }

            // Higher-priority objects claim label space first so satellites and
            // luminaries stay readable when the sky is crowded.
            func labelPriority(_ point: CelestialPoint) -> Int {
                if point.category == "Satellite" { return 0 }
                if point.name == "Sun" || point.name == "Moon" { return 1 }
                if point.category == "Planet" { return 2 }
                if point.category == "Reference" { return 4 }
                return 3
            }
            let visible = points.filter { $0.elevation >= 0 }
                .sorted { labelPriority($0) < labelPriority($1) }

            for point in visible {
                let theta = point.azimuth * .pi / 180
                let r = radius * max(0, min(1, (90 - point.elevation) / 90))
                let location = CGPoint(x: center.x + r * sin(theta),
                                       y: center.y - r * cos(theta))
                let color: Color = switch point.name {
                case "Sun": ODTheme.warning
                case "Moon": .cyan
                default:
                    switch point.category {
                    case "Planet": ODTheme.good
                    case "Satellite": .pink
                    case "Reference": ODTheme.muted
                    default: ODTheme.accent
                    }
                }
                let markerSize: CGFloat = point.category == "Satellite" ? 13 : 10
                context.fill(Path(ellipseIn: CGRect(x: location.x - markerSize/2, y: location.y - markerSize/2,
                                                    width: markerSize, height: markerSize)),
                             with: .color(color))
                let resolved = context.resolve(Text(point.name).font(.caption2).foregroundStyle(.white))
                let labelPos = placeLabel(resolved, near: CGPoint(x: location.x + 8, y: location.y - 8))
                // Draw a faint leader line when the label had to move away from its marker.
                if abs(labelPos.y - (location.y - 8)) > 6 || labelPos.x < location.x {
                    var leader = Path()
                    leader.move(to: CGPoint(x: location.x, y: location.y))
                    leader.addLine(to: CGPoint(x: labelPos.x, y: labelPos.y))
                    context.stroke(leader, with: .color(color.opacity(0.35)), lineWidth: 0.6)
                }
                context.draw(resolved, at: labelPos, anchor: .leading)
            }

            // Below-horizon ghost markers for the Sun and Moon: a hollow marker
            // just outside the rim, at the body's azimuth, so its bearing is
            // still visible for planning even when it has set.
            for point in points where point.elevation < 0 && (point.name == "Sun" || point.name == "Moon") {
                let theta = point.azimuth * .pi / 180
                let ghost = CGPoint(x: center.x + (radius + 8) * sin(theta),
                                    y: center.y - (radius + 8) * cos(theta))
                let color: Color = point.name == "Sun" ? ODTheme.warning : .cyan
                context.stroke(Path(ellipseIn: CGRect(x: ghost.x - 5, y: ghost.y - 5, width: 10, height: 10)),
                               with: .color(color.opacity(0.5)), lineWidth: 1.5)
                context.draw(Text("\(point.name) ↓").font(.system(size: 8)).foregroundStyle(color.opacity(0.7)),
                             at: CGPoint(x: ghost.x, y: ghost.y - 11))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Celestial sky plot")
    }
}

// MARK: - Sun / Moon

struct SunMoonView: View {
    @EnvironmentObject private var store: OrbitStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { timeline in
            let snapshot = FeatureEngine.sunMoon(site: store.preferences.observer, at: timeline.date)
            let points = [
                CelestialPoint(id: "sun", name: "Sun", azimuth: snapshot.sunAzimuth,
                               elevation: snapshot.sunElevation, category: "Solar System"),
                CelestialPoint(id: "moon", name: "Moon", azimuth: snapshot.moonAzimuth,
                               elevation: snapshot.moonElevation, category: "Solar System")
            ]
            ScrollView {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        sunMoonCard(title: "Sun", azimuth: snapshot.sunAzimuth,
                                    elevation: snapshot.sunElevation,
                                    detail: snapshot.sunElevation > 0 ? "Above horizon" :
                                        (snapshot.sunElevation > -18 ? "Twilight" : "Night"),
                                    systemImage: "sun.max.fill")
                        sunMoonCard(title: "Moon", azimuth: snapshot.moonAzimuth,
                                    elevation: snapshot.moonElevation,
                                    detail: "\(snapshot.moonPhaseName) · \(Int((snapshot.moonIllumination * 100).rounded()))%",
                                    systemImage: "moon.fill")
                    }
                    .frame(maxWidth: .infinity)

                    CelestialPolarPlot(points: points)
                        .frame(maxWidth: 560)
                        .padding()
                        .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 14))

                    HStack {
                        Label(ODFormat.utc.string(from: timeline.date), systemImage: "clock")
                        Spacer()
                        Text(String(format: "Moon distance %.0f km", snapshot.moonDistanceKm))
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(ODTheme.muted)
                }
                .padding()
            }
        }
    }

    private func sunMoonCard(title: String, azimuth: Double, elevation: Double,
                             detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(title == "Sun" ? ODTheme.warning : .cyan)
            Text("\(ODFormat.angle(azimuth))  \(ODFormat.compass(azimuth))")
                .font(.body.monospaced())
            Text(String(format: "%+.1f°", elevation))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
            Text(detail)
                .font(.caption)
                .foregroundStyle(ODTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Sky Map

struct SkyMapView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var showBelowHorizon = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            let all = FeatureEngine.skyObjects(site: store.preferences.observer, at: timeline.date, selectedSatellite: store.selectedSatellite)
            let visible = showBelowHorizon ? all : all.filter { $0.elevation >= 0 }
            ScrollView {
                VStack(spacing: 14) {
                    Toggle("Include below-horizon objects in list", isOn: $showBelowHorizon)
                        .padding(.horizontal)
                    CelestialPolarPlot(points: all)
                        .frame(maxWidth: 620)
                        .padding()
                        .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 14))

                    LazyVStack(spacing: 1) {
                        ForEach(visible.sorted { $0.elevation > $1.elevation }) { point in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(point.name).font(.headline)
                                    Text(point.category).font(.caption).foregroundStyle(ODTheme.muted)
                                }
                                Spacer()
                                Text("Az \(ODFormat.angle(point.azimuth))")
                                    .font(.caption.monospaced())
                                Text(String(format: "El %+.1f°", point.elevation))
                                    .font(.body.monospaced())
                                    .foregroundStyle(point.elevation >= 0 ? ODTheme.good : ODTheme.muted)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 9)
                            .background(ODTheme.panel.opacity(0.7))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
        }
    }
}

// MARK: - Mutual windows

private struct FavoriteMutualWindow: Identifiable, Sendable {
    let id = UUID()
    let satelliteName: String
    let window: MutualWindowRecord
}

/// Four-dial Doppler (my RX/TX and the DX station's RX/TX) across a mutual
/// window — the numbers two operators need to hear each other through a linear
/// bird. Reuses the shared `DXDopplerEngine` (same math as the activation path).
private struct DXDopplerSheet: View {
    let satellite: SatelliteRecord
    let home: ObserverSite
    let dx: ObserverSite
    let window: MutualWindowRecord
    let store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTransponderID: String?
    @State private var mode: DXDopplerMode = .trueRule
    @State private var anchor: DXDopplerAnchor = .myTX
    @State private var passbandPercent = 50.0
    // Loaded from / saved to the per-satellite calibration store.
    @State private var calDlHz = 0.0
    @State private var calUlHz = 0.0
    @State private var rows: [DXDopplerRow] = []
    @State private var loading = false
    @State private var error: String?

    private var transponder: TransponderRecord? {
        satellite.transponders.first { $0.id == selectedTransponderID } ?? satellite.transponders.first
    }

    private func offsetHz(_ tp: TransponderRecord) -> Int64 {
        guard tp.isLinear, tp.bandwidth > 0 else { return 0 }
        return Int64((Double(tp.bandwidth) * max(0, min(100, passbandPercent)) / 100).rounded())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    SectionCard("Setup") {
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
                        Picker("Mode", selection: $mode) {
                            ForEach(DXDopplerMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if mode != .trueRule {
                            Picker("Locked dial", selection: $anchor) {
                                ForEach(DXDopplerAnchor.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        if let tp = transponder, tp.isLinear, tp.bandwidth > 0 {
                            let pair = OrbitPredictor.passbandFrequencies(tp, offsetHz: offsetHz(tp))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Passband leg")
                                    Spacer()
                                    Text(String(format: "%.0f%% · DL %.4f · UL %.4f MHz", passbandPercent,
                                                Double(pair.downlink) / 1e6, Double(pair.uplink) / 1e6))
                                        .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                }
                                Slider(value: $passbandPercent, in: 0...100, step: 1)
                            }
                        }
                    }
                    SectionCard("Radio calibration") {
                        HStack {
                            Text("Downlink offset")
                            Spacer()
                            TextField("Hz", value: $calDlHz, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.odField)
                                .frame(width: 100)
                            Text("Hz").foregroundStyle(ODTheme.muted)
                        }
                        HStack {
                            Text("Uplink offset")
                            Spacer()
                            TextField("Hz", value: $calUlHz, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.odField)
                                .frame(width: 100)
                            Text("Hz").foregroundStyle(ODTheme.muted)
                        }
                        Text("Your combined oscillator error (radio + satellite). Measure it from the downlink and/or uplink; both fold into one overall correction applied to your receive dial only — your transmit dial stays on the computed frequency, and the DX station is never calibrated. Saved per satellite.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    SectionCard("Window") {
                        MetricRow("Satellite", satellite.name)
                        MetricRow("DX station", dx.name)
                        MetricRow("Start", ODFormat.utc.string(from: window.start), valueColor: ODTheme.good)
                        MetricRow("End", ODFormat.utc.string(from: window.end), valueColor: ODTheme.warning)
                        MetricRow("Duration", ODFormat.duration(window.duration))
                    }
                    SectionCard("Four-dial Doppler · MHz") {
                        if loading {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if let error {
                            Text(error).foregroundStyle(ODTheme.warning)
                        } else if rows.isEmpty {
                            Text("No usable geometry in this window.").foregroundStyle(ODTheme.muted)
                        } else {
                            dialTable
                        }
                    }
                    Text("Dial frequencies each station tunes to work the same transponder point, with each station's own Doppler applied. \"Fixed\" modes lock the chosen dial to one value for the whole window. First-order Doppler from the SGP4 velocity.")
                        .font(.caption).foregroundStyle(ODTheme.muted).padding(.horizontal)
                }
                .padding(.vertical, 14)
            }
            .navigationTitle("DX Doppler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                let cal = store.calibration(for: satellite.id)
                calDlHz = cal.downlinkHz
                calUlHz = cal.uplinkHz
            }
            .task { await compute() }
            // `.task(id:)` doesn't reliably re-fire on local control changes here,
            // so recompute whenever any setup control (folded into computeKey) changes.
            .onChange(of: computeKey) { _, _ in Task { await compute() } }
            .onChange(of: calDlHz) { _, _ in store.setCalibration(RadioCalibration(downlinkHz: calDlHz, uplinkHz: calUlHz), for: satellite.id) }
            .onChange(of: calUlHz) { _, _ in store.setCalibration(RadioCalibration(downlinkHz: calDlHz, uplinkHz: calUlHz), for: satellite.id) }
        }
    }

    private var computeKey: String { "\(selectedTransponderID ?? "")-\(mode.rawValue)-\(anchor.rawValue)-\(Int(passbandPercent))-\(Int(calDlHz))-\(Int(calUlHz))" }

    private var dialTable: some View {
        // A Grid (not fixed-width columns) so the dials fit and scale with Dynamic
        // Type instead of clipping or needing a horizontal scroll.
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("UTC").gridColumnAlignment(.leading)
                Text("My RX"); Text("My TX"); Text("DX RX"); Text("DX TX")
            }
            .font(.caption.bold().monospaced())
            .foregroundStyle(ODTheme.muted)
            Divider().gridCellColumns(5)
            ForEach(rows) { row in
                GridRow {
                    Text(Self.clock.string(from: row.date)).gridColumnAlignment(.leading)
                    Text(mhz(row.myRX)).foregroundStyle(ODTheme.good)
                    Text(row.myTX > 0 ? mhz(row.myTX) : "—").foregroundStyle(ODTheme.warning)
                    Text(mhz(row.dxRX))
                    Text(row.dxTX > 0 ? mhz(row.dxTX) : "—")
                }
                .font(.caption.monospaced())
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func mhz(_ hz: Int64) -> String { String(format: "%.4f", Double(hz) / 1e6) }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    @MainActor
    private func compute() async {
        guard let tp = transponder else { rows = []; error = "This satellite has no transponder."; return }
        loading = rows.isEmpty
        error = nil
        let sat = satellite, homeSite = home, dxSite = dx, win = window, m = mode, a = anchor
        let offset = offsetHz(tp)
        let calDl = Int64(calDlHz.rounded()), calUl = Int64(calUlHz.rounded())
        let span = max(1, win.end.timeIntervalSince(win.start))
        let step = max(15.0, span / 40.0)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try DXDopplerEngine.table(satellite: sat, home: homeSite, dx: dxSite, transponder: tp,
                                          window: win, offsetHz: offset, mode: m, anchor: a,
                                          calDlHz: calDl, calUlHz: calUl, step: step)
            }.value
            rows = result
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct MutualView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var dxLocation = "IO91"
    @State private var minimumElevation = 0.0
    @State private var days = 10.0
    @State private var windows: [MutualWindowRecord] = []
    @State private var favoriteWindows: [FavoriteMutualWindow] = []
    @State private var allFavorites = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var reportStatus = ""
    @State private var computedAt = Date()
    @State private var seededMinEl = false
    @State private var dxDopplerWindow: MutualWindowRecord?
    @State private var skyPlotWindowID: Date?

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Form {
                Section("DX station") {
                    TextField("Grid or lat,lon", text: $dxLocation)
                        .textInputAutocapitalization(.characters)
                        .textFieldStyle(.odField)
                    Picker("Minimum elevation", selection: $minimumElevation) {
                        Text("0°").tag(0.0)
                        Text("5°").tag(5.0)
                        Text("10°").tag(10.0)
                    }
                    .onAppear { if !seededMinEl { minimumElevation = store.preferences.minElevation; seededMinEl = true } }
                    Picker("Horizon", selection: $days) {
                        Text("3 days").tag(3.0)
                        Text("7 days").tag(7.0)
                        Text("10 days").tag(10.0)
                    }
                    Picker("Scope", selection: $allFavorites) {
                        Text("Selected satellite").tag(false)
                        Text("All favorites").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Button("Compute mutual windows") { compute() }
                        .disabled(isLoading || (!allFavorites && store.selectedSatellite == nil))
                        .onChange(of: store.preferences.selectedNorad) { _, _ in
                            windows = []; favoriteWindows = []; error = nil; shareURL = nil; reportStatus = ""
                        }
                        .onChange(of: allFavorites) { _, _ in
                            windows = []; favoriteWindows = []; error = nil; shareURL = nil; reportStatus = ""
                        }
                }

                if isLoading {
                    Section { HStack { Spacer(); ProgressView("Computing…"); Spacer() } }
                } else if let error {
                    Section { Text(error).foregroundStyle(.red) }
                } else if allFavorites, !favoriteWindows.isEmpty {
                    Section("\(favoriteWindows.count) windows across favorites") {
                        ForEach(favoriteWindows) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.satelliteName).font(.headline)
                                    Spacer()
                                    Text(ODFormat.duration(entry.window.duration)).font(.caption.monospaced())
                                }
                                Text("\(ODFormat.utcShort.string(from: entry.window.start)) → \(ODFormat.utcShort.string(from: entry.window.end))")
                                    .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                HStack {
                                    Text(String(format: "Home max %.0f°", entry.window.myMaxElevation))
                                    Spacer()
                                    Text(String(format: "DX max %.0f°", entry.window.dxMaxElevation))
                                }
                                .font(.caption.monospaced()).foregroundStyle(ODTheme.accent)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else if !windows.isEmpty {
                    Section("Mutual windows") {
                        ForEach(windows) { window in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(ODFormat.utcShort.string(from: window.start)).font(.headline.monospaced())
                                    Spacer()
                                    Text(ODFormat.duration(window.duration)).font(.caption.monospaced())
                                }
                                Text("End \(ODFormat.utcShort.string(from: window.end))")
                                    .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                HStack {
                                    Text(String(format: "Home max %.0f°", window.myMaxElevation))
                                    Spacer()
                                    Text(String(format: "DX max %.0f°", window.dxMaxElevation))
                                }
                                .font(.caption.monospaced())
                                .foregroundStyle(ODTheme.accent)
                                HStack {
                                    Button { skyPlotWindowID = (skyPlotWindowID == window.id) ? nil : window.id } label: {
                                        Label(skyPlotWindowID == window.id ? "Hide sky plots" : "Sky plots",
                                              systemImage: "scope")
                                    }
                                    .font(.caption).buttonStyle(.bordered)
                                    if store.selectedSatellite?.transponders.isEmpty == false {
                                        Button { dxDopplerWindow = window } label: {
                                            Label("DX Doppler", systemImage: "waveform.path.ecg")
                                        }
                                        .font(.caption).buttonStyle(.bordered)
                                    }
                                }
                                if skyPlotWindowID == window.id {
                                    pairedSkyPlots(for: window)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        Button { Task { await prepareReport() } } label: {
                            Label("Prepare mutual-windows PDF", systemImage: "doc.richtext")
                        }
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share mutual-windows PDF", systemImage: "square.and.arrow.up")
                            }
                        }
                        if !reportStatus.isEmpty {
                            Text(reportStatus).font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    }
                }
            }
        }
        .sheet(item: $dxDopplerWindow) { window in
            dxDopplerSheet(for: window)
        }
    }

    /// Paired home/DX sky-track polar plots for a mutual window, so the operator
    /// can see where to point at each end simultaneously.
    @ViewBuilder
    private func pairedSkyPlots(for window: MutualWindowRecord) -> some View {
        if let sat = store.selectedSatellite, let parsed = FeatureEngine.parseLocation(dxLocation) {
            let dx = ObserverSite(name: dxLocation, latitude: parsed.latitude,
                                  longitude: parsed.longitude, altitudeMeters: 0)
            let home = store.preferences.observer
            let homeTrack = (try? DXDopplerEngine.skyTrack(satellite: sat, observer: home, window: window)) ?? []
            let dxTrack = (try? DXDopplerEngine.skyTrack(satellite: sat, observer: dx, window: window)) ?? []
            ViewThatFits {
                HStack(spacing: 12) {
                    ActivationSkyPlot(title: home.name.isEmpty ? "Home" : home.name, points: homeTrack)
                    ActivationSkyPlot(title: dxLocation, points: dxTrack)
                }
                VStack(spacing: 12) {
                    ActivationSkyPlot(title: home.name.isEmpty ? "Home" : home.name, points: homeTrack)
                    ActivationSkyPlot(title: dxLocation, points: dxTrack)
                }
            }
            .padding(.top, 4)
        } else {
            Text("Enter a valid DX grid or lat,lon to plot the paired sky tracks.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    @ViewBuilder
    private func dxDopplerSheet(for window: MutualWindowRecord) -> some View {
        if let sat = store.selectedSatellite, let parsed = FeatureEngine.parseLocation(dxLocation) {
            DXDopplerSheet(satellite: sat, home: store.preferences.observer,
                           dx: ObserverSite(name: dxLocation, latitude: parsed.latitude,
                                            longitude: parsed.longitude, altitudeMeters: 0),
                           window: window, store: store)
        } else {
            Text("DX Doppler needs a valid DX location and a selected satellite.").padding()
        }
    }

    @MainActor
    private func prepareReport() async {
        guard let satellite = store.selectedSatellite,
              let parsed = FeatureEngine.parseLocation(dxLocation) else {
            reportStatus = FeatureEngineError.invalidLocation.localizedDescription
            return
        }
        let home = store.preferences.observer
        let dx = ObserverSite(name: dxLocation, latitude: parsed.latitude, longitude: parsed.longitude, altitudeMeters: 0)
        let minEl = minimumElevation, horizon = days, start = computedAt
        isLoading = true; defer { isLoading = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try OrbitExportService.mutualWindowsReportPDF(
                    satellite: satellite, home: home, dx: dx, minimumElevation: minEl,
                    days: horizon, generatedAt: start
                )
            }.value
            let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            shareURL = try OrbitExportService.temporaryFile(name: "mutual_windows_\(base).pdf", data: data)
            reportStatus = "Prepared the mutual-window table and paired sky plots."
        } catch { reportStatus = error.localizedDescription }
    }

    private func compute() {
        guard let parsed = FeatureEngine.parseLocation(dxLocation) else {
            error = FeatureEngineError.invalidLocation.localizedDescription
            return
        }
        let home = store.preferences.observer
        let dx = ObserverSite(name: dxLocation, latitude: parsed.latitude,
                              longitude: parsed.longitude, altitudeMeters: 0)
        let minEl = minimumElevation
        let horizon = days
        let start = Date()
        computedAt = start
        shareURL = nil
        reportStatus = ""
        error = nil
        windows = []
        favoriteWindows = []

        if allFavorites {
            let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
            guard !favorites.isEmpty else { error = "No favorite satellites. Star some in the Satellites screen first."; return }
            isLoading = true
            Task {
                let merged = await Task.detached(priority: .userInitiated) { () -> [FavoriteMutualWindow] in
                    var out: [FavoriteMutualWindow] = []
                    for sat in favorites {
                        if let windows = try? FeatureEngine.mutualWindows(sat, home: home, dx: dx, from: start, days: horizon, minimumElevation: minEl) {
                            out.append(contentsOf: windows.map { FavoriteMutualWindow(satelliteName: sat.name, window: $0) })
                        }
                    }
                    return out.sorted { $0.window.start < $1.window.start }
                }.value
                favoriteWindows = merged
                if merged.isEmpty { error = "No mutual windows for any favorite in this horizon." }
                isLoading = false
            }
            return
        }

        guard let satellite = store.selectedSatellite else {
            error = "Select a satellite first."
            return
        }
        isLoading = true
        Task {
            do {
                let value = try await Task.detached {
                    try FeatureEngine.mutualWindows(satellite, home: home, dx: dx,
                                                    from: start, days: horizon, minimumElevation: minEl)
                }.value
                windows = value
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Workable grids

struct WorkableView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var acrossPass = false
    @State private var kind = "grids"
    @State private var filter = ""
    @State private var snapshot = WorkableSetSnapshot(grids: [], states: [], dxcc: [])
    @State private var isLoading = false
    @State private var error: String?

    private func items(from snapshot: WorkableSetSnapshot) -> [String] {
        switch kind { case "states": snapshot.states; case "dxcc": snapshot.dxcc; default: snapshot.grids }
    }
    private func filtered(from snapshot: WorkableSetSnapshot) -> [String] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let all = items(from: snapshot)
        return q.isEmpty ? all : all.filter { $0.uppercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            VStack(spacing: 14) {
                Picker("Mode", selection: $acrossPass) { Text("Live footprint").tag(false); Text("Across next pass").tag(true) }.pickerStyle(.segmented)
                Picker("Workable", selection: $kind) { Text("Grids").tag("grids"); Text("US states").tag("states"); Text("DXCC").tag("dxcc") }.pickerStyle(.segmented)
                TextField(kind == "dxcc" ? "Filter prefix/entity" : "Filter", text: $filter)
                    .textInputAutocapitalization(.characters).textFieldStyle(.odField)

                // A single, structurally-stable TimelineView drives both modes so
                // toggling Live/Across doesn't swap the view tree (which briefly
                // collapsed the NavigationSplitView detail back to Home). In Live
                // mode it recomputes the current-sub-point footprint each second
                // (a cheap point-in-footprint scan); in Across mode it just shows
                // the precomputed pass snapshot (the tick is a no-op re-read).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let display: WorkableSetSnapshot = {
                        if !acrossPass, let satellite = store.selectedSatellite {
                            return (try? ParityPlanningEngine.workableNow(satellite, at: context.date))
                                ?? WorkableSetSnapshot(grids: [], states: [], dxcc: [])
                        }
                        return snapshot
                    }()
                    resultsSection(display)
                }

                Text("DXCC uses 340 bundled reference points. State and entity results are point-based footprint tests rather than political-boundary polygon intersections.").font(.caption).foregroundStyle(ODTheme.muted)
            }.padding()
        }
        .onChange(of: acrossPass) { _, isAcross in if isAcross { compute() } }
        .onChange(of: store.preferences.selectedNorad) { _, _ in if acrossPass { compute() } }
    }

    @ViewBuilder private func resultsSection(_ snapshot: WorkableSetSnapshot) -> some View {
        let all = items(from: snapshot)
        let shown = filtered(from: snapshot)
        VStack(spacing: 12) {
            HStack {
                Text("\(all.count) workable").font(.headline)
                Spacer()
                if !filter.isEmpty { Text("\(shown.count) matching").foregroundStyle(ODTheme.muted) }
            }
            if acrossPass && isLoading {
                ProgressView("Scanning next pass…").padding()
            } else if acrossPass, let error {
                Text(error).foregroundStyle(.red).padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == "dxcc" ? 190 : 76), spacing: 6)], spacing: 6) {
                        ForEach(shown, id: \.self) { item in
                            Text(item).font(kind == "grids" ? .body.monospaced().bold() : .body).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: kind == "dxcc" ? .leading : .center).padding(.vertical, 7).padding(.horizontal, 6).background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }
    }

    /// Computes the across-next-pass footprint union (the heavier scan). Live
    /// footprint mode recomputes inline via the TimelineView above.
    private func compute() {
        guard let satellite = store.selectedSatellite else { return }
        let site = store.preferences.observer, minEl = store.preferences.minElevation
        isLoading = true
        error = nil
        // Run the heavy footprint scan off the main actor, but publish the result
        // (and the loading/error state) back ON the main actor. compute() is a
        // nonisolated View method, so a plain `Task {}` here would run its body —
        // and the `snapshot` @State write — on a background thread, which does not
        // reliably invalidate the view. That is what left this view stuck at
        // "0 workable" once the incidental periodic re-renders were removed.
        Task { @MainActor in
            do {
                snapshot = try await Task.detached {
                    try ParityPlanningEngine.workableAcrossNextPass(satellite, observer: site, minimumElevation: minEl)
                }.value
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

// MARK: - Planning

private enum PlanningMode: String, CaseIterable, Identifiable {
    case work = "Work target"
    case horizon = "Workable horizon"
    case search = "Target search"
    case visible = "Visible passes"
    case satSat = "Sat ↔ Sat"
    case rove = "Rove"
    case trust = "Element trust"
    case mask = "Horizon mask"
    var id: String { rawValue }
}

struct PlanningView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var mode: PlanningMode = .work
    @State private var targetKind = "grid"
    @State private var target = "FN31"
    @State private var hours = 72.0
    @State private var workResults: [TargetWindowRecord] = []
    @State private var horizonDays = 10
    @State private var horizonGrids = false
    @State private var horizonResult: WorkableHorizonSnapshot?
    @State private var searchDays = 10
    @State private var searchResults: [PlanningSearchHit] = []
    @State private var visibleResults: [VisiblePassRecord] = []
    @State private var secondaryNorad: UInt?
    @State private var losHours = 24.0
    @State private var losWindows: [SatelliteLOSWindow] = []
    @State private var roveLocation = ""
    @State private var roveHours = 24.0
    @State private var roveResults: [RovePassRecord] = []
    @State private var mask = HorizonMask()
    @State private var trimmedPasses: [(PredictedPass, Date, Date)] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var planningExportURL: URL?
    @State private var planningPDFURL: URL?
    @State private var planningExportName = "Planning CSV"

    private var favorites: [SatelliteRecord] {
        store.satellites.filter { store.preferences.favorites.contains($0.id) }
    }
    private var secondary: SatelliteRecord? {
        guard let secondaryNorad else { return nil }
        return store.satellites.first { $0.id == secondaryNorad }
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Form {
                Section {
                    Picker("Planning", selection: $mode) {
                        ForEach(PlanningMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                    if isLoading { ProgressView("Computing…") }
                    if let error { Text(error).foregroundStyle(ODTheme.warning) }
                }
                content
                if canExportPlanningResult {
                    Section("Share / export") {
                        HStack {
                            Button("Prepare CSV") { preparePlanningExport() }
                            Button("Prepare PDF") { preparePlanningPDF() }
                        }
                        if let planningExportURL {
                            ShareLink(item: planningExportURL) {
                                Label("Share \(planningExportName)", systemImage: "square.and.arrow.up")
                            }
                        }
                        if let planningPDFURL {
                            ShareLink(item: planningPDFURL) {
                                Label("Share planning PDF", systemImage: "doc.richtext")
                            }
                        }
                        Text("Exports use the same computed rows shown by this Planning mode; recompute after changing a target, horizon, stop, second satellite, or mask.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        }
        .onChange(of: mode) { _, _ in planningExportURL = nil; planningPDFURL = nil }
        .onChange(of: store.preferences.selectedNorad) { _, _ in
            workResults = []; visibleResults = []; losWindows = []; roveResults = []
            searchResults = []; horizonResult = nil; trimmedPasses = []
            planningExportURL = nil; planningPDFURL = nil; error = nil
        }
        .onAppear {
            if roveLocation.isEmpty {
                let o = store.preferences.observer
                roveLocation = FeatureEngine.latLonToGrid6(latitude: o.latitude, longitude: o.longitude)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .work:
            Section("Work a target through selected satellite") {
                targetEditor
                Picker("Search horizon", selection: $hours) {
                    Text("24 hours").tag(24.0); Text("72 hours").tag(72.0); Text("7 days").tag(168.0)
                }
                Button("Find simultaneous-footprint windows") { computeWork() }.disabled(isLoading || store.selectedSatellite == nil)
                ForEach(workResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ODFormat.utcShort.string(from: result.start)).font(.headline.monospaced())
                        Text("\(ODFormat.duration(result.duration)) • footprint margin \(String(format: "%.1f°", result.marginDegrees))").font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                    }
                }
                Text("A window is listed only when both your QTH and the target reference point are inside the satellite footprint at the same time.").font(.caption).foregroundStyle(ODTheme.muted)
            }
        case .horizon:
            Section("Union across favorite satellites") {
                Picker("Days", selection: $horizonDays) { Text("3").tag(3); Text("7").tag(7); Text("10").tag(10) }
                Toggle("Include Maidenhead grids", isOn: $horizonGrids)
                LabeledContent("Favorite satellites", value: "\(favorites.count)")
                Button("Compute workable horizon") { computeHorizon() }.disabled(isLoading || favorites.isEmpty)
                if let r = horizonResult {
                    LabeledContent("US states", value: "\(r.states.count)")
                    LabeledContent("DXCC entities", value: "\(r.dxcc.count)")
                    if horizonGrids {
                        // r.grids are 4-character grid squares (e.g. "FM18"). A grid
                        // field is the 2-character prefix ("FM"), so distinct fields
                        // are far fewer than squares — count them separately.
                        let fields = Set(r.grids.map { String($0.prefix(2)) }).count
                        LabeledContent("Grid fields", value: "\(fields)")
                        LabeledContent("Grid squares", value: "\(r.grids.count)")
                    }
                    LabeledContent("Passes sampled", value: "\(r.passCount)")
                    DisclosureGroup("States (\(r.states.count))") { Text(r.states.joined(separator: ", ")).font(.caption.monospaced()) }
                    DisclosureGroup("DXCC (\(r.dxcc.count))") { Text(r.dxcc.joined(separator: " • ")).font(.caption) }
                    if horizonGrids { DisclosureGroup("Grid squares (\(r.grids.count))") { Text(r.grids.joined(separator: " ")).font(.caption.monospaced()) } }
                }
            }
        case .search:
            Section("One target across all favorites") {
                targetEditor
                Picker("Days", selection: $searchDays) { Text("3").tag(3); Text("7").tag(7); Text("10").tag(10) }
                Button("Search favorite satellites") { computeSearch() }.disabled(isLoading || favorites.isEmpty)
                ForEach(searchResults) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.satelliteName).font(.headline)
                        Text(ODFormat.utc.string(from: row.start)).font(.caption.monospaced())
                        Text("\(ODFormat.duration(row.duration)) • max \(String(format: "%.0f°", row.maxElevation))").font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        case .visible:
            Section("Optically visible selected-satellite passes") {
                Button("Find next 7 days") { computeVisible() }.disabled(isLoading || store.selectedSatellite == nil)
                ForEach(visibleResults) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ODFormat.utc.string(from: row.pass.aos)).font(.headline.monospaced())
                        Text(String(format: "max %.0f° • est mag %.1f • best Sun %+.0f°", row.pass.maxElevation, row.bestEstimatedMagnitude, row.bestSunElevation)).font(.caption.monospaced())
                    }
                }
                Text("Visible means satellite sunlit, observer Sun ≤ −6°, and satellite ≥10°. Magnitude is a planning estimate; real spacecraft can flare or tumble.").font(.caption).foregroundStyle(ODTheme.muted)
            }
        case .satSat:
            Section("Satellite-to-satellite line of sight") {
                Picker("Second satellite", selection: $secondaryNorad) {
                    Text("Select…").tag(UInt?.none)
                    ForEach(store.satellites.prefix(2000)) { sat in Text(verbatim: "\(sat.name) · \(sat.id)").tag(UInt?.some(sat.id)) }
                }
                Picker("Horizon", selection: $losHours) { Text("6 h").tag(6.0); Text("12 h").tag(12.0); Text("24 h").tag(24.0); Text("48 h").tag(48.0) }
                Button("Find clear-Earth windows") { computeSatSat() }.disabled(isLoading || store.selectedSatellite == nil || secondary == nil)
                ForEach(losWindows) { w in
                    VStack(alignment: .leading) {
                        Text(ODFormat.utc.string(from: w.start)).font(.headline.monospaced())
                        Text("to \(ODFormat.utc.string(from: w.end)) • \(ODFormat.duration(w.duration))\(w.minRangeKm > 0 ? " • min range \(String(format: "%.0f km", w.minRangeKm))" : "")")
                            .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        case .rove:
            Section("Rove-stop opportunity scan") {
                TextField("Stop grid or lat,lon", text: $roveLocation).textInputAutocapitalization(.characters).textFieldStyle(.odField)
                Picker("Window", selection: $roveHours) { Text("12 h").tag(12.0); Text("24 h").tag(24.0); Text("48 h").tag(48.0) }
                Button("Scan favorites from this stop") { computeRove() }.disabled(isLoading || favorites.isEmpty)
                ForEach(roveResults) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.satelliteName).font(.headline)
                        Text("AOS \(ODFormat.utcShort.string(from: row.aos)) • max \(String(format: "%.0f°", row.maxElevation))").font(.caption.monospaced())
                        Text("\(row.states.count) states • \(row.dxcc.count) DXCC • \(row.grids.count) grids").font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        case .trust:
            if let satellite = store.selectedSatellite {
                let trust = FeatureEngine.elementTrust(satellite)
                Section("Element trust") {
                    LabeledContent("Element age", value: String(format: "%.1f days", trust.ageDays))
                    LabeledContent("Assessment", value: trust.level)
                    Text(trust.note).font(.caption).foregroundStyle(ODTheme.muted)
                }
            } else { Section { Text("Select a satellite first.") } }
        case .mask:
            if store.selectedSatellite != nil {
                Section("Local horizon mask") {
                    maskField("North", value: $mask.north); maskField("East", value: $mask.east); maskField("South", value: $mask.south); maskField("West", value: $mask.west)
                    Button("Apply to next passes") { computeMaskedPasses() }.disabled(isLoading)
                    ForEach(Array(trimmedPasses.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading) {
                            Text(ODFormat.utcShort.string(from: item.1)).font(.headline.monospaced())
                            Text("effective LOS \(ODFormat.utcShort.string(from: item.2)) • raw max \(String(format: "%.0f°", item.0.maxElevation))").font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                        }
                    }
                    Text("The four cardinal elevations are linearly interpolated around the horizon to approximate trees, buildings, or terrain, then applied to the next passes to trim effective AOS/LOS.").font(.caption).foregroundStyle(ODTheme.muted)
                }
            } else { Section { Text("Select a satellite first.") } }
        }
    }

    private var targetEditor: some View {
        Group {
            Picker("Target type", selection: $targetKind) {
                Text("Grid").tag("grid"); Text("US state").tag("state"); Text("DXCC").tag("dxcc"); Text("Lat,Lon").tag("ll")
            }
            TextField(targetKind == "dxcc" ? "Prefix or entity name" : "Target", text: $target).textInputAutocapitalization(.characters).textFieldStyle(.odField)
            if targetKind == "dxcc" && !target.isEmpty {
                let hits = DXCCData.search(target, limit: 5)
                ForEach(hits) { entity in Button("\(entity.prefix) · \(entity.name)") { target = entity.name }.font(.caption) }
            }
        }
    }

    private func maskField(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField("0", value: value, format: .number.precision(.fractionLength(0...1))).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).textFieldStyle(.odField).frame(width: 100); Text("°").foregroundStyle(ODTheme.muted) }
    }

    private func resolvedTarget() -> LatLon? { ParityPlanningEngine.targetLocation(kind: targetKind, value: target) }

    private var canExportPlanningResult: Bool {
        switch mode {
        case .work: return !workResults.isEmpty && store.selectedSatellite != nil
        case .horizon: return horizonResult != nil
        case .search: return !searchResults.isEmpty
        case .visible: return !visibleResults.isEmpty && store.selectedSatellite != nil
        case .satSat: return !losWindows.isEmpty && store.selectedSatellite != nil && secondary != nil
        case .rove: return !roveResults.isEmpty
        case .trust: return false
        case .mask: return !trimmedPasses.isEmpty && store.selectedSatellite != nil
        }
    }

    private func planningPayload() -> (csv: String, filename: String, label: String, title: String, subtitle: String)? {
        switch mode {
        case .work:
            guard let sat = store.selectedSatellite else { return nil }
            return (OrbitExportService.targetWindowsCSV(workResults, satellite: sat, target: target),
                    "work_target_\(sat.id).csv", "work-target CSV", "Work a target",
                    "\(sat.name) · target \(target) · simultaneous footprint windows")
        case .horizon:
            guard let result = horizonResult else { return nil }
            return (OrbitExportService.workableHorizonCSV(result, days: horizonDays),
                    "workable_horizon_\(horizonDays)d.csv", "workable-horizon CSV", "Workable horizon",
                    "Union across \(result.satelliteCount) favorite satellites over \(horizonDays) days")
        case .search:
            return (OrbitExportService.planningSearchCSV(searchResults, target: target, days: searchDays),
                    "target_search.csv", "target-search CSV", "Target search",
                    "\(target) across favorite satellites · \(searchDays)-day search")
        case .visible:
            guard let sat = store.selectedSatellite else { return nil }
            return (OrbitExportService.visiblePassesCSV(visibleResults, satellite: sat),
                    "visible_passes_\(sat.id).csv", "visible-passes CSV", "Optically visible passes",
                    "\(sat.name) · sunlit satellite, twilight observer and elevation filters")
        case .satSat:
            guard let first = store.selectedSatellite, let second = secondary else { return nil }
            return (OrbitExportService.satelliteLOSCSV(losWindows, first: first, second: second),
                    "sat_to_sat_\(first.id)_\(second.id).csv", "satellite-LOS CSV", "Satellite-to-satellite LOS",
                    "\(first.name) ↔ \(second.name) · clear-Earth line-of-sight windows")
        case .rove:
            return (OrbitExportService.rovePassesCSV(roveResults, stop: roveLocation),
                    "rove_opportunities.csv", "rove-opportunities CSV", "Rove opportunities",
                    "Stop \(roveLocation) · favorite-satellite footprint opportunities")
        case .trust:
            return nil
        case .mask:
            guard let sat = store.selectedSatellite else { return nil }
            return (OrbitExportService.horizonMaskedPassesCSV(trimmedPasses, satellite: sat, mask: mask),
                    "horizon_mask_\(sat.id).csv", "horizon-mask CSV", "Horizon-masked passes",
                    "\(sat.name) · N/E/S/W mask \(Int(mask.north))/\(Int(mask.east))/\(Int(mask.south))/\(Int(mask.west))°")
        }
    }

    private func preparePlanningExport() {
        do {
            guard let payload = planningPayload() else { return }
            planningExportName = payload.label
            planningExportURL = try OrbitExportService.temporaryTextFile(name: payload.filename, text: payload.csv)
        } catch { self.error = error.localizedDescription }
    }

    private func preparePlanningPDF() {
        do {
            guard let payload = planningPayload() else { return }
            let data = OrbitExportService.planningReportPDF(title: payload.title, subtitle: payload.subtitle, csvText: payload.csv)
            planningPDFURL = try OrbitExportService.temporaryFile(name: payload.filename.replacingOccurrences(of: ".csv", with: ".pdf"), data: data)
        } catch { self.error = error.localizedDescription }
    }

    private func computeWork() {
        guard let satellite = store.selectedSatellite, let location = resolvedTarget() else { error = FeatureEngineError.invalidLocation.localizedDescription; return }
        let observer = store.preferences.observer, horizon = hours
        begin()
        Task { do { workResults = try await Task.detached { try FeatureEngine.bestPassesForTarget(satellite, observer: observer, target: location, hours: horizon) }.value } catch { self.error = error.localizedDescription }; end() }
    }
    private func computeHorizon() {
        let favs=favorites, observer=store.preferences.observer, days=horizonDays, grids=horizonGrids
        begin(); Task { do { horizonResult = try await Task.detached { try ParityPlanningEngine.workableHorizon(favorites:favs,observer:observer,days:days,minimumElevation:5,includeGrids:grids) }.value } catch { self.error=error.localizedDescription }; end() }
    }
    private func computeSearch() {
        guard let location=resolvedTarget() else { error=FeatureEngineError.invalidLocation.localizedDescription; return }
        let favs=favorites, observer=store.preferences.observer, days=searchDays
        begin(); Task { do { searchResults = try await Task.detached { try ParityPlanningEngine.targetSearch(favorites:favs,observer:observer,target:location,days:days) }.value } catch { self.error=error.localizedDescription }; end() }
    }
    private func computeVisible() {
        guard let sat=store.selectedSatellite else{return}; let observer=store.preferences.observer
        begin(); Task { do { visibleResults = try await Task.detached { try ParityPlanningEngine.visiblePasses(satellite:sat,observer:observer) }.value } catch { self.error=error.localizedDescription }; end() }
    }
    private func computeSatSat() {
        guard let first=store.selectedSatellite,let second=secondary else{return};let h=losHours
        begin();Task{do{losWindows=try await Task.detached{try ParityPlanningEngine.satelliteLOSWindows(first:first,second:second,hours:h)}.value}catch{self.error=error.localizedDescription};end()}
    }
    private func computeRove() {
        guard let ll=FeatureEngine.parseLocation(roveLocation) else{error=FeatureEngineError.invalidLocation.localizedDescription;return}
        let favs=favorites,h=roveHours,stop=ObserverSite(name:"Rove",latitude:ll.latitude,longitude:ll.longitude,altitudeMeters:0)
        begin();Task{do{roveResults=try await Task.detached{try ParityPlanningEngine.rovePasses(favorites:favs,stop:stop,hours:h)}.value}catch{self.error=error.localizedDescription};end()}
    }
    private func computeMaskedPasses() {
        guard let sat=store.selectedSatellite else{return};let observer=store.preferences.observer,m=mask
        begin();Task{do{let passes=try await Task.detached{try OrbitPredictor.predictPasses(sat,observer:observer,from:.now,minElevation:0,maxCount:10,horizonDays:3)}.value;var rows:[(PredictedPass,Date,Date)]=[];for p in passes{if let x=try ParityPlanningEngine.trim(p,satellite:sat,observer:observer,mask:m){rows.append((p,x.0,x.1))}};trimmedPasses=rows}catch{self.error=error.localizedDescription};end()}
    }
    private func begin(){isLoading=true;error=nil}
    private func end(){isLoading=false}
}

// MARK: - Conjunctions

struct ConjunctionView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var secondaryNorad: UInt?
    @State private var horizonHours = 6.0
    @State private var thresholdKm = 800.0
    @State private var conjunctions: [ConjunctionRecord] = []
    @State private var neighbors: [OrbitalNeighbor] = []
    @State private var selectedEventID: Date?
    @State private var detail: ConjunctionDetailSnapshot?
    @State private var neighborhoodEpoch: Date = .now
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var shareLabel = ""

    private var secondary: SatelliteRecord? {
        guard let secondaryNorad else { return nil }
        return store.satellites.first { $0.id == secondaryNorad }
    }

    private var selectedEvent: ConjunctionRecord? {
        guard let selectedEventID else { return conjunctions.first }
        return conjunctions.first { $0.id == selectedEventID } ?? conjunctions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Form {
                Section("Pair screening") {
                    Picker("Second satellite", selection: $secondaryNorad) {
                        Text("Select…").tag(UInt?.none)
                        ForEach(store.satellites) { satellite in
                            if satellite.id != store.selectedSatellite?.id {
                                Text(verbatim: "\(satellite.name) · \(satellite.id)").tag(UInt?.some(satellite.id))
                            }
                        }
                    }
                    Picker("Horizon", selection: $horizonHours) {
                        Text("6 h").tag(6.0); Text("12 h").tag(12.0); Text("24 h").tag(24.0)
                    }
                    Picker("Alert threshold", selection: $thresholdKm) {
                        Text("100 km").tag(100.0); Text("500 km").tag(500.0)
                        Text("800 km").tag(800.0); Text("2000 km").tag(2000.0)
                    }
                    Button("Screen pair") { screenPair() }
                        .disabled(isLoading || store.selectedSatellite == nil || secondary == nil)
                    if !conjunctions.isEmpty, let primary = store.selectedSatellite, let secondary {
                        HStack {
                            Button("Prepare CSV") { preparePair(primary, secondary, pdf: false) }
                            Button("Prepare PDF") { preparePair(primary, secondary, pdf: true) }
                            if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") } }
                        }
                    }
                }

                if isLoading {
                    Section { HStack { Spacer(); ProgressView("Propagating…"); Spacer() } }
                } else if let error {
                    Section { Text(error).foregroundStyle(ODTheme.warning) }
                }

                if !conjunctions.isEmpty {
                    Section("Close approaches") {
                        ForEach(conjunctions) { item in
                            Button {
                                selectedEventID = item.id
                                computeDetail()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(ODFormat.utc.string(from: item.date)).font(.headline.monospaced())
                                        Text(String(format: "Δv %.3f km/s", item.relativeVelocityKmS))
                                            .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                    }
                                    Spacer()
                                    Text(String(format: "%.1f km", item.missDistanceKm))
                                        .font(.body.monospaced()).foregroundStyle(ODTheme.warning)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }

                if let detail, let primary = store.selectedSatellite, let secondary {
                    Section("TCA detail") {
                        LabeledContent("Closest approach", value: ODFormat.utc.string(from: detail.date))
                        LabeledContent("Miss distance", value: String(format: "%.3f km", detail.missDistanceKm))
                        LabeledContent("Relative velocity", value: String(format: "%.4f km/s", detail.relativeVelocityKmS))
                        LabeledContent("Separation rate at TCA", value: String(format: "%+.5f km/s", detail.closingRateKmS))
                        LabeledContent("\(primary.name) altitude", value: String(format: "%.1f km", detail.primaryAltitudeKm))
                        LabeledContent("\(secondary.name) altitude", value: String(format: "%.1f km", detail.secondaryAltitudeKm))
                        LabeledContent("Object speeds", value: String(format: "%.3f / %.3f km/s", detail.primarySpeedKmS, detail.secondarySpeedKmS))
                        Text(detail.awarenessLabel).font(.caption.bold()).foregroundStyle(ODTheme.warning)
                        Chart(detail.curve) { point in
                            LineMark(x: .value("Time", point.date), y: .value("Separation km", point.separationKm))
                        }
                        .frame(height: 190)
                        Text("±10 minutes around the screened TCA. Public GP elements are km-class data: this is an awareness curve, never collision-avoidance ephemeris.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }

                Section("Orbital neighborhood") {
                    Button("Compute nearest catalog objects now") { computeNeighborhood() }
                        .disabled(isLoading || store.selectedSatellite == nil)
                        .onChange(of: store.preferences.selectedNorad) { _, _ in
                            conjunctions = []; neighbors = []; detail = nil
                            selectedEventID = nil; shareURL = nil; error = nil
                        }
                    if !neighbors.isEmpty, let primary = store.selectedSatellite {
                        Button("Prepare neighborhood CSV") { prepareNeighborhood(primary) }
                        if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") } }
                    }
                    Text("Deep-parity scan evaluates the full loaded catalog, then ranks exact propagated 3-D separation and relative velocity at the same epoch.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }

                if !neighbors.isEmpty {
                    Section("Nearest now") {
                        ForEach(neighbors) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.headline)
                                    Text(verbatim: "NORAD \(item.id)").font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(ODFormat.distance(item.rangeKm)).font(.body.monospaced())
                                    Text(String(format: "Δv %.2f km/s", item.relativeVelocityKmS))
                                        .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Public GP elements are km-class accurate: a small miss distance means “look closer,” never a confirmed conjunction. Awareness, not avoidance.")
                        .font(.caption).foregroundStyle(ODTheme.warning)
                }
            }
            .onChange(of: secondaryNorad) {
                conjunctions = []; selectedEventID = nil; detail = nil; shareURL = nil
            }
        }
    }

    private func screenPair() {
        guard let primary = store.selectedSatellite, let secondary else { return }
        let horizon = horizonHours, threshold = thresholdKm
        isLoading = true; error = nil; conjunctions = []; detail = nil; shareURL = nil
        Task {
            do {
                conjunctions = try await Task.detached {
                    try FeatureEngine.screenConjunctions(primary: primary, secondary: secondary,
                                                          hours: horizon, thresholdKm: threshold)
                }.value
                selectedEventID = conjunctions.first?.id
                computeDetail()
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private func computeDetail() {
        guard let primary = store.selectedSatellite, let secondary, let event = selectedEvent else {
            detail = nil; return
        }
        Task {
            do {
                detail = try await Task.detached {
                    try FeatureCompletionEngine.conjunctionDetail(primary: primary, secondary: secondary, event: event)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }

    private func computeNeighborhood() {
        guard let primary = store.selectedSatellite else { return }
        let candidates = store.satellites.filter { $0.id != primary.id }
        let epoch = Date.now
        neighborhoodEpoch = epoch
        isLoading = true; error = nil; neighbors = []; shareURL = nil
        Task {
            do {
                neighbors = try await Task.detached {
                    try FeatureEngine.orbitalNeighborhood(primary: primary, others: candidates,
                                                           at: epoch, maxResults: 15)
                }.value
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    @MainActor
    private func preparePair(_ primary: SatelliteRecord, _ secondary: SatelliteRecord, pdf: Bool) {
        do {
            if pdf {
                shareURL = try OrbitExportService.temporaryFile(name: "conjunction_\(primary.id)_\(secondary.id).pdf",
                    data: OrbitExportService.conjunctionsPDF(conjunctions, primary: primary, secondary: secondary,
                                                              hours: horizonHours, thresholdKm: thresholdKm))
                shareLabel = "PDF"
            } else {
                shareURL = try OrbitExportService.temporaryTextFile(name: "conjunction_\(primary.id)_\(secondary.id).csv",
                    text: OrbitExportService.conjunctionsCSV(conjunctions, primary: primary, secondary: secondary,
                                                              hours: horizonHours, thresholdKm: thresholdKm))
                shareLabel = "CSV"
            }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func prepareNeighborhood(_ primary: SatelliteRecord) {
        do {
            shareURL = try OrbitExportService.temporaryTextFile(name: "orbital_neighborhood_\(primary.id).csv",
                text: OrbitExportService.orbitalNeighborhoodCSV(neighbors, primary: primary, at: neighborhoodEpoch))
            shareLabel = "CSV"
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - AO-7 Mode

struct AO7View: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var fit: AO7FitResult?
    @State private var sunlightStart: Date?
    @State private var sunlightExact = false
    @State private var eclipsingNow: Bool?
    @State private var isLoading = false
    @State private var error: String?
    @State private var reportDays = 30

    private var ao7: SatelliteRecord? {
        store.satellites.first { $0.id == AO7Service.ao7Norad }
    }

    var body: some View {
        Form {
            Section("AO-7 power state") {
                if let ao7 {
                    LabeledContent("Catalog object", value: "\(ao7.name) · 7530")
                    if let eclipsingNow {
                        LabeledContent("Orbit illumination", value: eclipsingNow ? "Eclipse season" : "Continuous sunlight")
                    }
                    if let sunlightStart, eclipsingNow == false {
                        LabeledContent("Continuous since", value: ODFormat.utc.string(from: sunlightStart))
                        if !sunlightExact {
                            Text("Continuous sunlight began at least 120 days before the search epoch.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    }
                } else {
                    Text("AO-7 (NORAD 7530) is not in the current GP catalog. The AMSAT Amateur catalog normally includes it; update or change the GP source in Settings.")
                        .foregroundStyle(ODTheme.warning)
                }
            }

            if isLoading {
                Section { HStack { Spacer(); ProgressView("Analyzing AO-7…"); Spacer() } }
            } else if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let fit {
                Section("Mode timer fit") {
                    LabeledContent("Estimated mode", value: fit.modeName)
                    LabeledContent("Fitted half-cycle", value: ODFormat.duration(fit.periodSeconds))
                    LabeledContent("Next switch", value: ODFormat.utc.string(from: fit.nextSwitch))
                    LabeledContent("Time to switch", value: ODFormat.duration(fit.timeToSwitch))
                    LabeledContent("Agreement", value: String(format: "%.1f%%", fit.agreementPercent))
                    LabeledContent("Reports", value: "\(fit.observationCount) total · \(fit.positiveCount) heard · \(fit.negativeCount) not heard")
                    LabeledContent("Mode changes seen", value: String(fit.observedSwitchCount))
                    LabeledContent("Phase uncertainty", value: ODFormat.duration(fit.phaseUncertaintySeconds))
                    Text(fit.note)
                        .font(.caption)
                        .foregroundStyle(fit.nearBoundary ? ODTheme.warning : ODTheme.muted)
                }
            }

            Section {
                Picker("History window", selection: $reportDays) {
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                }
                .pickerStyle(.segmented)
                Button("Refresh AO-7 estimate") { refresh() }
                    .disabled(isLoading || ao7 == nil)
            } header: {
                Text("AMSAT report fit")
            } footer: {
                Text("OrbitDeck only treats the fitted A/B timer as meaningful during continuous sunlight; eclipse-season power cycling destroys timer phase.")
            }
        }
        .task { if fit == nil && ao7 != nil { refresh() } }
    }

    private func refresh() {
        guard let ao7 else { return }
        isLoading = true
        error = nil
        fit = nil
        let reportHours = reportDays * 24
        Task {
            do {
                let illumination = try await Task.detached {
                    let shadowed = try FeatureEngine.orbitEclipseSampleCount(ao7, at: .now)
                    let start = try FeatureEngine.continuousSunlightStart(ao7)
                    return (shadowed >= 2, start)
                }.value
                eclipsingNow = illumination.0
                if let start = illumination.1 {
                    sunlightStart = start.date
                    sunlightExact = start.exact
                } else {
                    sunlightStart = nil
                }
                if illumination.0 {
                    fit = nil
                } else {
                    fit = try await AO7Service.fetchAndFit(hours: reportHours, sinceSunlightStart: illumination.1?.date)
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Sky at a Glance

struct SkyGlanceView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var hours = 12.0
    @State private var minimumElevation = 5.0
    @State private var rows: [SkyGlanceRow] = []
    @State private var quietGap: (Date, Date)?
    @State private var isLoading = false
    @State private var error: String?
    @State private var seededMinEl = false

    private var favorites: [SatelliteRecord] {
        store.satellites.filter { store.preferences.favorites.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Window", selection: $hours) {
                    Text("6 h").tag(6.0)
                    Text("12 h").tag(12.0)
                    Text("24 h").tag(24.0)
                }
                .pickerStyle(.segmented)
                Picker("Minimum elevation", selection: $minimumElevation) {
                    Text("0°").tag(0.0)
                    Text("5°").tag(5.0)
                    Text("10°").tag(10.0)
                    Text("20°").tag(20.0)
                }
                .pickerStyle(.menu)
                Button("Refresh") { compute() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .onAppear { if !seededMinEl { minimumElevation = store.preferences.minElevation; seededMinEl = true } }

            if favorites.isEmpty {
                ContentUnavailableView("No favorite satellites", systemImage: "star",
                                       description: Text("Star satellites on the Satellites screen to build the all-favorites pass timeline."))
            } else if isLoading {
                Spacer(); ProgressView("Predicting \(favorites.count) favorites…"); Spacer()
            } else if let error {
                Spacer(); Text(error).foregroundStyle(.red).padding(); Spacer()
            } else {
                List {
                    if let quietGap, quietGap.1 > quietGap.0 {
                        Section("Quietest stretch") {
                            HStack {
                                Text(ODFormat.utcShort.string(from: quietGap.0)).font(.body.monospaced())
                                Image(systemName: "arrow.right")
                                Text(ODFormat.utcShort.string(from: quietGap.1)).font(.body.monospaced())
                                Spacer()
                                Text(ODFormat.duration(quietGap.1.timeIntervalSince(quietGap.0)))
                                    .foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                    Section("Upcoming favorite passes") {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(row.name).font(.headline)
                                    Spacer()
                                    Text("\(row.passes.count) pass\(row.passes.count == 1 ? "" : "es")")
                                        .font(.caption).foregroundStyle(ODTheme.muted)
                                }
                                if row.passes.isEmpty {
                                    Text("No pass in this window")
                                        .font(.caption).foregroundStyle(ODTheme.muted)
                                } else {
                                    ForEach(row.passes.prefix(4)) { pass in
                                        HStack {
                                            Circle()
                                                .fill(pass.maxElevation >= 45 ? ODTheme.good :
                                                      (pass.maxElevation >= 20 ? ODTheme.accent : ODTheme.warning))
                                                .frame(width: 8, height: 8)
                                            Text(ODFormat.utcShort.string(from: pass.aos)).font(.caption.monospaced())
                                            Spacer()
                                            Text(ODFormat.duration(pass.duration)).font(.caption.monospaced())
                                            Text(String(format: "%.0f°", pass.maxElevation)).font(.caption.monospaced().bold())
                                            if pass.aos > Date(), let satellite = store.satellites.first(where: { $0.id == row.id }) {
                                                PassAlarmButton(satellite: satellite, pass: pass,
                                                                observer: store.preferences.observer,
                                                                leadMinutes: store.preferences.passAlarmLeadMinutes ?? 10)
                                            } else {
                                                PassAlarmUnavailable()
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .task { if rows.isEmpty && !favorites.isEmpty { compute() } }
        .onChange(of: hours) { _, _ in compute() }
        .onChange(of: minimumElevation) { _, _ in compute() }
    }

    private func compute() {
        let favs = favorites
        guard !favs.isEmpty else { rows = []; quietGap = nil; return }
        let observer = store.preferences.observer
        let h = hours
        let minEl = minimumElevation
        let start = Date.now
        isLoading = true
        error = nil
        Task {
            do {
                let result = try await Task.detached {
                    let rows = try FeatureEngine.skyGlance(favorites: favs, observer: observer,
                                                           from: start, hours: h,
                                                           minimumElevation: minEl)
                    return (rows, FeatureEngine.longestQuietGap(rows: rows, start: start, hours: h))
                }.value
                rows = result.0
                quietGap = result.1
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Celestial bodies

struct CelestialView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var shareURL: URL?
    @State private var shareLabel = ""
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            TimelineView(.periodic(from: .now, by: 10)) { timeline in
                let points = FeatureEngine.skyObjects(site: store.preferences.observer,
                                                      at: timeline.date,
                                                      selectedSatellite: store.selectedSatellite)
                ScrollView {
                    VStack(spacing: 14) {
                        HStack {
                            Button("Prepare CSV") { prepare(points: points, date: timeline.date, pdf: false) }
                            Button("Prepare PDF") { prepare(points: points, date: timeline.date, pdf: true) }
                            if let shareURL {
                                ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") }
                            }
                            Spacer()
                        }
                        if let exportError { Text(exportError).font(.caption).foregroundStyle(ODTheme.warning) }

                        CelestialPolarPlot(points: points)
                            .frame(maxWidth: 620)
                            .padding()
                            .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 14))

                        LazyVStack(spacing: 1) {
                            ForEach(points.sorted { $0.elevation > $1.elevation }) { point in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(point.name).font(.headline)
                                        Text(point.category).font(.caption).foregroundStyle(ODTheme.muted)
                                    }
                                    Spacer()
                                    Text("\(ODFormat.angle(point.azimuth)) \(ODFormat.compass(point.azimuth))")
                                        .font(.caption.monospaced())
                                    Text(point.elevation >= 0 ? String(format: "%+.1f°", point.elevation) : "down")
                                        .font(.body.monospaced())
                                        .foregroundStyle(point.elevation >= 0 ? ODTheme.good : ODTheme.muted)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(ODTheme.panel.opacity(0.7))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Text("Shows the Sun, Moon, five planets, eight fixed cosmic radio sources, a high-galactic-latitude cold-sky reference, and the selected satellite when it can be propagated.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    .padding()
                }
            }
        }
    }

    @MainActor
    private func prepare(points: [CelestialPoint], date: Date, pdf: Bool) {
        do {
            if pdf {
                shareURL = try OrbitExportService.temporaryFile(
                    name: "celestial_bodies.pdf",
                    data: OrbitExportService.celestialBodiesPDF(points, observer: store.preferences.observer, at: date))
                shareLabel = "PDF"
            } else {
                shareURL = try OrbitExportService.temporaryTextFile(
                    name: "celestial_bodies.csv",
                    text: OrbitExportService.celestialBodiesCSV(points, observer: store.preferences.observer, at: date))
                shareLabel = "CSV"
            }
            exportError = nil
        } catch { exportError = error.localizedDescription }
    }
}

// MARK: - EME

struct EMEView: View {
    private enum EMETab: String, CaseIterable, Identifiable {
        case now = "Moon now"
        case bands = "Per-band"
        case plan = "90-day plan"
        case windows = "Common windows"
        var id: String { rawValue }
        /// Short label so the 4-way segmented control fits on iPhone.
        var short: String {
            switch self {
            case .now: "Now"
            case .bands: "Bands"
            case .plan: "90-day"
            case .windows: "Windows"
            }
        }
    }

    @EnvironmentObject private var store: OrbitStore
    @State private var tab: EMETab = .now
    @State private var frequencyMHz = 144.1
    @State private var dxLocation = ""
    @State private var hours = 48.0
    @State private var windows: [EMEWindowRecord] = []
    @State private var dxSite: ObserverSite?
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var shareLabel = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            let snapshot = FeatureEngine.emeSnapshot(site: store.preferences.observer,
                                                      frequencyMHz: frequencyMHz,
                                                      at: timeline.date)
            let bandRows = FeatureCompletionEngine.emeBandAnalysis(
                site: store.preferences.observer, at: timeline.date,
                solarFlux: store.spaceWeather?.flux)
            Form {
                Section {
                    Picker("EME view", selection: $tab) {
                        ForEach(EMETab.allCases) { item in Text(item.short).tag(item) }
                    }.pickerStyle(.segmented)
                }

                switch tab {
                case .now:
                    Section("Moon now") {
                        Picker("Band", selection: $frequencyMHz) {
                            Text("6 m · 50.2 MHz").tag(50.2)
                            Text("2 m · 144.1 MHz").tag(144.1)
                            Text("222 MHz").tag(222.1)
                            Text("70 cm · 432.1 MHz").tag(432.1)
                            Text("23 cm · 1296 MHz").tag(1296.0)
                            Text("13 cm · 2304.1 MHz").tag(2304.1)
                            Text("3 cm · 10368.1 MHz").tag(10368.1)
                        }
                        LabeledContent("Azimuth", value: "\(ODFormat.angle(snapshot.moonAzimuth)) \(ODFormat.compass(snapshot.moonAzimuth))")
                        LabeledContent("Elevation", value: String(format: "%+.1f°", snapshot.moonElevation))
                        LabeledContent("Distance", value: String(format: "%.0f km", snapshot.moonDistanceKm))
                        LabeledContent("Declination", value: String(format: "%+.1f°", FeatureCompletionEngine.moonDeclinationDegrees(at: timeline.date)))
                        LabeledContent("Path degradation", value: String(format: "%.2f dB", FeatureCompletionEngine.emePathDegradationDb(at: timeline.date)))
                        LabeledContent("Sun separation", value: String(format: "%.0f°", FeatureCompletionEngine.emeSunSeparationDegrees(site: store.preferences.observer, at: timeline.date)))
                        LabeledContent("Ground gain", value: FeatureCompletionEngine.emeGroundGainDescription(elevationDegrees: snapshot.moonElevation))
                    }
                    Section("EME path on \(String(format: "%.1f MHz", frequencyMHz))") {
                        LabeledContent("Total path loss", value: String(format: "%.1f dB", snapshot.pathLossDb))
                        LabeledContent("Self-echo Doppler", value: String(format: "%+.0f Hz", snapshot.selfEchoDopplerHz))
                        LabeledContent("Echo delay", value: String(format: "%.2f s", 2 * snapshot.moonDistanceKm / 299_792.458))
                        LabeledContent("Sky behind Moon", value: String(format: "%.0f K", FeatureCompletionEngine.emeSkyTemperatureK(at: timeline.date, frequencyMHz: frequencyMHz)))
                        LabeledContent("Libration spread", value: String(format: "%.1f Hz", FeatureCompletionEngine.emeLibrationSpreadHz(frequencyMHz: frequencyMHz)))
                        LabeledContent("Faraday rotation", value: String(format: "%.0f°", FeatureCompletionEngine.emeFaradayDegrees(frequencyMHz: frequencyMHz, solarFlux: store.spaceWeather?.flux)))
                        Text("Faraday and sky-background values are planning models. A Moon-Sun separation under roughly 10° can make weak echoes impractical.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }

                case .bands:
                    Section("Per-band analysis") {
                        HStack {
                            Button("Prepare CSV") { prepareBands(bandRows, date: timeline.date, pdf: false) }
                            Button("Prepare PDF") { prepareBands(bandRows, date: timeline.date, pdf: true) }
                            if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") } }
                        }
                        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                Text("Band").gridColumnAlignment(.leading)
                                Text("Doppler"); Text("Faraday"); Text("Sky K"); Text("Spread"); Text("Loss")
                            }
                            .font(.caption.bold().monospaced())
                            .foregroundStyle(ODTheme.muted)
                            Divider().gridCellColumns(6)
                            ForEach(bandRows) { row in
                                GridRow {
                                    Text(row.band).gridColumnAlignment(.leading)
                                    Text(String(format: "%+.0f Hz", row.dopplerHz))
                                    Text(String(format: "%.0f°", row.faradayDegrees))
                                    Text(String(format: "%.0f", row.skyTemperatureK))
                                    Text(String(format: "%.1f Hz", row.librationSpreadHz))
                                    Text(String(format: "%.1f dB", row.pathLossDb))
                                }
                                .font(.caption.monospaced())
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        Text("Faraday scales approximately as 1/f²; libration spread grows with frequency. Sky temperature includes a coarse galactic-plane excess behind the Moon.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }

                case .plan:
                    let plan = FeatureCompletionEngine.emePlan(from: timeline.date, days: 90)
                    Section("90-day plan") {
                        Text("Sampled at 12:00 UTC each day. Desktop’s ★ criterion is Moon declination > +15° and path degradation < 1 dB.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        ForEach(plan) { row in
                            HStack {
                                Text(ODFormat.utcDay.string(from: row.date)).font(.body.monospaced())
                                Spacer()
                                Text(String(format: "%+.1f°", row.declinationDegrees)).font(.caption.monospaced())
                                Text(String(format: "%.2f dB", row.degradationDb)).font(.caption.monospaced())
                                Text(String(format: "%.0f km", row.distanceKm)).font(.caption.monospaced())
                                if row.good { Image(systemName: "star.fill").foregroundStyle(ODTheme.good) }
                            }
                        }
                    }

                case .windows:
                    Section("Common-Moon visibility") {
                        TextField("Other station grid or lat,lon", text: $dxLocation)
                            .textInputAutocapitalization(.characters)
                            .textFieldStyle(.odField)
                        Picker("Window", selection: $hours) {
                            Text("24 h").tag(24.0); Text("48 h").tag(48.0); Text("72 h").tag(72.0)
                        }.pickerStyle(.segmented)
                        Button("Find windows") { computeWindows() }
                        if let error { Text(error).foregroundStyle(ODTheme.warning) }
                        if !windows.isEmpty, let dxSite {
                            Button("Prepare windows CSV") { prepareWindows(dxSite) }
                            if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") } }
                        }
                        ForEach(windows) { window in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ODFormat.utcShort.string(from: window.start)).font(.body.monospaced())
                                Text("to \(ODFormat.utcShort.string(from: window.end)) · \(ODFormat.duration(window.duration))")
                                    .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    private func computeWindows() {
        guard let parsed = FeatureEngine.parseLocation(dxLocation) else {
            error = FeatureEngineError.invalidLocation.localizedDescription
            windows = []; dxSite = nil; return
        }
        let dx = ObserverSite(name: dxLocation.uppercased(), latitude: parsed.latitude,
                              longitude: parsed.longitude, altitudeMeters: 0)
        error = nil; dxSite = dx; shareURL = nil
        windows = FeatureEngine.emeCommonWindows(home: store.preferences.observer, dx: dx, hours: hours)
    }

    @MainActor
    private func prepareBands(_ rows: [EMEBandAnalysisRow], date: Date, pdf: Bool) {
        do {
            if pdf {
                shareURL = try OrbitExportService.temporaryFile(name: "eme_analysis.pdf",
                    data: OrbitExportService.emeBandAnalysisPDF(rows, observer: store.preferences.observer, at: date))
                shareLabel = "PDF"
            } else {
                shareURL = try OrbitExportService.temporaryTextFile(name: "eme_analysis.csv",
                    text: OrbitExportService.emeBandAnalysisCSV(rows, observer: store.preferences.observer, at: date))
                shareLabel = "CSV"
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func prepareWindows(_ dx: ObserverSite) {
        do {
            shareURL = try OrbitExportService.temporaryTextFile(name: "eme_windows.csv",
                text: OrbitExportService.emeWindowsCSV(windows, home: store.preferences.observer, dx: dx))
            shareLabel = "CSV"; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Sun / Moon Transits

struct TransitsView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var bodyChoice = "both"
    @State private var separation = 1.0
    @State private var days = 7.0
    @State private var events: [TransitRecord] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Form {
                Section("Search") {
                    Picker("Body", selection: $bodyChoice) {
                        Text("Both").tag("both")
                        Text("Sun").tag("sun")
                        Text("Moon").tag("moon")
                    }
                    .pickerStyle(.segmented)
                    Picker("Within", selection: $separation) {
                        Text("0.5°").tag(0.5)
                        Text("1.0°").tag(1.0)
                        Text("2.0°").tag(2.0)
                        Text("5.0°").tag(5.0)
                    }
                    .pickerStyle(.segmented)
                    Picker("Window", selection: $days) {
                        Text("3 days").tag(3.0)
                        Text("7 days").tag(7.0)
                        Text("14 days").tag(14.0)
                    }
                    .pickerStyle(.segmented)
                    Button("Find approaches") { compute() }
                    if !events.isEmpty {
                        Button("Prepare CSV") { prepareCSV() }
                        if let shareURL {
                            ShareLink(item: shareURL) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                        }
                    }
                }

                Section("Approaches") {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let error {
                        Text(error).foregroundStyle(ODTheme.warning)
                    } else if events.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No approaches found in the selected window.")
                            Text("Disk transits from a fixed site are rare — a satellite often stays several degrees from the Sun/Moon for days. Widen “Within” (try 5°) or lengthen the window to see near-misses.")
                                .font(.caption)
                        }
                        .foregroundStyle(ODTheme.muted)
                    } else {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(event.body.capitalized).font(.headline)
                                    if event.isDiskTransit {
                                        Text("TRANSIT")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(ODTheme.good.opacity(0.2))
                                            .foregroundStyle(ODTheme.good)
                                            .clipShape(Capsule())
                                    } else {
                                        Text("near").font(.caption).foregroundStyle(ODTheme.muted)
                                    }
                                    Spacer()
                                    Text(String(format: "%.2f°", event.separationDegrees))
                                        .monospacedDigit().foregroundStyle(ODTheme.accent)
                                }
                                Text(ODFormat.utc.string(from: event.date)).font(.subheadline.monospaced())
                                Text(String(format: "Sat %.0f° az / %.0f° el • %.0f km",
                                            event.satelliteAzimuth, event.satelliteElevation, event.rangeKm))
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }

                Section {
                    Text("A disk transit is a closest approach inside the Sun or Moon's apparent radius (~0.25°). Wider settings also show near-misses useful for positioning a camera. Only encounters with the satellite and selected body above the horizon are included.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
        }
        .task(id: store.selectedSatellite?.id) { compute() }
        .onChange(of: bodyChoice) { _, _ in compute() }
        .onChange(of: separation) { _, _ in compute() }
        .onChange(of: days) { _, _ in compute() }
    }

    private func prepareCSV() {
        guard let satellite = store.selectedSatellite else { return }
        var rows = "body,disk_transit,separation_deg,utc,sat_az_deg,sat_el_deg,range_km\n"
        for event in events {
            rows += "\(event.body),\(event.isDiskTransit),\(String(format: "%.3f", event.separationDegrees)),\(ODFormat.utc.string(from: event.date)),\(String(format: "%.1f", event.satelliteAzimuth)),\(String(format: "%.1f", event.satelliteElevation)),\(String(format: "%.0f", event.rangeKm))\n"
        }
        let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        do {
            shareURL = try OrbitExportService.temporaryTextFile(name: "transits_\(base).csv", text: rows)
        } catch { self.error = error.localizedDescription }
    }

    private func compute() {
        guard let satellite = store.selectedSatellite else { events = []; return }
        isLoading = true; error = nil; shareURL = nil
        let observer = store.preferences.observer
        let bodyChoice = bodyChoice, separation = separation, days = days
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FeatureEngine.findTransits(satellite, observer: observer,
                                                   days: days, body: bodyChoice,
                                                   maximumSeparationDegrees: separation)
                }.value
                events = result
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

// MARK: - Orbital Zones

struct OrbitalZonesView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var zone: OrbitalZone = .saa
    @State private var hours = 0.0   // 0 = Auto (~4 orbits)
    @State private var result: OrbitalZoneResult?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Form {
                Section("Scan") {
                    Picker("Zone", selection: $zone) {
                        ForEach(OrbitalZone.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Window", selection: $hours) {
                        Text("Auto").tag(0.0); Text("6 h").tag(6.0); Text("24 h").tag(24.0); Text("48 h").tag(48.0)
                    }
                    .pickerStyle(.segmented)
                    Button("Scan zone") { scan() }
                }
                if isLoading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if let error {
                    Section { Text(error).foregroundStyle(ODTheme.warning) }
                } else if let result {
                    Section("Current state") {
                        LabeledContent("Zone", value: result.zone.rawValue)
                        LabeledContent("Now", value: result.inNow ? "IN ZONE" : "outside")
                        if zone == .innerBelt || zone == .outerBelt {
                            LabeledContent("L shell", value: String(format: "%.2f", result.shellL))
                            LabeledContent("B/B0", value: String(format: "%.1f", result.bRatio))
                        }
                        LabeledContent("Dwell", value: String(format: "%.1f min/day", result.dwellMinutesPerDay))
                        LabeledContent("Windows", value: "\(result.windows.count)")
                    }
                    Section("Upcoming windows") {
                        if result.windows.isEmpty {
                            Text("No zone entries in this scan.").foregroundStyle(ODTheme.muted)
                        }
                        ForEach(result.windows) { window in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ODFormat.utc.string(from: window.start)).font(.subheadline.monospaced())
                                Text("Exit \(ODFormat.utc.string(from: window.end)) • \(ODFormat.duration(window.duration))")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }
                Section {
                    Text("Radiation-belt classification uses a tilted centered-dipole approximation. Treat belt results as indicative near the belt horns and inside the SAA; SAA, polar-cap and eclipse classifications are geometric.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
        }
        .task(id: store.selectedSatellite?.id) { scan() }
        .onChange(of: zone) { _, _ in scan() }
    }

    private func scan() {
        guard let satellite = store.selectedSatellite else { result = nil; return }
        isLoading = true; error = nil
        // Auto (hours == 0) scales to ~4 orbits, clamped 3–36 h, like the desktop.
        let periodHours = satellite.meanMotionRevPerDay > 0 ? 24.0 / satellite.meanMotionRevPerDay : 1.5
        let effectiveHours = hours > 0 ? hours : max(3.0, min(36.0, 4.0 * periodHours))
        let zone = zone
        Task {
            do {
                result = try await Task.detached(priority: .userInitiated) {
                    try FeatureEngine.scanOrbitalZone(satellite, zone: zone, hours: effectiveHours)
                }.value
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

// MARK: - Astronomy

private struct EclipseGroundTrackPlot: View {
    let points: [EclipseGroundTrackPoint]
    let observer: ObserverSite

    var body: some View {
        Canvas { context, size in
            func map(_ latitude: Double, _ longitude: Double) -> CGPoint {
                CGPoint(x: (longitude + 180) / 360 * size.width,
                        y: (90 - latitude) / 180 * size.height)
            }
            var grid = Path()
            for lon in stride(from: -180.0, through: 180.0, by: 30.0) {
                let p1 = map(-90, lon), p2 = map(90, lon)
                grid.move(to: p1); grid.addLine(to: p2)
            }
            for lat in stride(from: -60.0, through: 60.0, by: 30.0) {
                let p1 = map(lat, -180), p2 = map(lat, 180)
                grid.move(to: p1); grid.addLine(to: p2)
            }
            context.stroke(grid, with: .color(ODTheme.grid.opacity(0.65)), lineWidth: 0.7)

            // Coastline base map (Natural Earth 110m; points are (lon, lat)).
            var coast = Path()
            for polyline in WorldMapData.coastlines {
                var prev: CGPoint?
                for (lon, lat) in polyline {
                    let p = map(lat, lon)
                    if let prev, abs(p.x - prev.x) < size.width * 0.45 {
                        coast.addLine(to: p)
                    } else {
                        coast.move(to: p)
                    }
                    prev = p
                }
            }
            context.stroke(coast, with: .color(ODTheme.mapLand), lineWidth: 0.7)

            var track = Path()
            var previous: CGPoint?
            for point in points {
                let p = map(point.latitude, point.longitude)
                if let previous, abs(p.x - previous.x) < size.width * 0.45 {
                    track.addLine(to: p)
                } else {
                    track.move(to: p)
                }
                previous = p
            }
            context.stroke(track, with: .color(ODTheme.warning), lineWidth: 2.2)

            let qth = map(observer.latitude, observer.longitude)
            context.fill(Path(ellipseIn: CGRect(x: qth.x-4, y:qth.y-4, width:8, height:8)), with:.color(ODTheme.good))
            context.draw(Text("QTH").font(.caption2).foregroundStyle(ODTheme.good), at: CGPoint(x:qth.x+16,y:qth.y-8))
        }
        .frame(height: 230)
        .background(ODTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Solar eclipse central shadow-axis ground track")
    }
}

struct AstronomyView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var tab = 0
    @State private var occultations: [OccultationRecord] = []
    @State private var appulses: [AppulseRecord] = []
    @State private var eclipses: [EclipseEventRecord] = []
    @State private var jupiterStorms: [JupiterStormWindow] = []
    @State private var eclipseTrackEventID: String?
    @State private var isLoading = false
    @State private var error: String?

    private let names = ["Meteor showers", "Jupiter", "Aurora", "Twilight",
                         "EME conditions", "Occultations", "Appulses", "Eclipses"]

    var body: some View {
        Form {
            Section {
                Picker("Astronomy", selection: $tab) {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                if isLoading { ProgressView("Computing \(names[tab])…") }
                if let error { Text(error).foregroundStyle(ODTheme.warning) }
            }
            content
            Section {
                Text("Planning precision: the native astronomy tools use the same low-precision Sun, Moon and planet models as the rest of OrbitDeck. They are suitable for deciding what to observe and when, but not for timing grazing occultations or eclipse contacts.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
        .task { await loadHeavyTab() }
        // `.task(id:)` does not reliably re-fire when `tab` (local Picker state)
        // changes in this view, so drive the heavy loads from an explicit onChange.
        .onChange(of: tab) { _, _ in Task { await loadHeavyTab() } }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case 0:
            let rows = FeatureEngine.meteorShowers(site: store.preferences.observer)
            Section("Major showers") {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(row.name).font(.headline); Spacer(); Text("ZHR \(row.zhr)").font(.caption.monospaced()).foregroundStyle(ODTheme.accent) }
                        Text(ODFormat.utc.string(from: row.peak)).font(.subheadline.monospaced())
                        Text(String(format: "Radiant %.0f° el • Moon %.0f%% illuminated", row.radiantElevation, row.moonIllumination * 100)).font(.caption).foregroundStyle(ODTheme.muted)
                        Text(row.verdict).font(.caption)
                    }
                }
            }
        case 1:
            let status = FeatureEngine.jupiterRadioStatus(site: store.preferences.observer)
            Section("Jupiter decametric status") {
                LabeledContent("CML (System III)", value: String(format: "%.1f°", status.cmlDegrees))
                LabeledContent("Io phase", value: String(format: "%.1f°", status.ioPhaseDegrees))
                LabeledContent("Jupiter", value: String(format: "%.1f° az / %+.1f° el", status.azimuth, status.elevation))
                LabeledContent("Status", value: status.verdict)
                Text("Io-controlled decametric work is normally concentrated around 15–30 MHz. The Jupiter screen and this tab share the same planetary model.").font(.caption).foregroundStyle(ODTheme.muted)
            }
            Section("Io-storm windows · next 14 days") {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if jupiterStorms.isEmpty {
                    Text("No Io-controlled windows with Jupiter above the horizon in the next 14 days.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                } else {
                    ForEach(jupiterStorms) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window.sources).font(.subheadline.bold())
                                Spacer()
                                Text(ODFormat.duration(window.duration)).font(.caption.monospaced())
                            }
                            Text("\(ODFormat.utcShort.string(from: window.start)) → \(ODFormat.utcShort.string(from: window.end))")
                                .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                            Text(String(format: "Peak Jupiter elevation %.0f°", window.peakElevation))
                                .font(.caption).foregroundStyle(ODTheme.accent)
                        }
                    }
                }
            }
        case 2:
            let outlook = AstronomyParityEngine.aurora(site: store.preferences.observer, kp: store.spaceWeather?.kp)
            Section("Aurora outlook") {
                LabeledContent("Magnetic latitude", value: String(format: "%.1f°", outlook.magneticLatitude))
                LabeledContent("Kp", value: outlook.kp.map { String(format: "%.1f", $0) } ?? "—")
                if let boundary = outlook.boundaryLatitude { LabeledContent("Oval boundary", value: String(format: "%.1f° magnetic", boundary)) }
                if let margin = outlook.marginDegrees { LabeledContent("Margin", value: String(format: "%+.1f°", margin)) }
                LabeledContent("Visual", value: outlook.visual)
                LabeledContent("Radio", value: outlook.radio)
                if store.spaceWeather?.kp == nil { Text("Refresh Space Wx to supply the current Kp value.").font(.caption).foregroundStyle(ODTheme.muted) }
            }
        case 3:
            let rows = FeatureEngine.twilightTimes(site: store.preferences.observer)
            Section("Today's UTC crossings") {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.label).font(.headline)
                        Text(String(format: "Sun altitude %.3g°", row.solarAltitude)).font(.caption).foregroundStyle(ODTheme.muted)
                        HStack { Text("Morning: \(row.morning.map { ODFormat.utc.string(from: $0) } ?? "—")"); Spacer(); Text("Evening: \(row.evening.map { ODFormat.utc.string(from: $0) } ?? "—")") }.font(.caption.monospaced())
                    }
                }
            }
        case 4:
            let snapshot = FeatureEngine.emeConditions()
            Section("EME conditions") {
                LabeledContent("Moon distance", value: String(format: "%.0f km", snapshot.distanceKm))
                LabeledContent("Perigee (30 d)", value: String(format: "%.0f km • %@", snapshot.perigeeKm, ODFormat.utcShort.string(from: snapshot.perigeeDate)))
                LabeledContent("Apogee (30 d)", value: String(format: "%.0f km • %@", snapshot.apogeeKm, ODFormat.utcShort.string(from: snapshot.apogeeDate)))
                LabeledContent("Path degradation", value: String(format: "%.2f dB vs perigee", snapshot.degradationDb))
                LabeledContent("Perigee–apogee swing", value: String(format: "%.2f dB", snapshot.swingDb))
                LabeledContent("Declination", value: String(format: "%+.1f°", snapshot.declinationDegrees))
            }
        case 5:
            Section("Lunar occultations — next year") {
                if !isLoading && occultations.isEmpty { Text("No bright-star or planet occultations/close approaches found above your horizon in the scan.").foregroundStyle(ODTheme.muted) }
                ForEach(occultations) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(row.target).font(.headline); Spacer(); Text(row.occultation ? "OCCULTATION" : "close approach").font(.caption.bold()).foregroundStyle(row.occultation ? ODTheme.good : ODTheme.muted) }
                        Text(ODFormat.utc.string(from: row.time)).font(.subheadline.monospaced())
                        Text(String(format: "separation %.3f° • lunar limb %.3f° • Moon %+.0f° el", row.separationDegrees, row.lunarSemidiameterDegrees, row.moonElevation)).font(.caption.monospaced())
                        Text(String(format: "%@ • limb margin %+.3f°", row.kind, row.lunarSemidiameterDegrees - row.separationDegrees)).font(.caption).foregroundStyle(ODTheme.muted)
                        if let ingress = row.ingress, let egress = row.egress {
                            Text("Ingress ~\(ODFormat.utcShort.string(from: ingress)) · egress ~\(ODFormat.utcShort.string(from: egress)) · \(ODFormat.duration(egress.timeIntervalSince(ingress)))")
                                .font(.caption2.monospaced()).foregroundStyle(ODTheme.muted)
                        }
                    }
                }
            }
        case 6:
            Section("Planet/Moon appulses — next year") {
                if !isLoading && appulses.isEmpty { Text("No pairings within 2° found in the scan.").foregroundStyle(ODTheme.muted) }
                ForEach(appulses) { row in
                    HStack { VStack(alignment: .leading) { Text("\(row.first) – \(row.second)").font(.headline); Text(ODFormat.utc.string(from: row.time)).font(.caption.monospaced()) }; Spacer(); Text(String(format: "%.2f°", row.separationDegrees)).monospacedDigit() }
                }
            }
        default:
            Section("Solar & lunar eclipses — next two years") {
                if !isLoading && eclipses.isEmpty { Text("No eclipse candidates found in the planning scan.").foregroundStyle(ODTheme.muted) }
                ForEach(eclipses) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("\(row.kind.capitalized) • \(row.className)").font(.headline); Spacer(); Text(row.visible ? "visible here" : "below horizon").font(.caption).foregroundStyle(row.visible ? ODTheme.good : ODTheme.muted) }
                        Text(ODFormat.utc.string(from: row.maxTime)).font(.subheadline.monospaced())
                        Text(String(format: "magnitude %.3f • altitude %+.0f° • min sep %.3f°", row.magnitude, row.elevation, row.minimumSeparationDegrees)).font(.caption.monospaced())
                        if let start = row.contactStart, let end = row.contactEnd {
                            Text("Main phase ~\(ODFormat.utcShort.string(from: start)) – \(ODFormat.utcShort.string(from: end)) · \(ODFormat.duration(end.timeIntervalSince(start)))")
                                .font(.caption2.monospaced()).foregroundStyle(ODTheme.muted)
                        }
                        if let start = row.centralStart, let end = row.centralEnd {
                            Text("Central/total phase ~\(ODFormat.utcShort.string(from: start)) – \(ODFormat.utcShort.string(from: end)) · \(ODFormat.duration(end.timeIntervalSince(start)))")
                                .font(.caption2.monospaced()).foregroundStyle(ODTheme.good)
                        }
                        if row.kind == "solar" {
                            Button(eclipseTrackEventID == row.id ? "Ground track selected" : "Show central-line ground track") { eclipseTrackEventID = row.id }
                                .font(.caption)
                        }
                    }
                }
                if let id = eclipseTrackEventID, let event = eclipses.first(where: { $0.id == id && $0.kind == "solar" }) {
                    let track = AstronomyParityEngine.eclipseGroundTrack(event)
                    if track.isEmpty {
                        Text("The shadow axis does not intersect Earth in the sampled window for this planning-model event.").font(.caption).foregroundStyle(ODTheme.muted)
                    } else {
                        EclipseGroundTrackPlot(points: track, observer: store.preferences.observer)
                        Text("Red: approximate central shadow-axis intersection with the spherical Earth, sampled around maximum. Green: your QTH. This is a planning visualization; authoritative eclipse circumstances should be used for contact timing and path-edge decisions.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        }
    }

    @MainActor private func loadHeavyTab() async {
        let selected = tab
        let site = store.preferences.observer
        if selected == 1 {
            isLoading = true; error = nil
            let value = await Task.detached(priority: .userInitiated) { FeatureEngine.jupiterStormWindows(site: site) }.value
            if tab == selected { jupiterStorms = value; isLoading = false }
            return
        }
        guard tab >= 5 else { isLoading = false; error = nil; return }
        isLoading = true; error = nil
        do {
            switch selected {
            case 5:
                let value = await Task.detached(priority: .userInitiated) { AstronomyParityEngine.occultations(site: site) }.value
                if tab == selected { occultations = value }
            case 6:
                let value = await Task.detached(priority: .userInitiated) { AstronomyParityEngine.appulses() }.value
                if tab == selected { appulses = value }
            default:
                let value = await Task.detached(priority: .userInitiated) { AstronomyParityEngine.eclipses(site: site) }.value
                if tab == selected {
                    eclipses = value
                    if eclipseTrackEventID == nil { eclipseTrackEventID = value.first(where: { $0.kind == "solar" })?.id }
                }
            }
        }
        if tab == selected { isLoading = false }
    }
}

// MARK: - Orbital History

struct OrbitalHistoryView: View {
    @EnvironmentObject private var store: OrbitStore
    @AppStorage("orbitdeck.spacetrack.identity") private var identity = ""
    @State private var password = ""
    @State private var selectedColumn: HistoryColumn = .apogee
    @State private var selectedTab: HistoryTab = .value
    @State private var showBothApsides = true
    @State private var samples: [OrbitalHistorySample] = []
    @State private var zoomLower = 0.0
    @State private var zoomUpper = 1.0
    @State private var decayEstimate: OrbitalHistoryDecayEstimate?
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var shareLabel = ""
    private static let service = SpaceTrackHistoryService()

    private enum HistoryTab: String, CaseIterable, Identifiable {
        case value = "Value", rate = "Rate", analysis = "Analysis", summary = "Summary"
        var id: String { rawValue }
    }

    private var visibleSamples: [OrbitalHistorySample] {
        FeatureEngine.historyWindow(samples, lower: zoomLower, upper: zoomUpper)
    }

    private var zoomLabel: String {
        if zoomLower == 0 && zoomUpper == 1 { return "full record" }
        return String(format: "showing %.0f%%–%.0f%% of record", zoomLower * 100, zoomUpper * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Form {
                Section("Archive") {
                    Picker("Element", selection: $selectedColumn) {
                        ForEach(HistoryColumn.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("View", selection: $selectedTab) {
                        ForEach(HistoryTab.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if selectedColumn == .apogee || selectedColumn == .perigee {
                        Toggle("Plot apogee + perigee together", isOn: $showBothApsides)
                    }
                    Button("Fetch history") { fetch() }
                        .disabled(isLoading || store.selectedSatellite == nil)
                    if identity.isEmpty || password.isEmpty {
                        Text("Set your Space-Track identity and password in Settings to fetch archival elements.")
                            .font(.caption).foregroundStyle(ODTheme.warning)
                    }
                    if isLoading { ProgressView() }
                    if let error { Text(error).foregroundStyle(ODTheme.warning) }
                    if !samples.isEmpty {
                        LabeledContent("Element sets", value: "\(samples.count)")
                        if let first = samples.first, let last = samples.last {
                            LabeledContent("Record", value: "\(ODFormat.utcShort.string(from: first.epoch)) – \(ODFormat.utcShort.string(from: last.epoch))")
                        }
                    }
                }

                if !samples.isEmpty {
                    Section("Time window") {
                        ViewThatFits {
                            HStack {
                                Button { adjustZoom(.out) } label: { Label("Wider", systemImage: "minus.magnifyingglass") }
                                Button { adjustZoom(.in) } label: { Label("Closer", systemImage: "plus.magnifyingglass") }
                                Button { adjustZoom(.left) } label: { Image(systemName: "chevron.left") }
                                Button { adjustZoom(.right) } label: { Image(systemName: "chevron.right") }
                                Button("Reset") { adjustZoom(.reset) }
                            }
                            VStack(alignment: .leading) {
                                HStack {
                                    Button { adjustZoom(.out) } label: { Label("Wider", systemImage: "minus.magnifyingglass") }
                                    Button { adjustZoom(.in) } label: { Label("Closer", systemImage: "plus.magnifyingglass") }
                                    Button("Reset") { adjustZoom(.reset) }
                                }
                                HStack {
                                    Button { adjustZoom(.left) } label: { Image(systemName: "chevron.left") }
                                    Button { adjustZoom(.right) } label: { Image(systemName: "chevron.right") }
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        Text(zoomLabel).font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                        Text("Value, rate and summary honor this time window. Analysis deliberately evaluates the whole archive.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }

                    if let decayEstimate {
                        Section("Archive-anchored decay") {
                            LabeledContent("Estimate", value: decayText(decayEstimate.days))
                            LabeledContent("Anchor", value: decayEstimate.source)
                            if let ndot = decayEstimate.fittedNdot {
                                LabeledContent("Archive fitted n-dot", value: String(format: "%.6g rev/day²", ndot))
                            }
                            Text(decayEstimate.note).font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    }

                    switch selectedTab {
                    case .value:
                        Section(selectedColumn.label) {
                            Chart {
                                if showBothApsides && (selectedColumn == .apogee || selectedColumn == .perigee) {
                                    ForEach(visibleSamples) { sample in
                                        if let value = sample.apogee {
                                            LineMark(x: .value("Epoch", sample.epoch), y: .value("Altitude", value),
                                                     series: .value("Apside", "Apogee"))
                                                .foregroundStyle(ODTheme.accent)
                                        }
                                        if let value = sample.perigee {
                                            LineMark(x: .value("Epoch", sample.epoch), y: .value("Altitude", value),
                                                     series: .value("Apside", "Perigee"))
                                                .foregroundStyle(ODTheme.warning)
                                        }
                                    }
                                } else {
                                    ForEach(visibleSamples) { sample in
                                        if let value = sample.value(selectedColumn) {
                                            LineMark(x: .value("Epoch", sample.epoch), y: .value(selectedColumn.label, value),
                                                     series: .value("Element", selectedColumn.label))
                                                .foregroundStyle(ODTheme.accent)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 300)
                            Text("\(visibleSamples.count) archived sets in the displayed time window.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    case .rate:
                        Section("\(selectedColumn.label) rate of change") {
                            let points = FeatureEngine.historyRateSeries(visibleSamples, column: selectedColumn)
                            if points.isEmpty {
                                Text("Not enough separated historical samples for a rate series.").foregroundStyle(ODTheme.muted)
                            } else {
                                Chart {
                                    RuleMark(y: .value("Zero", 0)).foregroundStyle(ODTheme.grid)
                                    ForEach(points) { point in
                                        LineMark(x: .value("Epoch", point.date), y: .value("Per year", point.ratePerYear))
                                            .foregroundStyle(ODTheme.accent)
                                    }
                                }.frame(minHeight: 300)
                                Text("Rates are expressed per year; pairs less than one hour apart are ignored to suppress near-zero-interval spikes.")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    case .analysis:
                        Section("Whole-record rate analysis") {
                            if let analysis = FeatureEngine.analyzeHistoryRate(samples, column: selectedColumn) {
                                Text(analysis.verdict).font(.headline)
                                LabeledContent("Early era mean", value: rateText(analysis.earlyMean))
                                LabeledContent("Late era mean", value: rateText(analysis.lateMean))
                                LabeledContent("Acceleration", value: String(format: "%+.5g/year²", analysis.accelerationPerYear))
                                LabeledContent("Median |rate|", value: rateText(analysis.medianAbsoluteRate))
                                LabeledContent("Peak |rate|", value: "\(rateText(analysis.peakRate)) · \(ODFormat.utcShort.string(from: analysis.peakDate))")
                                LabeledContent("Jumps (>5× baseline)", value: "\(analysis.jumps.count)")
                                LabeledContent("Intervals used", value: "\(analysis.intervalCount)")
                                if !analysis.jumps.isEmpty {
                                    Text("Largest jumps").font(.headline)
                                    ForEach(Array(analysis.jumps.sorted { abs($0.ratePerYear) > abs($1.ratePerYear) }.prefix(5))) { jump in
                                        Text("\(ODFormat.utcShort.string(from: jump.date))   \(rateText(jump.ratePerYear))")
                                            .font(.caption.monospaced())
                                    }
                                }
                                Text("A jump is a rate far above this object's own normal trend; it can represent a maneuver, a drag event, or an element-set discontinuity.")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            } else {
                                Text("Not enough data for whole-record analysis; at least four usable rate intervals are required.")
                                    .foregroundStyle(ODTheme.muted)
                            }
                        }
                    case .summary:
                        Section("Summary") {
                            ForEach(FeatureEngine.summarizeHistory(visibleSamples)) { summary in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(summary.column.label).font(.headline)
                                    Text(String(format: "first %.6g • last %.6g • Δ %+.6g", summary.first, summary.last, summary.delta))
                                        .font(.caption.monospaced())
                                    Text(String(format: "%+.6g/year • min %.6g • max %.6g • %d samples", summary.ratePerYear, summary.minimum, summary.maximum, summary.samples))
                                        .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                }
                            }
                        }
                    }

                    Section("Export current archive window") {
                        ViewThatFits {
                            HStack {
                                Button("Raw CSV") { prepareHistoryCSV() }
                                Button("Summary PDF") { prepareHistoryPDF() }
                            }
                            VStack(alignment: .leading) {
                                Button("Raw history CSV") { prepareHistoryCSV() }
                                Button("Printable summary PDF") { prepareHistoryPDF() }
                            }
                        }
                        if let shareURL {
                            ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                Section {
                    Text("Space-Track gp_history is archival data. OrbitDeck caches a successful fetch in Application Support and reloads it without another query. Blank historical cells remain missing rather than being interpreted as zero. The archive-decay anchor is used only when PERIOD spans at least six samples and 30 days with a positive mean-motion trend.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
        }
        .task { password = OrbitSecretStore.get(.spaceTrackPassword) }
        .task(id: store.selectedSatellite?.id) {
            zoomLower = 0; zoomUpper = 1; shareURL = nil
            samples = []; decayEstimate = nil; error = nil
            await loadCache()
        }
    }

    private enum ZoomAction { case `in`, out, left, right, reset }

    private func adjustZoom(_ action: ZoomAction) {
        var lo = zoomLower, hi = zoomUpper
        var span = hi - lo
        let center = (lo + hi) / 2
        switch action {
        case .reset: lo = 0; hi = 1
        case .in:
            span = max(0.02, span / 2); lo = center - span / 2; hi = center + span / 2
        case .out:
            span = min(1, span * 2); lo = center - span / 2; hi = center + span / 2
        case .left:
            let shift = -span / 4
            lo += shift; hi += shift
        case .right:
            let shift = span / 4
            lo += shift; hi += shift
        }
        if lo < 0 { hi -= lo; lo = 0 }
        if hi > 1 { lo -= hi - 1; hi = 1 }
        zoomLower = max(0, lo); zoomUpper = min(1, hi)
    }

    private func rateText(_ rate: Double) -> String {
        let unit = selectedColumn.unit.isEmpty ? "units" : selectedColumn.unit
        return String(format: "%+.5g %@/year", rate, unit)
    }

    private func decayText(_ days: Double) -> String {
        if days < 0 { return "no usable data" }
        if days.isInfinite || days >= 1e8 { return "effectively stable" }
        if days < 1 { return "< 1 day" }
        if days < 365.25 { return String(format: "%.0f days", days) }
        return String(format: "%.1f years", days / 365.25)
    }

    @MainActor private func updateDecay() {
        guard let sat = store.selectedSatellite, !samples.isEmpty else { decayEstimate = nil; return }
        decayEstimate = FeatureEngine.historyDecayEstimate(samples, satellite: sat)
    }

    private func loadCache() async {
        guard let sat = store.selectedSatellite else { samples = []; decayEstimate = nil; return }
        samples = await Self.service.cachedHistory(norad: sat.id) ?? []
        error = nil
        updateDecay()
    }

    private func fetch() {
        guard let sat = store.selectedSatellite else { return }
        isLoading = true; error = nil
        let identity = identity, password = password
        Task {
            do {
                samples = try await Self.service.fetchHistory(norad: sat.id, identity: identity, password: password)
                if samples.isEmpty { self.error = "Space-Track returned no archived elements for this object." }
                updateDecay()
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    @MainActor private func prepareHistoryCSV() {
        guard let sat = store.selectedSatellite, !visibleSamples.isEmpty else { return }
        do {
            let base = sat.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            shareURL = try OrbitExportService.temporaryTextFile(name: "orbital_history_\(base).csv", text: OrbitExportService.orbitalHistorySamplesCSV(visibleSamples))
            shareLabel = "history CSV"
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func prepareHistoryPDF() {
        guard let sat = store.selectedSatellite, !samples.isEmpty else { return }
        do {
            let base = sat.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            let data = OrbitExportService.orbitalHistoryReportPDF(samples, satellite: sat, lower: zoomLower, upper: zoomUpper)
            shareURL = try OrbitExportService.temporaryFile(name: "orbital_history_\(base).pdf", data: data)
            shareLabel = "history summary PDF"
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Space Weather

struct SpaceWeatherView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var isLoading = false

    var body: some View {
        Form {
            Section("Solar & geomagnetic indices") {
                Button("Refresh") { refresh() }.disabled(isLoading)
                if isLoading { ProgressView() }
                if let snapshot = store.spaceWeather {
                    LabeledContent("F10.7 solar flux", value: snapshot.flux.map { String(format: "%.1f sfu — %@", $0, snapshot.fluxLabel) } ?? "—")
                    LabeledContent("Sunspot number", value: snapshot.sunspotNumber.map { String(format: "%.0f", $0) } ?? "—")
                    if let mean = snapshot.flux90Day { LabeledContent("F10.7 90-day mean", value: String(format: "%.1f sfu", mean)) }
                    LabeledContent("Planetary Kp", value: snapshot.kp.map { String(format: "%.2f — %@", $0, snapshot.kpLabel) } ?? "—")
                    LabeledContent("Aurora likelihood", value: auroraLikelihood(kp: snapshot.kp))
                    LabeledContent((snapshot.aIndexSource?.contains("planetary A") ?? false) ? "Planetary A" : "A / ap equivalent", value: snapshot.aIndex.map { String(format: "%.0f", $0) } ?? "—")
                    if let source = snapshot.aIndexSource { LabeledContent("A-index source", value: source) }
                    LabeledContent("Fetched", value: ODFormat.utc.string(from: snapshot.fetchedAt))
                }
            }
            if let snapshot = store.spaceWeather {
                Section("Operating outlook") {
                    Text(snapshot.outlook)
                }
            }
            Section {
                Text("F10.7 and planetary Kp are fetched from NOAA SWPC public feeds; the sunspot number matches the N0NBH/hamqsl solar widget most operators reference (NOAA's SESC daily count is the fallback). OrbitDeck also reads NOAA's Daily Geomagnetic Data and uses its reported planetary 24-hour A index when available; Kp→ap is retained as a fallback.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
        .task {
            isLoading = (store.spaceWeather == nil)
            await store.refreshSpaceWeatherIfNeeded()
            isLoading = false
        }
    }

    /// Kp-derived aurora visibility outlook (matches the desktop's guidance bands).
    private func auroraLikelihood(kp: Double?) -> String {
        guard let kp else { return "—" }
        if kp >= 7 { return "High — possible to mid-latitudes" }
        if kp >= 5 { return "Elevated — high-latitude aurora likely" }
        if kp >= 4 { return "Minor — possible high-latitude aurora" }
        return "Low"
    }

    private func refresh() {
        isLoading = true
        Task {
            await store.refreshSpaceWeather()
            isLoading = false
        }
    }
}

// MARK: - AMSAT Status

// The interactive 0.4 implementation is below the new-launch screen.

// MARK: - New Launches

struct NewLaunchesView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var filterNoise = true
    @State private var allHits: [NewLaunchHit] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var hasScanned = false
    @State private var shareURL: URL?
    @State private var shareLabel = ""

    /// Applies the noise filter to the cached scan results, so toggling the
    /// switch re-filters instantly without another network scan.
    private var hits: [NewLaunchHit] {
        filterNoise ? allHits.filter { !$0.isNoise } : allHits
    }

    var body: some View {
        Form {
            Section("Discovery") {
                Toggle("Filter rocket bodies, debris and constellation batches", isOn: $filterNoise)
                HStack {
                    Button("Scan last 30 days") { scan() }.disabled(isLoading)
                    if !hits.isEmpty {
                        Button("Prepare CSV") { prepareShare(pdf: false) }.buttonStyle(.bordered)
                        Button("Prepare PDF") { prepareShare(pdf: true) }.buttonStyle(.bordered)
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share \(shareLabel)", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                if isLoading { ProgressView("Fetching CelesTrak and SatNOGS…") }
                if let error { Text(error).foregroundStyle(ODTheme.warning) }
                if !hasScanned {
                    Text("The scan is user-initiated. It crosses CelesTrak's last-30-days catalog against the bulk SatNOGS transmitter database and returns objects with documented active transmitters.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
            if hasScanned {
                Section("Objects with documented transmitters") {
                    if !allHits.isEmpty {
                        Text("Showing \(hits.count) of \(allHits.count) objects with transmitters\(filterNoise ? " · noise filtered" : "").")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    if hits.isEmpty && !isLoading {
                        Text("No documented transmitters found among the objects checked. SatNOGS coverage can lag a launch, so this does not prove the new objects are silent.")
                            .foregroundStyle(ODTheme.muted)
                    }
                    ForEach(hits) { hit in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hit.name).font(.headline)
                                Spacer()
                                Text(verbatim: "NORAD \(hit.id)").font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                            }
                            Text("\(hit.transmitterCount) transmitter(s) • \(hit.mode.isEmpty ? "mode unknown" : hit.mode)")
                                .font(.caption)
                            if hit.downlinkHz > 0 {
                                Text("Downlink \(ODFormat.frequency(hit.downlinkHz))")
                                    .font(.caption.monospaced()).foregroundStyle(ODTheme.accent)
                            }
                            let inCatalog = store.satellites.contains { $0.id == hit.id }
                            if inCatalog {
                                Button(store.preferences.favorites.contains(hit.id) ? "Remove favorite" : "Add to favorites") {
                                    store.toggleFavorite(hit.id)
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Button("Add to my satellites") {
                                    store.addExtraSatellite(hit.record, transponders: hit.transponders)
                                }
                                .buttonStyle(.borderedProminent)
                                Text("Adds this CelesTrak element set now and keeps the NORAD ID on the normal refresh path.")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scan() {
        // The launch scan is a bulk CelesTrak group query (last-30-days); honour
        // CelesTrak's one-request-per-2-hours policy to avoid an IP ban.
        guard store.celestrakAllowed("newlaunch") else {
            hasScanned = true
            error = "CelesTrak permits one launch scan every 2 hours (try again in ~\(store.celestrakCooldownMinutes("newlaunch")) min)."
            return
        }
        isLoading = true; error = nil; hasScanned = true; shareURL = nil
        let known = Set(store.satellites.map(\.id))
        Task {
            do {
                allHits = try await NewLaunchService.discover(knownNorads: known)
                store.recordCelestrakFetch("newlaunch")
            }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private func prepareShare(pdf: Bool) {
        do {
            if pdf {
                shareURL = try OrbitExportService.temporaryFile(
                    name: "new_launches.pdf", data: OrbitExportService.newLaunchesPDF(hits))
                shareLabel = "PDF"
            } else {
                shareURL = try OrbitExportService.temporaryTextFile(
                    name: "new_launches.csv", text: OrbitExportService.newLaunchesCSV(hits))
                shareLabel = "CSV"
            }
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - MUF / HF propagation

struct MUFView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var ssn = 100.0
    @State private var rows: [MUFRegionResult] = []
    @State private var sortMode = "region"
    @State private var customTarget = ""
    @State private var customResult: MUFRegionResult?
    @State private var seeded = false
    @State private var dxccQuery = ""

    private var sortedRows: [MUFRegionResult] {
        switch sortMode {
        case "muf": rows.sorted { $0.mufMHz > $1.mufMHz }
        case "distance": rows.sorted { $0.distanceKm < $1.distanceKm }
        default: rows
        }
    }

    var body: some View {
        Form {
            Section("MINIMUF-3.5 inputs") {
                HStack {
                    Text("Sunspot number")
                    Spacer()
                    TextField("SSN", value: $ssn, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.odField)
                        .frame(maxWidth: 120)
                }
                if let weather = store.spaceWeather {
                    Text(weather.sunspotNumber != nil
                         ? "Auto-seeded from the current sunspot number (N0NBH/hamqsl, NOAA SESC fallback); recomputes automatically."
                         : "Auto-seeded from F10.7 using SSN ≈ 1.61 × (F10.7 − 67); recomputes automatically.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                } else {
                    Text("Fetching space weather…").font(.caption).foregroundStyle(ODTheme.muted)
                }
                Picker("Sort", selection: $sortMode) {
                    Text("Region").tag("region")
                    Text("MUF").tag("muf")
                    Text("Distance").tag("distance")
                }.pickerStyle(.segmented)
            }

            Section("Direct path") {
                TextField("Maidenhead grid or latitude,longitude", text: $customTarget)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.odField)
                Button("Compute direct path") { computeCustom() }
                DisclosureGroup("Look up DXCC entity") {
                    TextField("Prefix or name (e.g. JA, Brazil)", text: $dxccQuery)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.odField)
                    ForEach(DXCCData.search(dxccQuery, limit: 12)) { entity in
                        Button {
                            customTarget = String(format: "%.2f,%.2f", entity.latitude, entity.longitude)
                            computeCustom()
                        } label: {
                            HStack {
                                Text(entity.prefix)
                                    .font(.body.monospaced().bold())
                                    .frame(width: 74, alignment: .leading)
                                Text(entity.name)
                                Spacer()
                                Text(String(format: "%.0f, %.0f", entity.latitude, entity.longitude))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ODTheme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let r = customResult { resultView(r) }
            }

            Section("World regions") {
                if rows.isEmpty { Text("Compute to populate the regional MUF table.").foregroundStyle(ODTheme.muted) }
                ForEach(sortedRows) { resultView($0) }
            }

            Section {
                Text("MINIMUF-3.5 is a monthly-median model driven by sunspot number. It is not a live ionosonde and does not model absorption. “Workable” is shown at OrbitDeck's 85% of MUF rule of thumb.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
        .task {
            // Seed from the cached snapshot immediately so the screen is usable,
            // then pull fresh space weather if it's stale and reseed from it.
            seedFromWeather()
            compute()
            seeded = true
            await store.refreshSpaceWeatherIfNeeded()
            seedFromWeather()
            compute()
        }
        .onChange(of: store.spaceWeather?.sunspotNumber) { _, _ in seedFromWeather(); compute() }
        .onChange(of: ssn) { _, _ in if seeded { compute() } }
        .onChange(of: store.preferences.observer.latitude) { _, _ in compute() }
        .onChange(of: store.preferences.observer.longitude) { _, _ in compute() }
    }

    @ViewBuilder private func resultView(_ r: MUFRegionResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.name).font(.headline)
                Spacer()
                Text(String(format: "%.1f MHz", r.mufMHz)).font(.body.monospacedDigit()).foregroundStyle(ODTheme.accent)
            }
            Text(String(format: "Workable %.1f MHz • %@ • %.0f km • %03.0f°",
                        r.workableMHz, r.bestBand, r.distanceKm, r.bearingDegrees))
                .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
        }
    }

    private func seedFromWeather() {
        if let observed = store.spaceWeather?.sunspotNumber { ssn = observed }
        else { ssn = MUFEngine.ssnFromFlux(store.spaceWeather?.flux) }
    }

    private func compute() {
        rows = MUFEngine.toRegions(observer: store.preferences.observer, ssn: max(0, ssn))
    }

    private func computeCustom() {
        guard let ll = FeatureEngine.parseLocation(customTarget) else { customResult = nil; return }
        customResult = MUFEngine.toDestination(observer: store.preferences.observer, destination: ll, ssn: max(0, ssn))
    }
}

// MARK: - Propagation outlook

struct PropagationView: View {
    @EnvironmentObject private var store: OrbitStore
    private var outlook: PropagationOutlookSnapshot { PropagationEngine.outlook(weather: store.spaceWeather) }

    // The engine emits lowercase status words ("quiet", "low — 80/40 normal")
    // so they read naturally inside the summary sentence ("field quiet").
    // Presented on their own in a row or as a headline they need a capital.
    private func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    var body: some View {
        Form {
            Section("Operating outlook") {
                Text(sentenceCased(outlook.summary))
                Button("Update Space Wx") { Task { await store.refreshSpaceWeather() } }
                if let flux = outlook.flux { LabeledContent("Solar flux", value: String(format: "%.0f sfu", flux)) }
                if let kp = outlook.kp { LabeledContent("Kp", value: String(format: "%.1f", kp)) }
                if let day = outlook.dayMUF, let night = outlook.nightMUF {
                    LabeledContent("Headline MUF", value: String(format: "%.0f MHz day / %.0f MHz night", day, night))
                }
            }
            Section("Modes & conditions") {
                LabeledContent("Geomagnetic", value: sentenceCased(outlook.geomagnetic))
                LabeledContent("Aurora (VHF)", value: sentenceCased(outlook.aurora))
                LabeledContent("Absorption", value: sentenceCased(outlook.absorption))
                LabeledContent("Meteor scatter", value: sentenceCased(outlook.meteor))
                LabeledContent("Sporadic E", value: sentenceCased(outlook.sporadicE))
            }
            Section("Band outlook") {
                ForEach(outlook.bands) { row in
                    HStack {
                        Text(row.band).font(.body.monospaced().bold()).frame(width: 54, alignment: .leading)
                        Spacer()
                        Text("Day: \(row.dayState)")
                        Text("Night: \(row.nightState)").foregroundStyle(ODTheme.muted)
                    }.font(.caption)
                }
            }
            Section {
                Text("These are deliberately coarse rules of thumb driven by solar flux, Kp and season. Use MUF / HF Prop for a path calculation; sporadic-E and meteor-scatter lines describe seasonal opportunity rather than a guaranteed opening.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
        .task { await store.refreshSpaceWeatherIfNeeded() }
    }
}

// MARK: - Activations / QRZ

struct DataFeedsView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var tab = 0
    @State private var activations: [ActivationRecord] = []
    @State private var activationChecks: [String: ActivationCheckResult] = [:]
    @State private var activationMessage = "Upcoming satellite activations from hams.at."
    @State private var isLoadingActivations = false
    @State private var activationDetail: ActivationDetailResult?
    @State private var activationDetailLoadingID: String?
    @State private var qrzCall = ""
    @State private var qrzResult: QRZRecord?
    @State private var qrzMessage = ""
    @State private var qrzLoading = false
    private static let qrzService = QRZService()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Feed", selection: $tab) {
                Text("Activations").tag(0)
                Text("QRZ Lookup").tag(1)
            }.pickerStyle(.segmented).padding()
            if tab == 0 { activationsView } else { qrzView }
        }
    }

    private var activationsView: some View {
        Form {
            Section("hams.at upcoming activations") {
                Button("Refresh feed") { fetchActivations() }.disabled(isLoadingActivations)
                if isLoadingActivations { ProgressView() }
                Text(activationMessage).font(.caption).foregroundStyle(ODTheme.muted)
            }
            Section("Scheduled") {
                if activations.isEmpty && !isLoadingActivations { Text("No activation rows loaded.").foregroundStyle(ODTheme.muted) }
                ForEach(activations) { a in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(a.callsign.isEmpty ? a.title : a.callsign).font(.headline)
                            Spacer()
                            Text(a.satellite).foregroundStyle(ODTheme.accent)
                        }
                        Text([a.date, stripUTC(a.start), a.grid, a.mode, a.frequency].filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        HStack {
                            Button("Can I work it?") { check(a) }.buttonStyle(.bordered)
                            Button("Operating detail") { openDetail(a) }.buttonStyle(.bordered)
                                .disabled(activationDetailLoadingID == a.id)
                            Button("Star satellite") { starSatellite(a) }.buttonStyle(.bordered)
                            if activationDetailLoadingID == a.id { ProgressView().controlSize(.small) }
                        }
                        if let check = activationChecks[a.id] {
                            Text(check.message).font(.caption)
                                .foregroundStyle(check.workable ? ODTheme.accent : ODTheme.warning)
                            if let elevation = check.myMaximumElevation {
                                Text(String(format: "My pass max elevation: %.0f°", elevation)).font(.caption.monospacedDigit())
                            }
                            if let window = check.mutualWindow {
                                Text("Mutual: \(ODFormat.utc.string(from: window.start)) – \(ODFormat.utc.string(from: window.end))")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }.padding(.vertical, 3)
                }
            }
        }
        .task { if activations.isEmpty { fetchActivations() } }
        .sheet(item: $activationDetail) { detail in
            ActivationOperatingDetailView(detail: detail, home: store.preferences.observer, store: store)
        }
    }

    private var qrzView: some View {
        Form {
            Section("QRZ XML lookup") {
                TextField("Callsign", text: $qrzCall)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.odField)
                Button("Look up") { lookupQRZ() }.disabled(qrzLoading || qrzCall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if qrzLoading { ProgressView() }
                if !qrzMessage.isEmpty { Text(qrzMessage).font(.caption).foregroundStyle(ODTheme.muted) }
                if (store.preferences.qrzUsername ?? "").isEmpty {
                    Text("Set QRZ XML credentials in Settings. A QRZ XML-subscription account is required.")
                        .font(.caption).foregroundStyle(ODTheme.warning)
                }
            }
            if let r = qrzResult {
                Section(r.call) {
                    if !r.name.isEmpty { LabeledContent("Name", value: r.name) }
                    if !r.address.isEmpty { LabeledContent("Address", value: r.address) }
                    if !r.country.isEmpty { LabeledContent("Country", value: r.country) }
                    if !r.grid.isEmpty { LabeledContent("Grid", value: r.grid) }
                    if !r.licenseClass.isEmpty { LabeledContent("Class", value: r.licenseClass) }
                }
            }
        }
    }

    private func fetchActivations() {
        isLoadingActivations = true; activationMessage = "Fetching hams.at…"
        Task {
            do {
                activations = try await ActivationService.fetch()
                activationMessage = activations.isEmpty ? "No upcoming activations were returned." : "\(activations.count) upcoming activation(s)."
            } catch { activationMessage = error.localizedDescription }
            isLoadingActivations = false
        }
    }

    private func check(_ activation: ActivationRecord) {
        let satellites = store.satellites, home = store.preferences.observer
        Task {
            do {
                let result = try await Task.detached {
                    try ActivationService.check(activation, satellites: satellites, home: home)
                }.value
                activationChecks[activation.id] = result
            } catch {
                activationMessage = error.localizedDescription
            }
        }
    }

    private func openDetail(_ activation: ActivationRecord) {
        activationDetailLoadingID = activation.id
        activationMessage = "Preparing mutual-window operating detail…"
        Task {
            if let local = ActivationService.matchSatellite(activation.satellite, in: store.satellites),
               local.transponders.isEmpty {
                await store.loadTransponders(for: local.id)
            }
            let satellites = store.satellites
            let home = store.preferences.observer
            do {
                let detail = try await Task.detached {
                    try ActivationService.detail(activation, satellites: satellites, home: home)
                }.value
                activationDetail = detail
                activationMessage = detail.windows.isEmpty
                    ? "No mutual window was found within ±60 minutes of the advertised start."
                    : "Prepared \(detail.windows.count) mutual-window operating detail(s)."
            } catch {
                activationMessage = error.localizedDescription
            }
            activationDetailLoadingID = nil
        }
    }

    private func starSatellite(_ activation: ActivationRecord) {
        if let local = ActivationService.matchSatellite(activation.satellite, in: store.satellites) {
            if !store.preferences.favorites.contains(local.id) { store.toggleFavorite(local.id) }
            store.select(local.id)
            activationMessage = "\(local.name) is now a favorite."
            return
        }
        activationMessage = "Searching CelesTrak for \(activation.satellite)…"
        Task {
            do {
                let hits = try await ActivationService.searchCelesTrak(activation.satellite)
                guard let first = hits.first else { activationMessage = "No CelesTrak match for \(activation.satellite)."; return }
                store.addOrUpdateSatellite(first, favorite: true)
                await store.loadTransponders(for: first.id)
                activationMessage = "Added \(first.name) (NORAD \(first.id)) as a favorite."
            } catch { activationMessage = error.localizedDescription }
        }
    }

    private func lookupQRZ() {
        let username = store.preferences.qrzUsername ?? ""
        let password = OrbitSecretStore.get(.qrzPassword)
        let call = qrzCall.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        qrzLoading = true; qrzMessage = "Looking up \(call)…"; qrzResult = nil
        Task {
            do {
                qrzResult = try await Self.qrzService.lookup(username: username, password: password, callsign: call)
                qrzMessage = "QRZ lookup complete."
            } catch { qrzMessage = error.localizedDescription }
            qrzLoading = false
        }
    }

    private func stripUTC(_ text: String) -> String {
        text.replacingOccurrences(of: "(UTC)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "UTC", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


private struct ActivationOperatingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let detail: ActivationDetailResult
    let home: ObserverSite
    let store: OrbitStore

    @State private var windowIndex: Int
    @State private var transponderIndex: Int
    @State private var mode: DXDopplerMode
    @State private var anchor: DXDopplerAnchor
    @State private var offsetHz: Double
    @State private var calDlHz = 0.0
    @State private var calUlHz = 0.0
    @State private var rows: [DXDopplerRow] = []
    @State private var homeTrack: [SkyPoint] = []
    @State private var dxTrack: [SkyPoint] = []
    @State private var note = ""
    @State private var shareURL: URL?
    @State private var shareLabel = ""
    @State private var exportStatus = ""

    init(detail: ActivationDetailResult, home: ObserverSite, store: OrbitStore) {
        self.detail = detail
        self.home = home
        self.store = store
        let cal = store.calibration(for: detail.satellite.id)
        _calDlHz = State(initialValue: cal.downlinkHz)
        _calUlHz = State(initialValue: cal.uplinkHz)
        let match = DXDopplerEngine.matchingTransponder(detail.activation, in: detail.satellite)
        _windowIndex = State(initialValue: 0)
        _transponderIndex = State(initialValue: match?.index ?? 0)
        if let match, match.leg == "downlink" {
            _mode = State(initialValue: .fixedDownlink)
            _anchor = State(initialValue: .dxRX)
        } else if let match {
            _mode = State(initialValue: .fixedUplink)
            _anchor = State(initialValue: .dxTX)
        } else {
            _mode = State(initialValue: .trueRule)
            _anchor = State(initialValue: .myTX)
        }
        let initialOffset = detail.satellite.transponders.indices.contains(match?.index ?? 0)
            ? Double(detail.satellite.transponders[match?.index ?? 0].bandwidth) / 2
            : 0
        _offsetHz = State(initialValue: initialOffset)
    }

    private var windows: [MutualWindowRecord] { detail.windows }
    private var transponders: [TransponderRecord] { detail.satellite.transponders }
    private var selectedWindow: MutualWindowRecord? {
        windows.indices.contains(windowIndex) ? windows[windowIndex] : windows.first
    }
    private var selectedTransponder: TransponderRecord? {
        transponders.indices.contains(transponderIndex) ? transponders[transponderIndex] : transponders.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCard("Activation") {
                        LabeledContent("Callsign", value: detail.activation.callsign.isEmpty ? "—" : detail.activation.callsign)
                        LabeledContent("Satellite", value: detail.satellite.name)
                        LabeledContent("Grid", value: detail.activation.grid.isEmpty ? "—" : detail.activation.grid)
                        LabeledContent("Advertised start", value: ODFormat.utc.string(from: detail.listedDate))
                        if !detail.activation.mode.isEmpty { LabeledContent("Mode", value: detail.activation.mode) }
                        if !detail.activation.frequency.isEmpty { LabeledContent("Frequency", value: detail.activation.frequency) }
                        if !detail.activation.comment.isEmpty {
                            Text(detail.activation.comment).font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    }

                    SectionCard("Mutual visibility") {
                        if windows.isEmpty {
                            Text("No simultaneous home/DX visibility window was found within ±60 minutes of the advertised start.")
                                .foregroundStyle(ODTheme.warning)
                        } else {
                            Picker("Window", selection: $windowIndex) {
                                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                                    Text("\(ODFormat.utcShort.string(from: window.start)) · \(ODFormat.duration(window.duration))").tag(index)
                                }
                            }
                            .pickerStyle(.menu)
                            if let window = selectedWindow {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("Home max").font(.caption).foregroundStyle(ODTheme.muted)
                                        Text(ODFormat.angle(window.myMaxElevation, decimals: 0)).font(.headline.monospacedDigit())
                                    }
                                    Spacer()
                                    VStack(alignment: .leading) {
                                        Text("DX max").font(.caption).foregroundStyle(ODTheme.muted)
                                        Text(ODFormat.angle(window.dxMaxElevation, decimals: 0)).font(.headline.monospacedDigit())
                                    }
                                    Spacer()
                                    VStack(alignment: .leading) {
                                        Text("Duration").font(.caption).foregroundStyle(ODTheme.muted)
                                        Text(ODFormat.duration(window.duration)).font(.headline.monospacedDigit())
                                    }
                                }
                            }
                            ViewThatFits {
                                HStack(spacing: 12) {
                                    ActivationSkyPlot(title: home.name, points: homeTrack)
                                    ActivationSkyPlot(title: detail.dxSite.name, points: dxTrack)
                                }
                                VStack(spacing: 12) {
                                    ActivationSkyPlot(title: home.name, points: homeTrack)
                                    ActivationSkyPlot(title: detail.dxSite.name, points: dxTrack)
                                }
                            }
                        }
                    }

                    SectionCard("DX Doppler") {
                        if transponders.isEmpty {
                            Text("No transponder data is loaded for this satellite. The mutual-window geometry above is still valid.")
                                .foregroundStyle(ODTheme.warning)
                        } else {
                            Picker("Transponder", selection: $transponderIndex) {
                                ForEach(Array(transponders.enumerated()), id: \.offset) { index, tp in
                                    Text(tp.description.isEmpty ? tp.kind : tp.description).tag(index)
                                }
                            }
                            .pickerStyle(.menu)

                            Picker("Rule", selection: $mode) {
                                ForEach(DXDopplerMode.allCases) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented)

                            Picker("Anchor", selection: $anchor) {
                                ForEach(DXDopplerAnchor.allCases) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented)
                                .disabled(mode == .trueRule)

                            if let tp = selectedTransponder, tp.isLinear, tp.bandwidth > 0 {
                                VStack(alignment: .leading) {
                                    Text(verbatim: "Passband offset \(Int(offsetHz.rounded())) Hz")
                                        .font(.caption.monospacedDigit())
                                    Slider(value: $offsetHz, in: 0...Double(tp.bandwidth), step: 100)
                                }
                            }
                            if DXDopplerEngine.matchingTransponder(detail.activation, in: detail.satellite) != nil {
                                Button("Seed from advertised frequency") { seedFromActivation() }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Downlink cal")
                                    Spacer()
                                    TextField("Hz", value: $calDlHz, format: .number)
                                        .keyboardType(.numbersAndPunctuation)
                                        .multilineTextAlignment(.trailing)
                                        .textFieldStyle(.odField)
                                        .frame(width: 100)
                                    Text("Hz").foregroundStyle(ODTheme.muted)
                                }
                                HStack {
                                    Text("Uplink cal")
                                    Spacer()
                                    TextField("Hz", value: $calUlHz, format: .number)
                                        .keyboardType(.numbersAndPunctuation)
                                        .multilineTextAlignment(.trailing)
                                        .textFieldStyle(.odField)
                                        .frame(width: 100)
                                    Text("Hz").foregroundStyle(ODTheme.muted)
                                }
                                Text("Your combined oscillator error (radio + satellite). Measure it from the downlink and/or uplink; both fold into one overall correction applied to your receive dial only — your transmit dial stays on the computed frequency, and the DX station is never calibrated. Saved per satellite.")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            }

                            Text(note).font(.caption).foregroundStyle(ODTheme.muted)

                            ScrollView(.horizontal) {
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                                    GridRow {
                                        Text("UTC"); Text("My RX"); Text("My TX"); Text("DX RX"); Text("DX TX")
                                    }.font(.caption.bold()).foregroundStyle(ODTheme.muted)
                                    ForEach(rows) { row in
                                        GridRow {
                                            Text(Self.clock.string(from: row.date))
                                            Text(freq(row.myRX))
                                            Text(freq(row.myTX))
                                            Text(freq(row.dxRX))
                                            Text(freq(row.dxTX))
                                        }.font(.caption.monospacedDigit())
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            Text("True rule keeps both stations on the same satellite passband point and lets all four dials track their own Doppler. Fixed-downlink/uplink holds the selected anchor dial at its reference-time frequency and solves the satellite-frame passband point around it.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    }

                    if selectedWindow != nil, selectedTransponder != nil, !rows.isEmpty {
                        SectionCard("Share operating plan") {
                            Text("Export the selected activation window and the exact four-dial table currently shown above. CSV is machine-readable; PDF is a landscape operating sheet.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                            ViewThatFits {
                                HStack {
                                    Button("Prepare CSV") { prepareOperatingExport(pdf: false) }
                                    Button("Prepare PDF") { prepareOperatingExport(pdf: true) }
                                }
                                VStack(alignment: .leading) {
                                    Button("Prepare DX Doppler CSV") { prepareOperatingExport(pdf: false) }
                                    Button("Prepare operating-detail PDF") { prepareOperatingExport(pdf: true) }
                                }
                            }
                            if let shareURL {
                                ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") }
                            }
                            if !exportStatus.isEmpty { Text(exportStatus).font(.caption).foregroundStyle(ODTheme.muted) }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Activation Operating Detail")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { seedFromActivation(); reload() }
            .onChange(of: windowIndex) { reload() }
            .onChange(of: transponderIndex) {
                if let tp = selectedTransponder { offsetHz = tp.isLinear ? Double(tp.bandwidth) / 2 : 0 }
                note = ""
                reload()
            }
            .onChange(of: mode) { reload() }
            .onChange(of: anchor) { reload() }
            .onChange(of: offsetHz) { reload() }
            .onChange(of: calDlHz) { store.setCalibration(RadioCalibration(downlinkHz: calDlHz, uplinkHz: calUlHz), for: detail.satellite.id); reload() }
            .onChange(of: calUlHz) { store.setCalibration(RadioCalibration(downlinkHz: calDlHz, uplinkHz: calUlHz), for: detail.satellite.id); reload() }
        }
    }

    private func prepareOperatingExport(pdf: Bool) {
        guard let window = selectedWindow, let tp = selectedTransponder, !rows.isEmpty else {
            exportStatus = "No DX Doppler table is available to export."
            return
        }
        do {
            let baseCall = detail.activation.callsign.isEmpty ? "activation" : detail.activation.callsign
            let base = "\(baseCall)_\(detail.satellite.name)"
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            if pdf {
                let data = OrbitExportService.activationOperatingPDF(
                    detail: detail, home: home, window: window, transponder: tp, rows: rows,
                    mode: mode, anchor: anchor, offsetHz: Int64(offsetHz.rounded())
                )
                shareURL = try OrbitExportService.temporaryFile(name: "activation_\(base).pdf", data: data)
                shareLabel = "operating-detail PDF"
            } else {
                let text = OrbitExportService.activationOperatingCSV(
                    detail: detail, home: home, window: window, transponder: tp, rows: rows,
                    mode: mode, anchor: anchor, offsetHz: Int64(offsetHz.rounded())
                )
                shareURL = try OrbitExportService.temporaryTextFile(name: "activation_\(base).csv", text: text)
                shareLabel = "DX Doppler CSV"
            }
            exportStatus = "Prepared the currently selected window, rule, anchor and transponder."
        } catch { exportStatus = error.localizedDescription }
    }

    private func seedFromActivation() {
        guard let window = selectedWindow,
              let match = DXDopplerEngine.matchingTransponder(detail.activation, in: detail.satellite),
              transponders.indices.contains(match.index) else {
            note = rows.isEmpty ? "" : note
            return
        }
        transponderIndex = match.index
        let tp = transponders[match.index]
        if match.leg == "downlink" {
            mode = .fixedDownlink
            anchor = .dxRX
        } else {
            mode = .fixedUplink
            anchor = .dxTX
        }
        offsetHz = Double(DXDopplerEngine.solvePassbandOffset(
            targetHz: match.hz, satellite: detail.satellite, home: home, dx: detail.dxSite,
            transponder: tp, reference: window.start, mode: mode, anchor: anchor
        ))
        note = "Seeded from the activation’s \(match.leg) frequency \(String(format: "%.6f", Double(match.hz) / 1_000_000)) MHz."
        reload()
    }

    private func reload() {
        shareURL = nil
        exportStatus = ""
        guard let window = selectedWindow else {
            rows = []; homeTrack = []; dxTrack = []; return
        }
        homeTrack = (try? DXDopplerEngine.skyTrack(satellite: detail.satellite, observer: home, window: window)) ?? []
        dxTrack = (try? DXDopplerEngine.skyTrack(satellite: detail.satellite, observer: detail.dxSite, window: window)) ?? []
        guard let tp = selectedTransponder else { rows = []; return }
        rows = (try? DXDopplerEngine.table(
            satellite: detail.satellite, home: home, dx: detail.dxSite, transponder: tp,
            window: window, offsetHz: Int64(offsetHz.rounded()), mode: mode, anchor: anchor,
            calDlHz: Int64(calDlHz.rounded()), calUlHz: Int64(calUlHz.rounded())
        )) ?? []
        if note.isEmpty {
            note = "\(rows.count) rows at 30-second steps across the selected mutual window."
        }
    }

    private func freq(_ hz: Int64) -> String {
        hz == 0 ? "—" : String(format: "%.6f", Double(hz) / 1_000_000)
    }

    private static let clock: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "HH:mm:ss"
        return df
    }()
}

/// A titled sky-track plot built on the shared `PolarSkyPlot` (compass rose,
/// elevation-ring labels, rise/set + peak markers). Used for the paired
/// home/DX plots on Activation detail and Mutual Windows.
private struct ActivationSkyPlot: View {
    let title: String
    let points: [SkyPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            PolarSkyPlot(points: points, currentPoint: nil, minimumElevation: 0)
                .frame(minWidth: 260, minHeight: 260)
                .odPanel()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Saved sites

private struct SiteComparisonRow: Identifiable, Sendable {
    let id: String
    let name: String
    let passCount: Int
    let nextAOS: Date?
    let nextMaximumElevation: Double?
    let bestMaximumElevation: Double?
}

struct SitesView: View {
    @EnvironmentObject private var store: OrbitStore
    @StateObject private var locationProvider = LocationProvider()
    @State private var pollingForNewSite = false
    @State private var newName = ""
    @State private var newLocation = ""
    @State private var newAltitude = 0.0
    @State private var days = 2
    @State private var comparisons: [SiteComparisonRow] = []
    @State private var isComparing = false
    @State private var message = ""
    @State private var shareURL: URL?

    var body: some View {
        Form {
            Section("Primary site") {
                siteSummary(store.preferences.observer)
                if store.locationMode == .currentLocation {
                    Text("Following device location — the primary site is “\(OrbitStore.currentLocationName)” and can't be renamed. Switch to a fixed site in Settings to edit it.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                } else {
                    TextField("Primary site name", text: Binding(
                        get: { store.preferences.observer.name },
                        set: { store.preferences.observer.name = $0 }
                    ))
                    .textFieldStyle(.odField)
                    Text("The primary site drives Track, passes, MUF, mutual visibility and every other observer-relative screen.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
            Section("Add secondary site") {
                TextField("Nickname", text: $newName).textFieldStyle(.odField)
                TextField("Maidenhead grid or latitude,longitude", text: $newLocation)
                    .textInputAutocapitalization(.characters)
                    .textFieldStyle(.odField)
                HStack { Text("Altitude"); Spacer(); TextField("m", value: $newAltitude, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).textFieldStyle(.odField) }
                Button { pollCurrentLocation() } label: { Label("Use current location", systemImage: "location") }
                Button("Add Site") { addSite() }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(ODTheme.muted) }
                if let error = locationProvider.errorMessage { Text(error).font(.caption).foregroundStyle(ODTheme.warning) }
            }
            Section("Secondary sites") {
                let sites = store.preferences.savedSites ?? []
                if sites.isEmpty { Text("No secondary sites saved.").foregroundStyle(ODTheme.muted) }
                ForEach(Array(sites.enumerated()), id: \.offset) { index, site in
                    VStack(alignment: .leading, spacing: 5) {
                        siteSummary(site)
                        HStack {
                            Button("Make primary") { store.makePrimarySite(site); compare() }.buttonStyle(.bordered)
                            Button("Remove", role: .destructive) { store.removeSavedSite(at: IndexSet(integer: index)); compare() }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section("Compare selected satellite") {
                Picker("Window", selection: $days) { Text("1 day").tag(1); Text("2 days").tag(2); Text("3 days").tag(3) }.pickerStyle(.segmented)
                Button("Compare passes") { compare() }.disabled(isComparing || store.selectedSatellite == nil)
                if isComparing { ProgressView("Predicting across sites…") }
                ForEach(comparisons) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(row.name).font(.headline); Spacer(); Text("\(row.passCount) passes").font(.caption.monospaced()) }
                        if let aos = row.nextAOS {
                            Text("Next \(ODFormat.utc.string(from: aos)) • max \(row.nextMaximumElevation.map { String(format: "%.0f°", $0) } ?? "—") • best \(row.bestMaximumElevation.map { String(format: "%.0f°", $0) } ?? "—")")
                                .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                        } else { Text("No qualifying passes in window.").font(.caption).foregroundStyle(ODTheme.muted) }
                    }
                }
                if !comparisons.isEmpty {
                    Button("Prepare comparison CSV") { prepareCSV() }
                    if let shareURL {
                        ShareLink(item: shareURL) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        .task(id: store.selectedSatellite?.id) { compare() }
        .onChange(of: locationProvider.location) { _, location in
            guard pollingForNewSite, let location else { return }
            pollingForNewSite = false
            newLocation = String(format: "%.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude)
            if location.altitude.isFinite { newAltitude = location.altitude }
            message = "Filled from current location (\(FeatureEngine.latLonToGrid6(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)))."
        }
    }

    private func pollCurrentLocation() {
        pollingForNewSite = true
        message = "Getting current location…"
        locationProvider.requestLocation()
    }

    private func prepareCSV() {
        guard let satellite = store.selectedSatellite else { return }
        var rows = "site,passes,next_aos_utc,next_max_el_deg,best_max_el_deg\n"
        for row in comparisons {
            rows += "\(row.name),\(row.passCount),\(row.nextAOS.map { ODFormat.utc.string(from: $0) } ?? ""),\(row.nextMaximumElevation.map { String(format: "%.1f", $0) } ?? ""),\(row.bestMaximumElevation.map { String(format: "%.1f", $0) } ?? "")\n"
        }
        do {
            shareURL = try OrbitExportService.temporaryTextFile(name: "site_comparison_\(satellite.id).csv", text: rows)
        } catch { message = error.localizedDescription }
    }

    @ViewBuilder private func siteSummary(_ site: ObserverSite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(site.name).font(.headline)
            Text(String(format: "%.4f, %.4f • %@ • %.0f m", site.latitude, site.longitude,
                        FeatureEngine.latLonToGrid6(latitude: site.latitude, longitude: site.longitude), site.altitudeMeters))
                .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
        }
    }

    private func addSite() {
        guard let ll = FeatureEngine.parseLocation(newLocation) else { message = "Enter a valid Maidenhead grid or latitude,longitude."; return }
        store.addSavedSite(ObserverSite(name: newName, latitude: ll.latitude, longitude: ll.longitude, altitudeMeters: newAltitude))
        newName = ""; newLocation = ""; newAltitude = 0; message = "Site saved."; compare()
    }

    private func compare() {
        guard let satellite = store.selectedSatellite else { comparisons = []; return }
        let sites = [store.preferences.observer] + (store.preferences.savedSites ?? [])
        let minimum = store.preferences.minElevation, days = Double(days)
        isComparing = true; shareURL = nil
        Task {
            do {
                comparisons = try await Task.detached {
                    try sites.map { site in
                        let passes = try OrbitPredictor.predictPasses(satellite, observer: site, minElevation: minimum,
                                                                     maxCount: 200, horizonDays: days)
                        let best = passes.max(by: { $0.maxElevation < $1.maxElevation })
                        return SiteComparisonRow(id: site.name, name: site.name, passCount: passes.count,
                                                 nextAOS: passes.first?.aos,
                                                 nextMaximumElevation: passes.first?.maxElevation,
                                                 bestMaximumElevation: best?.maxElevation)
                    }
                }.value
            } catch is CancellationError {
                // Navigated away mid-compare — nothing to report.
            } catch let error as URLError where error.code == .cancelled {
            } catch { message = error.localizedDescription }
            isComparing = false
        }
    }
}

// MARK: - AMSAT status with attributed posting

struct AmsatStatusInteractiveView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var tab = 0
    @State private var hours = 24
    @State private var board: [AmsatStatusSummaryRecord] = []
    @State private var isLoading = false
    @State private var message = ""
    @State private var apiMatches: [String] = []
    @State private var apiName = ""
    @State private var reportStatus = "Heard"
    @State private var recentReports: [AmsatReportRecord] = []
    @State private var confirmPost = false
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("AMSAT", selection: $tab) { Text("Status Board").tag(0); Text("Report Status").tag(1) }
                .pickerStyle(.segmented).padding()
            if tab == 0 { boardView } else { reportView }
        }
        .task { refreshBoard(); await resolveSelectedSatellite() }
        .onChange(of: hours) { _, _ in if tab == 0 { refreshBoard() } }
        .onChange(of: store.selectedSatellite?.id) { _, _ in Task { await resolveSelectedSatellite() } }
        .confirmationDialog("Post public AMSAT status report?", isPresented: $confirmPost, titleVisibility: .visible) {
            Button("Post “\(reportStatus)”") { submitReport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will publicly post \(reportStatus) for \(apiName) as \((store.preferences.callsign ?? "").uppercased()) / \(store.operatorGrid) on amsat.org. The report is attributed and visible to other operators.")
        }
    }

    private var boardView: some View {
        Form {
            Section("Community status board") {
                Picker("Window", selection: $hours) { Text("6 h").tag(6); Text("24 h").tag(24); Text("48 h").tag(48) }.pickerStyle(.segmented)
                Button("Refresh") { refreshBoard() }.disabled(isLoading)
                if isLoading { ProgressView() }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(ODTheme.muted) }
            }
            Section("Reported satellites") {
                ForEach(board) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(row.displayName).font(.headline); Spacer(); Text("\(row.heard)/\(row.reports) heard").font(.caption.monospaced()).foregroundStyle(ODTheme.accent) }
                        if !row.lastReport.isEmpty { Text("Last: \(row.lastReport)").font(.caption).foregroundStyle(ODTheme.muted) }
                    }
                }
            }
        }
    }

    private var reportView: some View {
        Form {
            Section("Public attributed report") {
                if let sat = store.selectedSatellite { LabeledContent("Selected satellite", value: sat.name) }
                if apiMatches.count > 1 {
                    Picker("AMSAT mode name", selection: $apiName) { ForEach(apiMatches, id: \.self) { Text($0).tag($0) } }
                } else {
                    TextField("AMSAT API name", text: $apiName).textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
                }
                Button("Resolve AMSAT catalog name") { Task { await resolveSelectedSatellite() } }
                Picker("Status", selection: $reportStatus) { ForEach(AmsatStatusService.reportStatuses, id: \.self) { Text($0).tag($0) } }
                LabeledContent("Callsign", value: (store.preferences.callsign ?? "").isEmpty ? "Not set" : (store.preferences.callsign ?? ""))
                LabeledContent("Grid", value: store.operatorGrid)
                Button("Load recent reports") { loadRecent() }.disabled(apiName.isEmpty)
                Button("Send public report…") { confirmPost = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiName.isEmpty || (store.preferences.callsign ?? "").isEmpty || isSending)
                if isSending { ProgressView("Posting…") }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(ODTheme.muted) }
            }
            Section("Recent reports for this mode") {
                if recentReports.isEmpty { Text("No recent reports loaded.").foregroundStyle(ODTheme.muted) }
                ForEach(recentReports.prefix(30)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(r.callsign.isEmpty ? "(unknown call)" : r.callsign).font(.headline); Spacer(); Text(r.status).foregroundStyle(ODTheme.accent) }
                        Text([r.grid, r.date.map { ODFormat.utc.string(from: $0) } ?? r.rawTime].filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                    }
                }
            }
            Section {
                Text("OrbitDeck never posts automatically. The Send button always opens an explicit confirmation describing the public callsign/grid attribution before any network submission occurs.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func refreshBoard() {
        isLoading = true; message = ""
        let h = hours
        Task {
            do { board = try await AmsatStatusService.fetchSummary(hours: h) }
            catch { message = error.localizedDescription }
            isLoading = false
        }
    }

    private func resolveSelectedSatellite() async {
        guard let sat = store.selectedSatellite else { apiMatches = []; apiName = ""; return }
        // Retry quietly a few times (cold networks fail the first calls). Never
        // show a scary "match failed" banner on auto-load — the manual AMSAT-name
        // field below stays usable, and the catalog is session-cached once it
        // succeeds so later screens resolve instantly.
        for attempt in 0..<5 {
            if Task.isCancelled { return }
            do {
                let matches = try await AmsatStatusService.catalogMatches(commonName: sat.name)
                apiMatches = matches
                if let first = matches.first { apiName = first }
                else if apiName.isEmpty { apiName = sat.name }
                if message.hasPrefix("AMSAT catalog match failed") { message = "" }
                return
            } catch {
                if attempt < 4 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
        if apiName.isEmpty { apiName = sat.name }   // fall back to manual entry, silently
    }

    private func loadRecent() {
        let name = apiName, h = hours
        Task {
            do { recentReports = try await AmsatStatusService.fetchReports(apiName: name, hours: h) }
            catch { message = error.localizedDescription }
        }
    }

    private func submitReport() {
        let name = apiName, status = reportStatus, call = store.preferences.callsign ?? "", grid = store.operatorGrid
        isSending = true; message = ""
        Task {
            do {
                message = try await AmsatStatusService.submitReport(apiName: name, status: status, callsign: call, grid: grid)
                recentReports = try await AmsatStatusService.fetchReports(apiName: name, hours: hours)
                refreshBoard()
            } catch { message = error.localizedDescription }
            isSending = false
        }
    }
}
