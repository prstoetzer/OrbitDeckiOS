import SwiftUI

enum IlluminationMode: String, CaseIterable, Identifiable {
    case now = "Now"
    case raster = "Illumination raster"
    case eclipses = "Eclipse table"
    var id: String { rawValue }
}

struct IlluminationView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var mode: IlluminationMode = .now
    @State private var dayOffset = 0
    @State private var raster: IlluminationRasterSnapshot?
    @State private var eclipseDays = 7
    @State private var periods: [SatelliteEclipsePeriod] = []
    @State private var daily: [SatelliteEclipseDailySummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var shareLabel = ""

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            Picker("Illumination view", selection: $mode) {
                ForEach(IlluminationMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            if let satellite = store.selectedSatellite {
                Group {
                    switch mode {
                    case .now: nowView(satellite)
                    case .raster: rasterView(satellite)
                    case .eclipses: eclipseView(satellite)
                    }
                }
            } else {
                LoadingOrError(isLoading: store.isRefreshingGP, error: store.lastError,
                               emptyText: "No satellite selected")
            }
        }
        .onChange(of: mode) { _, _ in shareURL = nil; error = nil }
    }

    @ViewBuilder
    private func nowView(_ satellite: SatelliteRecord) -> some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            if let look = try? OrbitPredictor.look(satellite,
                                                   observer: store.preferences.observer,
                                                   at: context.date) {
                ScrollView {
                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            Image(systemName: look.sunlit ? "sun.max.fill" : "moon.fill")
                                .font(.system(size: 68))
                                .foregroundStyle(look.sunlit ? ODTheme.warning : ODTheme.muted)
                            Text(look.sunlit ? "SUNLIT" : "IN EARTH SHADOW")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(look.sunlit ? ODTheme.warning : ODTheme.muted)
                            Text(ODFormat.utc.string(from: context.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ODTheme.muted)
                        }
                        .padding(.top, 24)

                        SectionCard("Illumination geometry") {
                            MetricRow("Beta angle", String(format: "%+.3f°", look.betaAngleDeg))
                            MetricRow("Satellite altitude", String(format: "%.1f km", look.altitudeKm))
                            MetricRow("Station elevation", ODFormat.angle(look.elevation))
                            MetricRow("Visible from station", look.visible ? "Yes" : "No",
                                      valueColor: look.visible ? ODTheme.good : ODTheme.muted)
                            MetricRow("Optical condition",
                                      look.visible && look.sunlit
                                      ? "Satellite is above the horizon and illuminated"
                                      : "Not simultaneously above-horizon and sunlit")
                        }

                        Text("The shadow state uses a cylindrical Earth-shadow test. The raster and eclipse table use this same propagator rather than a separate illumination model.")
                            .font(.caption).foregroundStyle(ODTheme.muted).padding(.horizontal)
                    }
                    .padding(.vertical, 14)
                }
            } else {
                ContentUnavailableView("Illumination unavailable",
                                       systemImage: "sun.max.trianglebadge.exclamationmark")
            }
        }
    }

    @ViewBuilder
    private func rasterView(_ satellite: SatelliteRecord) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { dayOffset = max(0, dayOffset - 7) } label: { Image(systemName: "chevron.left") }
                    .disabled(dayOffset == 0 || isLoading)
                Button("Today") { dayOffset = 0 }.disabled(dayOffset == 0 || isLoading)
                Button { dayOffset += 7 } label: { Image(systemName: "chevron.right") }.disabled(isLoading)
                Spacer()
                if let raster {
                    Text("Mean eclipse \(String(format: "%.0f", (1 - raster.meanSunlitFraction) * 100))% / orbit")
                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            HStack {
                Button { prepareIlluminationReport(satellite) } label: {
                    Label("Prepare 60-day PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal)

            if let shareURL {
                ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }

            if isLoading && raster == nil {
                Spacer(); ProgressView("Computing illumination raster…"); Spacer()
            } else if let error {
                Spacer(); Text(error).foregroundStyle(.red).padding(); Spacer()
            } else if let raster {
                VStack(alignment: .leading, spacing: 6) {
                    IlluminationRasterGraphic(raster: raster)
                        .frame(minHeight: 300)
                        .padding(.horizontal)
                    HStack {
                        Text(ODFormat.utcDay.string(from: Date().addingTimeInterval(Double(dayOffset) * 86400)))
                        Spacer()
                        Text("30 days →")
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                    .padding(.horizontal)
                    Text("Bright = sunlit, dark = eclipse. X is UTC day; Y is minutes into one orbital period. The view samples 96 points per orbit.")
                        .font(.caption).foregroundStyle(ODTheme.muted).padding(.horizontal)
                }
            }
        }
        .padding(.vertical, 10)
        .task(id: satellite.id) { await loadRaster(satellite) }
        // `.task(id:)` does not reliably re-fire when `dayOffset` (local button
        // state) changes, so reload the raster explicitly when stepping days.
        .onChange(of: dayOffset) { _, _ in Task { await loadRaster(satellite) } }
    }

    @ViewBuilder
    private func eclipseView(_ satellite: SatelliteRecord) -> some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Span", selection: $eclipseDays) {
                    Text("1 d").tag(1); Text("3 d").tag(3); Text("7 d").tag(7); Text("14 d").tag(14)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
                Button("Prepare CSV") { prepareEclipseShare(satellite, pdf: false) }.buttonStyle(.bordered)
                Button("Prepare PDF") { prepareEclipseShare(satellite, pdf: true) }.buttonStyle(.bordered)
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)

            if isLoading && periods.isEmpty {
                Spacer(); ProgressView("Finding shadow transitions…"); Spacer()
            } else if let error {
                Spacer(); Text(error).foregroundStyle(.red).padding(); Spacer()
            } else {
                List {
                    Section("Every orbit") {
                        if periods.isEmpty {
                            Text("No eclipses in the next \(eclipseDays) day\(eclipseDays == 1 ? "" : "s") — continuous sunlight over this window.")
                                .foregroundStyle(ODTheme.muted)
                        }
                        ForEach(periods.indices, id: \.self) { index in
                            let p = periods[index]
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(ODFormat.utcShort.string(from: p.enter)).font(.body.monospacedDigit())
                                    Text("→").foregroundStyle(ODTheme.muted)
                                    Text(ODFormat.utcShort.string(from: p.exit)).font(.body.monospacedDigit())
                                    Spacer()
                                    Text(ODFormat.duration(p.durationSeconds)).font(.body.monospacedDigit())
                                }
                                HStack {
                                    if index > 0 {
                                        Text("Interval \(ODFormat.duration(p.enter.timeIntervalSince(periods[index - 1].exit)))")
                                    }
                                    Spacer()
                                    Text(String(format: "β %+.1f°", p.betaAngleDegrees))
                                }
                                .font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                    Section("Daily summary") {
                        ForEach(daily) { row in
                            HStack {
                                Text(ODFormat.utcDay.string(from: row.date)).font(.body.monospacedDigit())
                                Spacer()
                                Text("\(row.count) eclipse\(row.count == 1 ? "" : "s")")
                                Text("· \(ODFormat.duration(row.totalSeconds))")
                                Text(String(format: "· %.1f%% day", row.percentOfDay))
                                Text(String(format: "· β %+.1f°", row.betaAngleDegrees))
                                    .foregroundStyle(ODTheme.muted)
                            }
                            .font(.caption)
                        }
                    }
                }
                Text("Umbral Earth-shadow ephemeris. Beta angle is the Sun/orbit-plane angle; high |β| produces shorter eclipses and eventually continuous sunlight. Planning output, not spacecraft power telemetry.")
                    .font(.caption).foregroundStyle(ODTheme.muted).padding(.horizontal)
            }
        }
        .padding(.top, 8)
        .task(id: satellite.id) { await loadEclipses(satellite) }
        // `.task(id:)` does not reliably re-fire when `eclipseDays` (local Picker
        // state) changes, so reload eclipses explicitly on span change.
        .onChange(of: eclipseDays) { _, _ in Task { await loadEclipses(satellite) } }
    }

    @MainActor
    private func loadRaster(_ satellite: SatelliteRecord) async {
        isLoading = true; error = nil; shareURL = nil
        let offset = dayOffset
        do {
            raster = try await Task.detached(priority: .userInitiated) {
                try OrbitExportService.illuminationRaster(
                    satellite: satellite, days: 30, rowsPerOrbit: 96,
                    start: Date().addingTimeInterval(Double(offset) * 86400)
                )
            }.value
        } catch { self.error = error.localizedDescription; raster = nil }
        isLoading = false
    }

    @MainActor
    private func loadEclipses(_ satellite: SatelliteRecord) async {
        isLoading = true; error = nil; shareURL = nil
        let days = eclipseDays
        let start = Date()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let p = try FeatureCompletionEngine.satelliteEclipses(satellite: satellite, from: start, days: days)
                let d = FeatureCompletionEngine.satelliteEclipseDailySummary(satellite: satellite, periods: p, from: start, days: days)
                return (p, d)
            }.value
            periods = result.0; daily = result.1
        } catch { self.error = error.localizedDescription; periods = []; daily = [] }
        isLoading = false
    }

    private func prepareIlluminationReport(_ satellite: SatelliteRecord) {
        Task {
            isLoading = true; error = nil
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try OrbitExportService.illuminationReportPDF(satellite: satellite, days: 60)
                }.value
                shareURL = try OrbitExportService.temporaryFile(name: "illumination_\(satellite.id).pdf", data: data)
                shareLabel = "60-day PDF"
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private func prepareEclipseShare(_ satellite: SatelliteRecord, pdf: Bool) {
        do {
            if pdf {
                let data = OrbitExportService.satelliteEclipsePDF(periods: periods, daily: daily,
                                                                 satellite: satellite, days: eclipseDays)
                shareURL = try OrbitExportService.temporaryFile(name: "eclipses_\(satellite.id).pdf", data: data)
                shareLabel = "eclipse PDF"
            } else {
                let text = OrbitExportService.satelliteEclipseCSV(periods: periods, daily: daily, satellite: satellite)
                shareURL = try OrbitExportService.temporaryTextFile(name: "eclipses_\(satellite.id).csv", text: text)
                shareLabel = "eclipse CSV"
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct IlluminationRasterGraphic: View {
    let raster: IlluminationRasterSnapshot

    var body: some View {
        Canvas { context, size in
            let cw = size.width / CGFloat(max(1, raster.days))
            let ch = size.height / CGFloat(max(1, raster.rowsPerOrbit))
            for day in 0..<raster.days {
                for row in 0..<raster.rowsPerOrbit {
                    let y = size.height - CGFloat(row + 1) * ch
                    let rect = CGRect(x: CGFloat(day) * cw, y: y,
                                      width: max(1, cw + 0.25), height: max(1, ch + 0.25))
                    context.fill(Path(rect), with: .color(raster.isSunlit(day: day, row: row)
                                                         ? Color.yellow.opacity(0.82)
                                                         : Color.indigo.opacity(0.58)))
                }
            }
            for day in stride(from: 0, through: raster.days, by: 5) {
                let x = CGFloat(day) * cw
                var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            }
        }
        .background(.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
        .accessibilityLabel("Thirty-day satellite illumination raster")
    }
}
