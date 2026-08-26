import SwiftUI

// ===========================================================================
//  FT4Views.swift — Home FT4 card (full-duplex, linear-transponder)
//
//  Shown only when an audio interface is available. Decodes the downlink and
//  (optionally) transmits the uplink on alternating 7.5 s slots. PTT is over CAT
//  when supported; otherwise a prominent manual-PTT indicator tells the operator
//  when to key. A persistent banner warns about FT4's ~100% duty cycle.
// ===========================================================================

// ---------------------------------------------------------------------------
//  Shared audio-level UI (used by both the FT4 and SSTV cards)
// ---------------------------------------------------------------------------

/// A horizontal peak-level bar: green → yellow → red as it approaches clipping.
struct AudioLevelBar: View {
    let level: Float          // 0…1
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(ODTheme.panel)
                Capsule().fill(barColor)
                    .frame(width: g.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 6)
    }
    private var barColor: Color {
        level > 0.95 ? ODTheme.warning : (level > 0.7 ? .yellow : ODTheme.good)
    }
}

/// A slider flanked by −/＋ nudge buttons for precise adjustment. Generic over any
/// BinaryFloatingPoint bound so both Float (gains) and Double (slant/tuning) work.
struct FineSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V

    var body: some View {
        HStack(spacing: 8) {
            nudge("minus") { value = max(range.lowerBound, value - step) }
            Slider(value: $value, in: range)
            nudge("plus") { value = min(range.upperBound, value + step) }
        }
    }
    private func nudge(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "\(symbol).circle.fill").font(.title3) }
            .buttonStyle(.borderless)
    }
}

