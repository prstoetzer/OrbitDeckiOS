import SwiftUI

struct OrbitalAnalysisView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var tab: AnalysisTab = .live
    @State private var crossings: [(Date, Double)] = []
    @State private var crossingsLoading = false
    @State private var selectedTransponderID: String?

    private enum AnalysisTab: String, CaseIterable, Identifiable {
        case live = "Live", elements = "Elements", nodal = "Nodal", doppler = "Doppler"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            if let satellite = store.selectedSatellite {
                Picker("Page", selection: $tab) {
                    ForEach(AnalysisTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                TimelineView(.periodic(from: .now, by: 5)) { context in
                    ScrollView {
                        VStack(spacing: 14) {
                            page(satellite: satellite, at: context.date)
                        }
                        .padding(.vertical, 14)
                    }
                }
            } else {
                LoadingOrError(isLoading: store.isRefreshingGP, error: store.lastError, emptyText: "No satellite selected")
            }
        }
        .task { if tab == .nodal { await loadCrossings() } }
        // `.task(id:)` does not reliably re-fire when `tab` (local Picker state)
        // changes in this view, so trigger the nodal load from an explicit onChange.
        .onChange(of: tab) { _, _ in if tab == .nodal { Task { await loadCrossings() } } }
        .onChange(of: store.preferences.selectedNorad) { _, _ in
            selectedTransponderID = nil
            if tab == .nodal { Task { await loadCrossings() } }
        }
    }

    private func selectedTransponder(_ satellite: SatelliteRecord) -> TransponderRecord? {
        satellite.transponders.first { $0.id == selectedTransponderID } ?? satellite.transponders.first
    }

    private var nodalKey: String {
        "\(tab.rawValue)-\(store.selectedSatellite?.id ?? 0)-\(store.preferences.observer.latitude)"
    }

    @ViewBuilder
    private func page(satellite: SatelliteRecord, at date: Date) -> some View {
        let look = try? OrbitPredictor.look(satellite, observer: store.preferences.observer, at: date)
        switch tab {
        case .live:
            SectionCard("Current geometry") {
                if let look {
                    MetricRow("Azimuth", "\(ODFormat.angle(look.azimuth))  \(ODFormat.compass(look.azimuth))")
                    MetricRow("Elevation", ODFormat.angle(look.elevation), valueColor: look.elevation >= 0 ? ODTheme.good : ODTheme.muted)
                    MetricRow("Range", ODFormat.distance(look.rangeKm))
                    MetricRow("Range rate", ODFormat.velocity(look.rangeRateKmS))
                    MetricRow("Sub-satellite latitude", String(format: "%+.4f°", look.subLatitude))
                    MetricRow("Sub-satellite longitude", String(format: "%+.4f°", look.subLongitude))
                    MetricRow("Altitude", String(format: "%.1f km", look.altitudeKm))
                    MetricRow("Footprint diameter", String(format: "%.0f km", look.footprintRadiusKm * 2))
                    MetricRow("Beta angle", String(format: "%+.2f°", look.betaAngleDeg))
                    MetricRow("Illumination", look.sunlit ? "Sunlit" : "Eclipsed", valueColor: look.sunlit ? ODTheme.warning : ODTheme.muted)
                    let eclFrac = LearnMath.eclipseFraction(altitudeKm: look.altitudeKm, betaDeg: look.betaAngleDeg)
                    MetricRow("Eclipse per orbit", eclFrac <= 0 ? "0% — continuous sun" : String(format: "%.1f%% of orbit", eclFrac * 100),
                              valueColor: eclFrac <= 0 ? ODTheme.good : ODTheme.muted)
                } else {
                    Text("Propagation unavailable for the selected element set.").foregroundStyle(ODTheme.warning)
                }
            }
        case .elements:
            let j2 = LearnMath.j2Rates(meanMotionRevDay: satellite.meanMotionRevPerDay,
                                       inclinationDeg: satellite.inclinationDeg,
                                       eccentricity: satellite.eccentricity)
            let decay = LearnMath.decayEstimate(meanMotion: satellite.meanMotionRevPerDay,
                                                eccentricity: satellite.eccentricity,
                                                bstar: satellite.bstar)
            SectionCard("Mean elements") {
                MetricRow("Epoch", ODFormat.utc.string(from: satellite.epoch))
                MetricRow("Element age", String(format: "%.2f days", satellite.elementAgeDays))
                MetricRow("Inclination", ODFormat.angle(satellite.inclinationDeg, decimals: 4))
                MetricRow("RAAN", ODFormat.angle(satellite.raanDeg, decimals: 4))
                MetricRow("Eccentricity", String(format: "%.7f", satellite.eccentricity))
                MetricRow("Argument of perigee", ODFormat.angle(satellite.argumentOfPerigeeDeg, decimals: 4))
                MetricRow("Mean anomaly", ODFormat.angle(satellite.meanAnomalyDeg, decimals: 4))
                MetricRow("Mean motion", String(format: "%.8f rev/day", satellite.meanMotionRevPerDay))
                MetricRow("Period", String(format: "%.3f min", satellite.periodMinutes))
            }
            SectionCard("Derived orbit") {
                MetricRow("Semi-major axis", String(format: "%.1f km", satellite.semiMajorAxisKm))
                MetricRow("Perigee", String(format: "%.1f km", satellite.perigeeKm))
                MetricRow("Apogee", String(format: "%.1f km", satellite.apogeeKm))
                MetricRow("J2 node regression", String(format: "%+.4f°/day", j2.nodeDegDay))
                MetricRow("J2 perigee precession", String(format: "%+.4f°/day", j2.perigeeDegDay))
                MetricRow("B* drag term", String(format: "%.4e (1/R⊕)", satellite.bstar))
                // Sun-synchronous orbits precess ~+0.9856°/day to track the Sun.
                let sunSync = abs(j2.nodeDegDay - 0.98565) < 0.10
                MetricRow("Sun-synchronous", sunSync ? "Yes" : "No",
                          valueColor: sunSync ? ODTheme.good : ODTheme.muted)
                if sunSync {
                    let ltan = FeatureEngine.localTimeOfAscendingNode(raanDeg: satellite.raanDeg, at: satellite.epoch)
                    let hh = Int(ltan), mm = Int((ltan - Double(Int(ltan))) * 60)
                    MetricRow("LTAN", String(format: "%02d:%02d local", hh, mm))
                }
                if decay.days >= 0 {
                    MetricRow("B* lifetime estimate", decayLabel(decay.days))
                    MetricRow("Decay anchor", decay.source)
                } else {
                    MetricRow("B* lifetime estimate", "No usable drag estimate")
                }
            }
        case .nodal:
            // Northern QTHs use the ascending node; southern QTHs the descending node.
            let ascendingNodes = store.preferences.observer.latitude >= 0
            SectionCard("\(ascendingNodes ? "Ascending" : "Descending") equator crossings") {
                if crossingsLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if crossings.isEmpty {
                    Text("No equator crossings found in the next ~12 orbits.").font(.caption).foregroundStyle(ODTheme.muted)
                } else {
                    ForEach(Array(crossings.prefix(16).enumerated()), id: \.offset) { _, crossing in
                        MetricRow(ODFormat.utc.string(from: crossing.0),
                                  String(format: "%+.2f° longitude", crossing.1))
                    }
                }
            }
        case .doppler:
            SectionCard("Live Doppler") {
                if let transponder = selectedTransponder(satellite), let look {
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
                    let corrected = OrbitPredictor.dopplerFrequencies(downlinkHz: transponder.downlinkCenter, uplinkHz: transponder.uplinkCenter, rangeRateKmS: look.rangeRateKmS)
                    MetricRow("Downlink", ODFormat.frequency(transponder.downlinkCenter))
                    MetricRow("RX (tune)", ODFormat.frequency(corrected.rx), valueColor: ODTheme.good)
                    MetricRow("Doppler (DN)", String(format: "%+lld Hz", corrected.rx - transponder.downlinkCenter))
                    if transponder.uplinkCenter > 0 {
                        MetricRow("Uplink", ODFormat.frequency(transponder.uplinkCenter))
                        MetricRow("TX (tune)", ODFormat.frequency(corrected.tx), valueColor: ODTheme.warning)
                        MetricRow("Doppler (UP)", String(format: "%+lld Hz", corrected.tx - transponder.uplinkCenter))
                    }
                } else {
                    Text(satellite.transponders.isEmpty
                         ? "No transponder data for this satellite. Cache the SatNOGS database from Home or Satellites, or add a manual transponder."
                         : "Propagation unavailable.")
                        .foregroundStyle(ODTheme.muted)
                }
            }
        }
    }

    @MainActor
    private func loadCrossings() async {
        guard let satellite = store.selectedSatellite else { crossings = []; return }
        crossingsLoading = crossings.isEmpty
        let start = Date()
        let end = start.addingTimeInterval(max(90, satellite.periodMinutes) * 60 * 12)
        // Southern-hemisphere stations reference the descending node.
        let ascending = store.preferences.observer.latitude >= 0
        do {
            crossings = try await Task.detached(priority: .userInitiated) {
                try OrbitPredictor.equatorCrossings(satellite, from: start, to: end, ascending: ascending)
            }.value
        } catch {
            crossings = []
        }
        crossingsLoading = false
    }

    private func decayLabel(_ days: Double) -> String {
        if days.isInfinite { return "Effectively stable" }
        if days < 1 { return "< 1 day" }
        if days < 365.25 { return String(format: "%.0f days", days) }
        return String(format: "%.1f years", days / 365.25)
    }
}
