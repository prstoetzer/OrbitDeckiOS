import SwiftUI

// ===========================================================================
//  FT4Views.swift — Home FT4 card (full-duplex, linear-transponder)
//
//  Shown only when an audio interface is available. Decodes the downlink and
//  (optionally) transmits the uplink on alternating 7.5 s slots. PTT is over CAT
//  when supported; otherwise a prominent manual-PTT indicator tells the operator
//  when to key. A persistent banner warns about FT4's ~100% duty cycle.
// ===========================================================================

struct HomeFT4Card: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var ft4: FT4Engine
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    let satellite: SatelliteRecord

    var body: some View {
        if audio.audioAvailable {
            SectionCard("FT4 (full duplex)") {
                cautionBanner
                if !ft4.errorText.isEmpty {
                    Text(ft4.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(ft4.isRunning ? ODTheme.good : ODTheme.muted).frame(width: 10, height: 10)
                    Text(ft4.status).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(ft4.isRunning ? "Stop" : "Start") { toggleRun() }
                        .buttonStyle(.bordered)
                }

                if ft4.isTransmitting { txIndicator }

                if !ft4.decodes.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(ft4.decodes.suffix(6).reversed()) { d in decodeRow(d) }
                }

                Divider().opacity(0.4)
                txControls
            }
        }
    }

    private var cautionBanner: some View {
        Text("FT4 runs at nearly 100% duty cycle. Reduce power out of respect for other operators sharing this linear transponder.")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(ODTheme.warning.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var txIndicator: some View {
        Group {
            if ft4.pttOverCAT {
                Label("Transmitting (CAT PTT)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.bold)).foregroundStyle(ODTheme.good)
            } else {
                Label("TRANSMIT NOW — key your radio (VOX / manual PTT)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(ODTheme.warning)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func decodeRow(_ d: FT4DecodedMessage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(d.text).font(.callout.monospaced())
                Text("score \(d.score) · \(Int(d.freqHz)) Hz").font(.caption2).foregroundStyle(ODTheme.muted)
            }
            Spacer()
            if qso.config.enabled {
                Button { logDecode(d) } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var txControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Enable transmit", isOn: $ft4.txEnabled)
            TextField("TX message (e.g. CQ N8HM FM18)", text: $ft4.txMessage)
                .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
            Toggle("Transmit on even slots", isOn: $ft4.txOnEvenSlots)
            if !ft4.pttOverCAT {
                Text("This radio has no CAT PTT — use VOX or key manually when the TX indicator shows. Configure a CAT radio (CI-V / Yaesu / Kenwood / rigctld / Icom network) for automatic keying.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func toggleRun() {
        if ft4.isRunning {
            ft4.stop()
        } else if let source = audio.makeSource() {
            ft4.start(source: source, myCall: qso.config.myCall, myGrid: store.operatorGrid6)
        } else {
            ft4.errorText = "No audio interface available."
        }
    }

    private func logDecode(_ d: FT4DecodedMessage) {
        var q = QSORecord.prefilled(satellite: satellite, transponder: rig.transponder(for: satellite),
                                    myGrid: store.operatorGrid6, myCall: qso.config.myCall, defaultRst: "+00")
        q.mode = "FT4"
        q.call = Self.parseCall(d.text)
        q.notes = d.text
        qso.add(q)
    }

    /// Best-effort worked-callsign extraction from an FT4 message.
    static func parseCall(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        let skip: Set<String> = ["CQ", "DE", "QRZ", "RR73", "RRR", "73", "R"]
        for t in tokens where !skip.contains(t) {
            let hasDigit = t.contains { $0.isNumber }, hasAlpha = t.contains { $0.isLetter }
            let isReport = t.hasPrefix("+") || t.hasPrefix("-")
            let isGrid = t.count == 4 && t.prefix(2).allSatisfy { $0.isLetter } && t.suffix(2).allSatisfy { $0.isNumber }
            if hasDigit && hasAlpha && !isReport && !isGrid { return t }
        }
        return tokens.first ?? ""
    }
}
