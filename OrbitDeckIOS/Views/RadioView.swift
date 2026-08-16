import SwiftUI

struct RadioView: View {
    private enum RadioTab: String, CaseIterable, Identifiable {
        case link = "Link budget"
        case playbook = "Doppler playbook"
        case passband = "Passband plan"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: OrbitStore
    @State private var selectedTransponderID: String?
    @State private var passes: [PredictedPass] = []
    @State private var selectedPassID: Date?
    @State private var tab: RadioTab = .link
    @State private var passbandPercent = 50.0
    @State private var passTimePercent = 50.0
    @State private var intervalSeconds = 60.0
    @State private var hold = "downlink"
    @State private var groundTxPowerW = 5.0
    @State private var groundTxGainDb = 0.0
    @State private var groundRxGainDb = 12.0
    @State private var lineLossDb = 1.5
    @State private var satelliteTxPowerW = 1.0
    @State private var satelliteGainDb = 2.0
    @State private var isLoading = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var shareLabel = ""

    private var selectedPass: PredictedPass? {
        guard let selectedPassID else { return passes.first }
        return passes.first { $0.id == selectedPassID } ?? passes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            if let satellite = store.selectedSatellite {
                ScrollView {
                    VStack(spacing: 14) {
                        SectionCard("Operating setup") {
                            if isLoading {
                                HStack { ProgressView(); Text("Loading pass/transponder data…") }
                            }
                            if let error { Text(error).foregroundStyle(ODTheme.warning) }

                            Picker("Transponder", selection: $selectedTransponderID) {
                                if satellite.transponders.isEmpty {
                                    Text("No transponder loaded").tag(String?.none)
                                }
                                ForEach(satellite.transponders) { tx in
                                    Text(transponderLabel(tx)).tag(String?.some(tx.id))
                                }
                            }

                            Picker("Plan for pass", selection: $selectedPassID) {
                                if passes.isEmpty { Text("No upcoming pass").tag(Date?.none) }
                                ForEach(passes) { pass in
                                    Text(passLabel(pass)).tag(Date?.some(pass.id))
                                }
                            }

                            Picker("View", selection: $tab) {
                                ForEach(RadioTab.allCases) { item in Text(item.rawValue).tag(item) }
                            }
                            .pickerStyle(.segmented)
                        }

                        if let tx = selectedTransponder(satellite) {
                            switch tab {
                            case .link: linkBudgetView(satellite: satellite, transponder: tx)
                            case .playbook: playbookView(satellite: satellite, transponder: tx)
                            case .passband: passbandView(satellite: satellite, transponder: tx)
                            }
                        } else {
                            SectionCard("Radio") {
                                Text("No transponder is available for this satellite.")
                                    .foregroundStyle(ODTheme.muted)
                                Button("Reload SatNOGS") { Task { await loadTransponders(for: satellite.id) } }
                            }
                        }
                    }
                    .padding()
                }
                .task(id: satellite.id) {
                    selectedTransponderID = satellite.transponders.first?.id
                    await loadAll(for: satellite)
                }
                .onChange(of: selectedPassID) { snapToTCA() }
                .onChange(of: selectedTransponderID) { passbandPercent = 50; shareURL = nil }
            } else {
                LoadingOrError(isLoading: store.isRefreshingGP, error: store.lastError,
                               emptyText: "No satellite selected")
            }
        }
    }

