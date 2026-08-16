import SwiftUI

struct TrackView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var trackPoints: [SkyPoint] = []
    @State private var currentPass: PredictedPass?

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            if let satellite = store.selectedSatellite {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let look = try? OrbitPredictor.look(
                        satellite,
                        observer: store.preferences.observer,
                        at: context.date
                    )
                    if let look {
                        ScrollView {
                            VStack(spacing: 14) {
                                PolarSkyPlot(
                                    points: trackPoints,
                                    currentPoint: SkyPoint(
                                        id: context.date,
                                        date: context.date,
                                        azimuth: look.azimuth,
                                        elevation: look.elevation
                                    ),
                                    minimumElevation: store.preferences.minElevation
                                )
                                .frame(maxHeight: 430)
                                .padding()

                                SectionCard("Live look") {
                                    nextEventRow(now: context.date)
                                    MetricRow("Azimuth", "\(ODFormat.angle(look.azimuth))  \(ODFormat.compass(look.azimuth))")
                                    MetricRow("Elevation", ODFormat.angle(look.elevation), valueColor: look.elevation >= 0 ? ODTheme.good : ODTheme.muted)
                                    MetricRow("Range", ODFormat.distance(look.rangeKm))
                                    MetricRow("Range rate", ODFormat.velocity(look.rangeRateKmS))
                                    MetricRow("Subpoint", String(format: "%.3f°, %.3f°", look.subLatitude, look.subLongitude))
                                    MetricRow("Altitude", String(format: "%.1f km", look.altitudeKm))
                                    MetricRow("Footprint radius", String(format: "%.0f km", look.footprintRadiusKm))
                                    MetricRow("Illumination", look.sunlit ? "Sunlit" : "Eclipsed", valueColor: look.sunlit ? ODTheme.warning : ODTheme.muted)
                                }

                                if let transponder = satellite.transponders.first {
                                    dopplerCard(transponder: transponder, rangeRateKmS: look.rangeRateKmS)
                                }
                            }
                            .padding(.bottom, 24)
                        }
                    } else {
                        ContentUnavailableView("Propagation failed", systemImage: "exclamationmark.triangle")
                    }
                }
            } else {
                LoadingOrError(isLoading: store.isRefreshingGP, error: store.lastError, emptyText: "No satellite selected")
            }
        }
        .task(id: taskKey) {
            trackPoints = []
            currentPass = nil
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func nextEventRow(now: Date) -> some View {
        if let pass = currentPass {
            if now < pass.aos {
                MetricRow("AOS in", "\(ODFormat.duration(pass.aos.timeIntervalSince(now))) · max \(ODFormat.angle(pass.maxElevation))", valueColor: ODTheme.accent)
            } else if now <= pass.los {
                MetricRow("LOS in", "\(ODFormat.duration(pass.los.timeIntervalSince(now))) @ \(ODFormat.utcShort.string(from: pass.los))", valueColor: ODTheme.good)
            } else {
                MetricRow("Next event", "updating…", valueColor: ODTheme.muted)
            }
        } else {
            MetricRow("Next event", "no pass in 10 days", valueColor: ODTheme.muted)
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

    private var taskKey: String {
        let o = store.preferences.observer
        return "\(store.selectedSatellite?.id ?? 0)-\(o.latitude)-\(o.longitude)-\(store.preferences.minElevation)"
    }

    @MainActor
    private func reload() async {
        guard let satellite = store.selectedSatellite else {
            trackPoints = []
            currentPass = nil
            return
        }
        let observer = store.preferences.observer
        // Non-throwing so a failure computing one piece never blanks the other.
        let computed = await Task.detached(priority: .userInitiated) { () -> (path: [SkyPoint], pass: PredictedPass?) in
            guard let pass = try? OrbitPredictor.currentOrNextPass(satellite, observer: observer) else {
                return ([], nil)
            }
            let path = (try? OrbitPredictor.skyPath(satellite, observer: observer, pass: pass)) ?? []
            return (path, pass)
        }.value
        if Task.isCancelled { return }
        trackPoints = computed.path
        currentPass = computed.pass
    }
}
