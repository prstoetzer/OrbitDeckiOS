import Charts
import SwiftUI

struct PassDetailView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var pass: PredictedPass?
    @State private var path: [SkyPoint] = []
    /// Per-sample illumination for `path` (`LiveLook.sunlit`), same order.
    @State private var sunlit: [Bool] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            ScrollView {
                if isLoading {
                    ProgressView("Computing pass detail…")
                        .padding(40)
                } else if let pass {
                    VStack(spacing: 14) {
                        PolarSkyPlot(
                            points: path,
                            minimumElevation: store.preferences.minElevation
                        )
                        .frame(maxHeight: 500)
                        .padding()

                        if path.count > 1 {
                            SectionCard("Elevation profile") {
                                // The curve is split into runs by illumination (one
                                // series per run, sharing the boundary sample) so it
                                // reads sunlit vs eclipse at a glance.
                                let runs = illuminationRuns
                                Chart {
                                    ForEach(path) { point in
                                        AreaMark(
                                            x: .value("Time", point.date),
                                            y: .value("Elevation", max(0, point.elevation))
                                        )
                                        .foregroundStyle(ODTheme.accent.opacity(0.15))
                                    }
                                    ForEach(runs) { point in
                                        LineMark(
                                            x: .value("Time", point.date),
                                            y: .value("Elevation", max(0, point.elevation)),
                                            series: .value("Run", point.run)
                                        )
                                        .interpolationMethod(.catmullRom)
                                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                                        .foregroundStyle(by: .value("Illumination", point.sunlit ? "Sunlit" : "Eclipse"))
                                    }
                                }
                                .chartForegroundStyleScale(["Sunlit": ODTheme.warning, "Eclipse": Color.indigo])
                                .chartYScale(domain: 0...90)
                                .chartYAxisLabel("Elevation (°)")
                                .frame(height: 200)
                            }
                        }

                        SectionCard("Next pass") {
                            MetricRow("AOS", ODFormat.utc.string(from: pass.aos), valueColor: ODTheme.good)
                            MetricRow("TCA", ODFormat.utc.string(from: pass.tca))
                            MetricRow("LOS", ODFormat.utc.string(from: pass.los), valueColor: ODTheme.warning)
                            MetricRow("Duration", ODFormat.duration(pass.duration))
                            MetricRow("Maximum elevation", ODFormat.angle(pass.maxElevation))
                            MetricRow("AOS azimuth", "\(ODFormat.angle(pass.aosAzimuth)) \(ODFormat.compass(pass.aosAzimuth))")
                            MetricRow("LOS azimuth", "\(ODFormat.angle(pass.losAzimuth)) \(ODFormat.compass(pass.losAzimuth))")
                        }

                        if let satellite = store.selectedSatellite,
                           let tcaLook = try? OrbitPredictor.look(
                                satellite,
                                observer: store.preferences.observer,
                                at: pass.tca
                           ) {
                            SectionCard("At TCA") {
                                MetricRow("Range", ODFormat.distance(tcaLook.rangeKm))
                                MetricRow("Range rate", ODFormat.velocity(tcaLook.rangeRateKmS))
                                MetricRow("Subpoint", String(format: "%.3f°, %.3f°", tcaLook.subLatitude, tcaLook.subLongitude))
                                MetricRow("Altitude", ODFormat.units(String(format: "%.1f km", tcaLook.altitudeKm)))
                                MetricRow("Illumination", tcaLook.sunlit ? "Sunlit" : "Eclipsed", valueColor: tcaLook.sunlit ? ODTheme.warning : ODTheme.muted)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                } else {
                    ContentUnavailableView(
                        errorMessage == nil ? "No qualifying pass" : "Pass detail unavailable",
                        systemImage: "chart.xyaxis.line",
                        description: Text(errorMessage ?? "No pass above the configured minimum elevation was found.")
                    )
                    .padding(.top, 40)
                }
            }
        }
        .task(id: taskKey) {
            await load(initial: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await load(initial: false)
            }
        }
    }

    /// `path` cut into same-illumination runs for the elevation chart. Each change
    /// of state repeats the boundary sample in both runs so the line is continuous.
    private var illuminationRuns: [IlluminationSample] {
        guard sunlit.count == path.count else {
            return path.enumerated().map { IlluminationSample(id: $0.offset, date: $0.element.date, elevation: $0.element.elevation, run: 0, sunlit: true) }
        }
        var out: [IlluminationSample] = []
        var run = 0
        for (i, point) in path.enumerated() {
            if i > 0, sunlit[i] != sunlit[i - 1] {
                out.append(IlluminationSample(id: out.count, date: point.date, elevation: point.elevation, run: run, sunlit: sunlit[i - 1]))
                run += 1
            }
            out.append(IlluminationSample(id: out.count, date: point.date, elevation: point.elevation, run: run, sunlit: sunlit[i]))
        }
        return out
    }

    private var taskKey: String {
        let o = store.preferences.observer
        return "\(store.selectedSatellite?.id ?? 0)-\(o.latitude)-\(o.longitude)-\(store.preferences.minElevation)"
    }

    @MainActor
    private func load(initial: Bool) async {
        guard let satellite = store.selectedSatellite else {
            pass = nil
            path = []
            sunlit = []
            return
        }
        let observer = store.preferences.observer
        let minimum = store.preferences.minElevation
        if initial {
            pass = nil
            path = []
            sunlit = []
            errorMessage = nil
            isLoading = true
        }
        defer { isLoading = false }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let matches = try OrbitPredictor.predictPasses(
                    satellite,
                    observer: observer,
                    minElevation: minimum,
                    maxCount: 1
                )
                guard let next = matches.first else {
                    return (Optional<PredictedPass>.none, [SkyPoint](), [Bool]())
                }
                let sky = try OrbitPredictor.skyPath(satellite, observer: observer, pass: next)
                let lit = sky.map { (try? OrbitPredictor.look(satellite, observer: observer, at: $0.date))?.sunlit ?? true }
                return (Optional(next), sky, lit)
            }.value
            if Task.isCancelled { return }
            pass = result.0
            path = result.1
            sunlit = result.2
            errorMessage = nil
        } catch {
            if initial { errorMessage = error.localizedDescription }
        }
    }
}

/// One elevation-chart sample tagged with its illumination run.
private struct IlluminationSample: Identifiable {
    let id: Int
    let date: Date
    let elevation: Double
    let run: Int
    let sunlit: Bool
}