    @ViewBuilder
    private func linkBudgetView(satellite: SatelliteRecord, transponder: TransponderRecord) -> some View {
        if let pass = selectedPass,
           let look = try? OrbitPredictor.look(satellite, observer: store.preferences.observer,
                                                at: passTime(pass)) {
            let nominal = nominalPair(transponder)
            let downlink = FeatureCompletionEngine.linkBudget(
                rangeKm: look.rangeKm, frequencyHz: Double(max(1, nominal.downlink)),
                txPowerW: satelliteTxPowerW, txGainDb: satelliteGainDb,
                rxGainDb: groundRxGainDb, lineLossDb: lineLossDb)
            let uplink = nominal.uplink > 0 ? FeatureCompletionEngine.linkBudget(
                rangeKm: look.rangeKm, frequencyHz: Double(nominal.uplink),
                txPowerW: groundTxPowerW, txGainDb: groundTxGainDb,
                rxGainDb: 0, lineLossDb: lineLossDb) : nil
            let corrected = OrbitPredictor.dopplerFrequencies(
                downlinkHz: nominal.downlink, uplinkHz: nominal.uplink,
                rangeRateKmS: look.rangeRateKmS)

            SectionCard("Pass") {
                MetricRow("AOS", ODFormat.utc.string(from: pass.aos))
                MetricRow("TCA", "\(ODFormat.utc.string(from: pass.tca)) · max \(ODFormat.angle(pass.maxElevation))")
                MetricRow("LOS", ODFormat.utc.string(from: pass.los))
                MetricRow("Duration", ODFormat.duration(pass.duration))
            }

            SectionCard("Geometry in pass") {
                HStack {
                    Text("Time")
                    Spacer()
                    Text("\(ODFormat.utcShort.string(from: passTime(pass))) · el \(ODFormat.angle(look.elevation))")
                        .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                }
                Slider(value: $passTimePercent, in: 0...100, step: 0.5)
                HStack {
                    Text("AOS").font(.caption).foregroundStyle(ODTheme.muted)
                    Spacer()
                    Button("TCA") { snapToTCA() }.buttonStyle(.bordered)
                    Spacer()
                    Text("LOS").font(.caption).foregroundStyle(ODTheme.muted)
                }
                if transponder.isLinear { passbandSlider(transponder) }
                MetricRow("Slant range", ODFormat.distance(look.rangeKm))
                MetricRow("Elevation", ODFormat.angle(look.elevation))
                MetricRow("Range rate", ODFormat.velocity(look.rangeRateKmS))
                MetricRow("Propagation delay", String(format: "%.2f ms one-way", downlink.propagationDelayMs))
            }

            SectionCard("Station assumptions") {
                HStack { numericField("Your TX power", value: $groundTxPowerW, unit: "W"); numericField("TX gain", value: $groundTxGainDb, unit: "dBi") }
                HStack { numericField("RX gain", value: $groundRxGainDb, unit: "dBi"); numericField("Line loss", value: $lineLossDb, unit: "dB") }
                HStack { numericField("Sat TX power", value: $satelliteTxPowerW, unit: "W"); numericField("Sat gain", value: $satelliteGainDb, unit: "dBi") }
            }

            SectionCard("Downlink \(ODFormat.frequency(nominal.downlink))") {
                MetricRow("Satellite EIRP", String(format: "%.1f dBm", downlink.eirpDbm))
                MetricRow("Free-space path loss", String(format: "%.1f dB", downlink.freeSpacePathLossDb))
                MetricRow("Estimated received power", String(format: "%.1f dBm", downlink.receivedPowerDbm))
                MetricRow("Doppler-corrected RX", ODFormat.frequency(corrected.rx), valueColor: ODTheme.good)
            }
            if let uplink {
                SectionCard("Uplink \(ODFormat.frequency(nominal.uplink))") {
                    MetricRow("Your EIRP", String(format: "%.1f dBm", uplink.eirpDbm))
                    MetricRow("Free-space path loss", String(format: "%.1f dB", uplink.freeSpacePathLossDb))
                    MetricRow("Doppler-corrected TX", ODFormat.frequency(corrected.tx), valueColor: ODTheme.warning)
                }
            }
            Text("Planning estimate, not a calibrated measurement. The time scrubber evaluates the selected pass anywhere from AOS through LOS; use TCA for closest-approach geometry.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        } else {
            SectionCard("Link budget") { Text("No upcoming pass is available above the configured minimum elevation.").foregroundStyle(ODTheme.muted) }
        }
    }

    @ViewBuilder
    private func playbookView(satellite: SatelliteRecord, transponder: TransponderRecord) -> some View {
        if let pass = selectedPass {
            SectionCard("Doppler playbook") {
                Picker("Interval", selection: $intervalSeconds) {
                    Text("30 s").tag(30.0); Text("60 s").tag(60.0); Text("120 s").tag(120.0)
                }.pickerStyle(.segmented)
                if transponder.isLinear {
                    Picker("Linear hold", selection: $hold) {
                        Text("Fixed downlink").tag("downlink")
                        Text("Fixed uplink").tag("uplink")
                    }.pickerStyle(.segmented)
                    passbandSlider(transponder)
                }

                let rows = (try? FeatureCompletionEngine.radioPlaybook(
                    satellite: satellite, observer: store.preferences.observer,
                    pass: pass, transponder: transponder,
                    intervalSeconds: intervalSeconds, hold: hold,
                    passbandPercent: passbandPercent)) ?? []

                HStack {
                    Button("Prepare CSV") { preparePlaybook(rows, satellite, transponder, pass, pdf: false) }
                    Button("Prepare PDF") { preparePlaybook(rows, satellite, transponder, pass, pdf: true) }
                    if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") } }
                }

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 16) {
                            Text("Min").frame(width: 48, alignment: .trailing)
                            Text("Az").frame(width: 56, alignment: .trailing)
                            Text("El").frame(width: 56, alignment: .trailing)
                            Text("RR km/s").frame(width: 88, alignment: .trailing)
                            Text("RX MHz").frame(width: 110, alignment: .trailing)
                            Text("TX MHz").frame(width: 110, alignment: .trailing)
                        }.font(.caption.bold().monospaced())
                        Divider()
                        ForEach(rows) { row in
                            HStack(spacing: 16) {
                                Text(String(format: "%.1f", row.date.timeIntervalSince(pass.aos)/60)).frame(width: 48, alignment: .trailing)
                                Text(String(format: "%.0f°", row.azimuthDegrees)).frame(width: 56, alignment: .trailing)
                                Text(String(format: "%.0f°", row.elevationDegrees)).frame(width: 56, alignment: .trailing)
                                Text(String(format: "%+.3f", row.rangeRateKmS)).frame(width: 88, alignment: .trailing)
                                Text(String(format: "%.4f", Double(row.receiveHz)/1e6)).frame(width: 110, alignment: .trailing)
                                Text(row.transmitHz > 0 ? String(format: "%.4f", Double(row.transmitHz)/1e6) : "—").frame(width: 110, alignment: .trailing)
                            }.font(.caption.monospaced())
                        }
                    }
                }
                Text(transponder.isLinear
                     ? "For a linear bird, the selected hold rule fixes one leg and derives the other through the standard pass-based Doppler convention."
                     : "FM/independent mode applies one-way correction separately to the receive and transmit channels.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        } else {
            SectionCard("Doppler playbook") { Text("No upcoming pass available.").foregroundStyle(ODTheme.muted) }
        }
    }