/// A labeled gain slider + live level meter, with a low-signal / clipping notice.
struct AudioLevelControl: View {
    let title: String
    @Binding var gain: Float
    let level: Float
    var range: ClosedRange<Float> = 0.25...8
    var step: Float = 0.05
    var showLevel: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(ODTheme.muted)
                Spacer()
                Text(String(format: "%.2f×", gain)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $gain, range: range, step: step)
            if showLevel {
                AudioLevelBar(level: level)
                if let note = notice {
                    Text(note).font(.caption2).foregroundStyle(level > 0.95 ? ODTheme.warning : ODTheme.muted)
                }
            }
        }
    }
    private var notice: String? {
        if level > 0.98 { return "Clipping — reduce gain" }
        if level > 0 && level < 0.05 { return "Signal very low — increase gain" }
        return nil
    }
}

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
                    Text(ft4.status).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(ft4.isRunning ? "Stop" : "Start") { toggleRun() }
                        .buttonStyle(.bordered)
                }

                if ft4.isRunning {
                    slotClock
                    waterfall
                    audioControls
                }
                if ft4.isTransmitting { txIndicator }

                if !ft4.decodes.isEmpty { decodeTable }

                Divider().opacity(0.4)
                txControls
            }
            .onAppear { setupLogging() }
        }
    }

    /// Log auto-sequenced QSOs with the current satellite/transponder context.
    private func setupLogging() {
        ft4.onQSOComplete = { [weak store, weak rig, weak qso] call, grid, rSent, rRcvd in
            guard let store, let rig, let qso else { return }
            let sat = store.selectedSatellite
            var q = QSORecord.prefilled(satellite: sat, transponder: sat.flatMap { rig.transponder(for: $0) },
                                        myGrid: store.operatorGrid6, myCall: qso.config.myCall, defaultRst: "-10")
            q.mode = "FT4"; q.call = call; q.grid = grid; q.rstSent = rSent; q.rstRcvd = rRcvd
            qso.add(q)
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
        VStack(spacing: 6) {
            if ft4.pttOverCAT {
                Label("Transmitting (CAT PTT)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.bold)).foregroundStyle(ODTheme.good)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("TRANSMIT NOW — key your radio (VOX / manual PTT)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(ODTheme.warning)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                Text("TX audio").font(.caption2).foregroundStyle(ODTheme.muted)
                ProgressView(value: Double(min(1, ft4.txLevel))).tint(ODTheme.good)
            }
            Text("TX audio is sent out the audio interface to the radio — monitor the rig, not the phone.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    /// Live slot clock: counts down to the next 7.5 s slot and shows whether it's a
    /// TX or RX slot (like the WSJT-X progress bar).
    private var slotClock: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let t = context.date.timeIntervalSince1970
            let period = 7.5
            let intoSlot = t.truncatingRemainder(dividingBy: period)
            let remaining = period - intoSlot
            let nextSlot = Int(t / period) + 1
            let nextIsTx = ft4.txEnabled && ((nextSlot % 2 == 0) == ft4.txOnEvenSlots)
            HStack(spacing: 8) {
                Image(systemName: nextIsTx ? "antenna.radiowaves.left.and.right" : "waveform")
                    .foregroundStyle(nextIsTx ? ODTheme.warning : ODTheme.accent)
                Text(ft4.isTransmitting ? "Transmitting…" : String(format: "%@ slot in %.1fs",
                                                                    nextIsTx ? "TX" : "RX", remaining))
                    .font(.caption.monospacedDigit())
                Spacer()
                ProgressView(value: min(1, intoSlot / period)).frame(width: 90)
            }
        }
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    private static let utcShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    /// Scrolling spectrum waterfall (newest at the bottom), with a frequency axis.
    @ViewBuilder private var waterfall: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let img = ft4.waterfall {
                Image(uiImage: img).resizable().interpolation(.none)
                    .frame(height: 90).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(ODTheme.panel).frame(height: 90)
                    .overlay(Text("Waterfall").font(.caption2).foregroundStyle(ODTheme.muted))
            }
            HStack {
                Text("0").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
                Spacer(); Text("1.5 kHz").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
                Spacer(); Text("3 kHz").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// RX/TX audio level controls.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudioLevelControl(title: "Input (RX)", gain: $ft4.inputGain, level: ft4.rxLevel)
            AudioLevelControl(title: "Output (TX)", gain: $ft4.outputGain, level: min(1, ft4.txLevel * ft4.outputGain), range: 0...1)
            Text("Set input so the meter peaks in the green on a decode; keep TX modest — FT4 is ~100% duty cycle.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    /// Decode list — one tappable row per station, message prominent, metadata below.
    private var decodeTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.4)
            Text("Band activity — tap a station to work it")
                .font(.caption2).foregroundStyle(ODTheme.muted).padding(.vertical, 2)
            ForEach(ft4.decodes.suffix(12).reversed()) { d in
                decodeRow(d)
                Divider().opacity(0.25)
            }
        }
    }

    private func decodeRow(_ d: FT4DecodedMessage) -> some View {
        let f = FT4Engine.parse(d.text)
        let toMe = ft4.isToMe(d.text)
        let isCQ = f?.isCQ == true
        let color: Color = toMe ? ODTheme.accent : (isCQ ? ODTheme.good : .primary)
        return Button { ft4.work(d) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.text)
                        .font(.callout.monospaced().weight(toMe || isCQ ? .semibold : .regular))
                        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(Self.utcShort.string(from: d.slotDate))  ·  \(d.snr) dB  ·  \(Int(d.freqHz)) Hz")
                        .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }
                Spacer(minLength: 4)
                if isCQ || toMe {
                    Image(systemName: "arrowshape.turn.up.left.circle.fill")
                        .font(.title3).foregroundStyle(ODTheme.accent)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var txControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Enable transmit", isOn: $ft4.txEnabled)
            Toggle("Auto-sequence QSO", isOn: $ft4.autoSequence)
            if ft4.autoSequence {
                HStack {
                    Button("Call CQ") { ft4.callCQ() }.buttonStyle(.bordered)
                    Spacer()
                    if !ft4.seqStatus.isEmpty {
                        Text(ft4.seqStatus).font(.caption).foregroundStyle(ODTheme.accent)
                    }
                }
                Text("Tap Reply on a decoded CQ, or Call CQ. The report you send is taken from the other station's decoded SNR automatically; the exchange (grid → report → RR73) and logging run on their own. Watch the TX indicator to key if you have no CAT PTT.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            } else {
                TextField("TX message (e.g. CQ N8HM FM18)", text: $ft4.txMessage)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
                Toggle("Transmit on even slots", isOn: $ft4.txOnEvenSlots)
            }
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

}