    @ViewBuilder
    private func passbandView(satellite: SatelliteRecord, transponder: TransponderRecord) -> some View {
        let rows = FeatureCompletionEngine.passbandPlan(transponder)
        SectionCard("Passband plan") {
            Text(transponder.isLinear
                 ? "\(satellite.name) · \(transponder.kind) · \(String(format: "%.0f", Double(transponder.bandwidth)/1000)) kHz. The table maps matching uplink/downlink points across the full passband."
                 : "\(satellite.name) · \(transponder.kind) · single-channel transmitter.")
                .font(.caption).foregroundStyle(ODTheme.muted)
            ForEach(rows) { row in
                HStack {
                    Text("\(row.percent)%").frame(width: 55, alignment: .leading).font(.body.monospaced())
                    Spacer()
                    Text(ODFormat.frequency(row.downlinkHz)).font(.body.monospaced())
                    Image(systemName: transponder.invert ? "arrow.left.arrow.right" : "arrow.right")
                        .foregroundStyle(ODTheme.muted)
                    Text(row.uplinkHz > 0 ? ODFormat.frequency(row.uplinkHz) : "—").font(.body.monospaced())
                }
                Divider()
            }
        }
    }

    @ViewBuilder
    private func passbandSlider(_ transponder: TransponderRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Passband position")
                Spacer()
                let pair = nominalPair(transponder)
                Text(String(format: "%.0f%% · DL %.4f MHz", passbandPercent, Double(pair.downlink)/1e6))
                    .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
            }
            Slider(value: $passbandPercent, in: 0...100, step: 1)
        }
    }

    @ViewBuilder
    private func numericField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(ODTheme.muted)
            HStack(spacing: 4) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.odField)
                    .keyboardType(.decimalPad)
                Text(unit).font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func passTime(_ pass: PredictedPass) -> Date {
        pass.aos.addingTimeInterval(pass.duration * max(0, min(100, passTimePercent)) / 100)
    }

    private func snapToTCA() {
        guard let pass = selectedPass, pass.duration > 0 else { return }
        passTimePercent = max(0, min(100, pass.tca.timeIntervalSince(pass.aos) / pass.duration * 100))
        shareURL = nil
    }

    private func nominalPair(_ transponder: TransponderRecord) -> (downlink: Int64, uplink: Int64) {
        let offset = transponder.isLinear
            ? Int64((Double(transponder.bandwidth) * max(0, min(100, passbandPercent)) / 100).rounded()) : 0
        return OrbitPredictor.passbandFrequencies(transponder, offsetHz: offset)
    }

    private func selectedTransponder(_ satellite: SatelliteRecord) -> TransponderRecord? {
        if let selectedTransponderID,
           let hit = satellite.transponders.first(where: { $0.id == selectedTransponderID }) { return hit }
        return satellite.transponders.first
    }

    private func transponderLabel(_ tx: TransponderRecord) -> String {
        "\(tx.description.isEmpty ? tx.kind : tx.description) — \(ODFormat.frequency(tx.downlinkCenter))"
    }

    private func passLabel(_ pass: PredictedPass) -> String {
        "\(ODFormat.utcShort.string(from: pass.aos)) · max \(String(format: "%.0f°", pass.maxElevation)) · \(String(format: "%.0f min", pass.duration/60))"
    }

    @MainActor
    private func loadAll(for satellite: SatelliteRecord) async {
        isLoading = true; error = nil; shareURL = nil
        if satellite.transponders.isEmpty { await loadTransponders(for: satellite.id) }
        guard let current = store.selectedSatellite else { isLoading = false; return }
        if selectedTransponderID == nil { selectedTransponderID = current.transponders.first?.id }
        let observer = store.preferences.observer
        let minEl = store.preferences.minElevation
        do {
            passes = try await Task.detached {
                try OrbitPredictor.predictPasses(current, observer: observer, from: .now,
                                                 minElevation: minEl, maxCount: 12, horizonDays: 7)
            }.value
            selectedPassID = passes.first?.id
            snapToTCA()
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    @MainActor
    private func loadTransponders(for norad: UInt) async {
        await store.loadTransponders(for: norad)
        if let refreshed = store.selectedSatellite { selectedTransponderID = refreshed.transponders.first?.id }
    }

    @MainActor
    private func preparePlaybook(_ rows: [RadioPlaybookRow], _ satellite: SatelliteRecord,
                                 _ transponder: TransponderRecord, _ pass: PredictedPass, pdf: Bool) {
        guard !rows.isEmpty else { return }
        do {
            let base = satellite.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
            if pdf {
                shareURL = try OrbitExportService.temporaryFile(
                    name: "doppler_\(base).pdf",
                    data: OrbitExportService.radioPlaybookPDF(rows, satellite: satellite,
                                                               transponder: transponder, hold: hold, pass: pass))
                shareLabel = "PDF"
            } else {
                shareURL = try OrbitExportService.temporaryTextFile(
                    name: "doppler_\(base).csv",
                    text: OrbitExportService.radioPlaybookCSV(rows, satellite: satellite,
                                                               transponder: transponder, hold: hold))
                shareLabel = "CSV"
            }
        } catch { self.error = error.localizedDescription }
    }
}
