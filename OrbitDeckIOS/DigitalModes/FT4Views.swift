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
                    .animation(.easeOut(duration: 0.18), value: level)
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

/// A labeled gain slider + live level meter. The level source is smoothed (fast
/// attack / slow release) and the bar turns amber/red near clipping, so there's no
/// separate notice line — a line that popped in and out was distracting.
struct AudioLevelControl: View {
    let title: String
    @Binding var gain: Float
    let level: Float
    // Up to 40× so low line-level sources (e.g. an IC-821 ACC/DATA jack, well below
    // headphone level) can be brought up without an external preamp.
    var range: ClosedRange<Float> = 0.25...40
    var step: Float = 0.25
    var showLevel: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(ODTheme.muted)
                Spacer()
                Text(String(format: "%.2f×", gain)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $gain, range: range, step: step)
            if showLevel { AudioLevelBar(level: level) }
        }
    }
}

struct HomeFT4Card: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var ft4: FT4Engine
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    @AppStorage(FeatureVisibility.ft4Key) private var visibility = FeatureVisibility.auto
    @AppStorage(PSKReporterSettings.enabledKey) private var pskEnabled = false
    @AppStorage(FT4Settings.dataModeKey) private var ft4DataMode = true
    @AppStorage(FT4Settings.autoCalibrateKey) private var ft4AutoCal = false
    @State private var showSetup = false
    @State private var newBlockedCall = ""
    /// Manual TX message being typed; committed to the engine on Return so a half-typed
    /// message can't late-start or replace a burst already on the air.
    @State private var messageDraft = ""
    @FocusState private var messageFocused: Bool
    let satellite: SatelliteRecord

    private var visible: Bool {
        switch visibility { case .auto: audio.audioAvailable; case .always: true; case .off: false }
    }

    var body: some View {
        if visible {
            SectionCard("FT4 (full duplex)") {
                cautionBanner
                AudioHealthBanner(active: ft4.isRunning)
                if !ft4.errorText.isEmpty {
                    Text(ft4.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                // Satellite FT4 needs full duplex to hear your own downlink; split VFO
                // is half duplex, so it can't start there.
                let halfDuplex = rig.isSplitVFO && !ft4.isRunning
                if halfDuplex {
                    Text("FT4 needs a full-duplex station. The radio is running half duplex (split VFO or same-band transmit hold) for this satellite.")
                        .font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(ft4.isRunning ? ODTheme.good : ODTheme.muted).frame(width: 10, height: 10)
                    Text(ft4.status).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(ft4.isRunning ? "Stop" : "Start") { toggleRun() }
                        .buttonStyle(.bordered)
                        .disabled(halfDuplex)
                }
                SatelliteStatusLine(satellite: satellite)
                DopplerFrequencyLine(satellite: satellite, transponderOverride: rig.transponder(for: satellite))
                if ft4.isRunning { dopplerLine }

                nextTxPanel

                if ft4.isRunning {
                    // Slot clock only when the Next-TX panel isn't already showing the
                    // countdown, to avoid duplicate timers.
                    if !(ft4.txEnabled && !ft4.txMessage.isEmpty) { slotClock }
                    waterfall
                }
                if ft4.isTransmitting { txIndicator }

                if !ft4.decodes.isEmpty { decodeTable }

                Divider().opacity(0.4)
                txControlsPrimary

                // Secondary setup (TX frequency, manual message, audio levels) tucked
                // behind a disclosure so the card stays uncluttered during operation.
                DisclosureGroup("Setup & audio levels", isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 10) {
                        if ft4.isRunning { audioControls }
                        txSetup
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline).tint(ODTheme.accent)
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

    /// Live net Doppler readout (downlink/uplink shift + drift rate) from the ephemeris.
    @ViewBuilder private var dopplerLine: some View {
        if let p = ft4.dopplerProvider {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                if let d = p(now), let d1 = p(now.addingTimeInterval(1)) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path").font(.system(size: 9)).foregroundStyle(ODTheme.muted)
                        Text(String(format: "Doppler  DL %+.0f · UL %+.0f Hz  ·  %+.0f Hz/s", d.dl, d.ul, d1.dl - d.dl))
                        Spacer()
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }
            }
        }
    }

    /// Prominent "what will I send next" panel — appears the moment you tap a station
    /// (or Call CQ), so you always know the queued message, the sequence state, and
    /// when it goes out.
    @ViewBuilder private var nextTxPanel: some View {
        if ft4.txEnabled && !ft4.txMessage.isEmpty {
            let tint: Color = ft4.isTransmitting ? ODTheme.warning : ODTheme.accent
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(ft4.isTransmitting ? "TRANSMITTING" : "NEXT TX",
                          systemImage: ft4.isTransmitting ? "dot.radiowaves.left.and.right" : "arrowshape.turn.up.right.fill")
                        .font(.caption2.weight(.bold)).foregroundStyle(tint)
                    Spacer()
                    if !ft4.seqStatus.isEmpty {
                        Text(ft4.seqStatus).font(.caption2).foregroundStyle(ODTheme.muted).lineLimit(1)
                    }
                }
                Text(ft4.txMessage)
                    .font(.callout.monospaced().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let t = context.date.timeIntervalSince1970
                    let period = 7.5
                    let remaining = period - t.truncatingRemainder(dividingBy: period)
                    let nextIsTx = ((Int(t / period) + 1) % 2 == 0) == ft4.txOnEvenSlots
                    let secs = nextIsTx ? remaining : remaining + period
                    Text(ft4.isTransmitting ? "On the air now"
                         : String(format: "Sends in %.0fs · TX %@ Hz on %@ slots",
                                   secs, "\(Int(ft4.txAudioFreq))", ft4.txOnEvenSlots ? "even" : "odd"))
                        .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    /// Spectrum waterfall (0–3 kHz) with a live TX-frequency marker.
    @ViewBuilder private var waterfall: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let img = ft4.waterfall {
                        Image(uiImage: img).resizable()
                            .frame(width: geo.size.width, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(ODTheme.panel)
                            .overlay(Text("Waterfall").font(.caption2).foregroundStyle(ODTheme.muted))
                    }
                    // TX frequency marker (0–3 kHz spans the full width).
                    let x = geo.size.width * CGFloat(min(1, max(0, ft4.txAudioFreq / 3000)))
                    Rectangle().fill(.orange).frame(width: 2, height: 130).offset(x: x - 1)
                    Text("TX").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        .offset(x: min(geo.size.width - 18, max(0, x - 6)), y: 2)
                }
            }
            .frame(height: 130)
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

    /// WSJT-X-style band-activity panel: a framed, fixed-height, self-scrolling
    /// monospaced list so the card doesn't grow without bound. Newest at the bottom.
    private var decodeTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Label("Band Activity", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.accent)
                Spacer()
                legendDot(ODTheme.good, "CQ"); legendDot(ODTheme.accent, "you")
                legendDot(.orange, "TX"); legendDot(.cyan, "self")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))

            Divider().overlay(ODTheme.muted.opacity(0.3))

            ScrollView {
                let items = Array(ft4.decodes.suffix(60))
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, d in
                        // Separate transmit periods with a faint rule (like WSJT-X).
                        if idx > 0 && items[idx - 1].atSlot != d.atSlot {
                            Divider().overlay(ODTheme.muted.opacity(0.35))
                        }
                        decodeRow(d)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .frame(height: 200)
            .defaultScrollAnchor(.bottom)

            Divider().overlay(ODTheme.muted.opacity(0.3))
            Text("Tap a station to work it · long-press to pounce or block").font(.system(size: 10)).foregroundStyle(ODTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color.black.opacity(0.9), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ODTheme.muted.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(ODTheme.muted)
        }
    }

    private func decodeRow(_ d: FT4DecodedMessage) -> some View {
        let f = FT4Engine.parse(d.text)
        let toMe = ft4.isToMe(d.text)
        let isCQ = f?.isCQ == true
        let color: Color
        if d.kind == .sent { color = .orange }                 // my transmitted message
        else if ft4.isFromMe(d.text) { color = .cyan }         // my own signal heard via full duplex
        else if toMe { color = ODTheme.accent }                // someone calling me
        else if isCQ { color = ODTheme.good }                  // CQ
        else { color = .white }
        // WSJT-X row: time · dB · freq · message, monospaced and aligned.
        let dt = d.kind == .sent ? " TX" : String(format: "%3d", d.snr)
        return Button { if d.kind != .sent { ft4.work(d) } } label: {
            HStack(spacing: 8) {
                Text(Self.utc.string(from: d.slotDate)).foregroundStyle(color.opacity(0.7))
                Text(dt).foregroundStyle(color.opacity(0.9))
                Text(String(format: "%4d", Int(d.freqHz))).foregroundStyle(color.opacity(0.7))
                Text(d.text).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: (toMe || isCQ) ? .semibold : .regular).monospaced())
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if d.kind != .sent, let call = ft4.otherStation(d) {
                Button { ft4.work(d) } label: { Label("Work \(call)", systemImage: "arrowshape.turn.up.right") }
                Button { ft4.pounce(on: d) } label: { Label("Pounce on this station", systemImage: "scope") }
                if ft4.isBlocked(call) {
                    Button { ft4.unblock(call) } label: { Label("Allow auto-reply to \(call)", systemImage: "checkmark.circle") }
                } else {
                    Button(role: .destructive) { ft4.block(call) } label: {
                        Label("Block from auto-reply", systemImage: "hand.raised")
                    }
                }
            }
        }
    }

    /// The essentials, always visible: enable TX, auto-sequence, and the big Call CQ.
    private var txControlsPrimary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Transmit", isOn: $ft4.txEnabled).fixedSize()
                Toggle("Auto-seq", isOn: $ft4.autoSequence).fixedSize()
                Spacer()
            }
            Button {
                ft4.callCQ()
                if !ft4.isRunning { toggleRun() }
            } label: {
                Label("Call CQ", systemImage: "megaphone.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(qso.config.myCall.isEmpty)

            if qso.config.myCall.isEmpty {
                Text("Set your callsign in Log settings to transmit.")
                    .font(.caption2).foregroundStyle(ODTheme.warning)
            } else if !ft4.seqStatus.isEmpty && !(ft4.txEnabled && !ft4.txMessage.isEmpty) {
                // Show the sequence status here only when the Next-TX panel isn't up.
                Text(ft4.seqStatus).font(.caption).foregroundStyle(ODTheme.accent)
            }
            if gridMissing {
                Text("Your grid is missing — CQ and replies will go out without a locator. Set your station location in Settings.")
                    .font(.caption2).foregroundStyle(ODTheme.warning)
            }
            pounceControls
        }
    }

    /// The operator's locator can't go on the air (no valid 4-character grid) — either the
    /// station location yields none, or the running session started without one.
    private var gridMissing: Bool {
        !FT4Engine.isGrid(String(store.operatorGrid6.prefix(4))) || (ft4.isRunning && ft4.gridMissing)
    }

    /// Wait-and-pounce: a target field (calls and/or grids) plus an arm toggle.
    private var pounceControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Pounce on (call or grid)", text: $ft4.pounceTargets)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.odField)
                Toggle("Pounce", isOn: $ft4.pounceEnabled).fixedSize()
                    .disabled(ft4.pounceTokens.isEmpty || qso.config.myCall.isEmpty)
            }
            if ft4.pounceEnabled && !ft4.pounceTokens.isEmpty {
                Text("Waiting for \(ft4.pounceTokens.joined(separator: ", ")) — answers their CQ (or their call to you) automatically, once.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// Secondary transmit setup, shown inside the disclosure.
    private var txSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TX freq").font(.caption2).foregroundStyle(ODTheme.muted)
                Spacer()
                Text("\(Int(ft4.txAudioFreq)) Hz").font(.caption2.monospacedDigit())
                Button("Clear spot") { ft4.txAudioFreq = (ft4.suggestedTxFreq / 10).rounded() * 10 }
                    .font(.caption2).buttonStyle(.borderless).disabled(!ft4.isRunning)
            }
            FineSlider(value: $ft4.txAudioFreq, range: 300...2700, step: 10)

            Toggle("Doppler-correct TX audio", isOn: $ft4.audioDopplerTX)
                .font(.caption)
            Text("On by default. Chirps the transmitted audio to cancel uplink-Doppler drift so your signal stays put across the burst. While FT4 runs the CAT dial is frozen for the whole slot, so this within-burst correction is what keeps you from smearing — turning it off makes others see you drift. Needs a configured transponder.")
                .font(.caption2).foregroundStyle(ODTheme.muted)

            Toggle("Doppler-correct RX audio", isOn: $ft4.audioDopplerRX)
                .font(.caption)
            Text("On by default. Flattens the downlink-Doppler drift across each received slot before decoding — helps at high Doppler rate. While FT4 runs with a connected CAT radio, OrbitDeck holds the dial steady and only re-tunes at slot boundaries, so this removes the residual within-slot drift without double-correcting. Needs a configured transponder.")
                .font(.caption2).foregroundStyle(ODTheme.muted)

            if ft4.autoSequence {
                Text("Call CQ, or tap a decoded station to answer it — the exchange (grid → report → RR73) and logging run automatically; your report is set from their decoded SNR.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            } else {
                TextField("TX message (e.g. CQ N8HM FM18)", text: $messageDraft)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
                    .focused($messageFocused)
                    .submitLabel(.done)
                    .onSubmit { ft4.txMessage = messageDraft.trimmingCharacters(in: .whitespaces).uppercased() }
                    .onAppear { messageDraft = ft4.txMessage }
                    .onChange(of: ft4.txMessage) { _, new in if !messageFocused { messageDraft = new } }
                Toggle("Transmit on even slots", isOn: $ft4.txOnEvenSlots)
            }
            if !ft4.pttOverCAT {
                Text("No CAT PTT — use VOX or key manually when the TX indicator shows. Configure a CAT radio (CI-V / Yaesu / Kenwood / rigctld / Icom network) for automatic keying.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
            Divider().opacity(0.4)
            cqBlockListEditor
        }
    }

    /// Callsigns never auto-answered while calling CQ (tapping their decode still works them).
    private var cqBlockListEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CQ block list").font(.caption.weight(.semibold))
            Text("Stations here are never answered automatically while you call CQ. Tapping their decode still works them.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
            HStack(spacing: 8) {
                TextField("Add callsign", text: $newBlockedCall)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.odField)
                    .onSubmit(addBlockedCall)
                Button("Add", action: addBlockedCall)
                    .font(.caption).buttonStyle(.bordered)
                    .disabled(newBlockedCall.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(ft4.cqBlockList, id: \.self) { call in
                HStack {
                    Text(call).font(.caption.monospaced())
                    Spacer()
                    Button { ft4.unblock(call) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(ODTheme.warning)
                        .accessibilityLabel("Remove \(call) from the block list")
                }
            }
        }
    }

    private func addBlockedCall() {
        for token in FT4Engine.listTokens(newBlockedCall) { ft4.block(token) }
        newBlockedCall = ""
    }

    private func toggleRun() {
        if ft4.isRunning {
            ft4.stop()
            ft4.ownSignalCalibration = nil
            rig.setDigitalDataMode(false)     // restore the rig's plain SSB mode
        } else if let source = audio.makeSource(allowMicFallback: visibility == .always) {
            let transponder = rig.transponder(for: satellite)
            ft4.dopplerProvider = Self.makeDopplerProvider(satellite: satellite,
                                                           observer: store.preferences.observer,
                                                           transponder: transponder)
            // Which sideband the uplink is keyed in decides the TX Doppler-comp sign: an
            // inverting linear transponder flips the downlink sideband on the uplink (USB
            // down → LSB up), and in LSB the audio→RF mapping inverts. Mirror the CAT
            // engine's uplinkMode() so the pre-comp cancels drift instead of doubling it.
            let dlMode = transponder.map(RigMode.downlink(for:)) ?? .usb
            let ulMode = transponder.map { RigMode.uplink(for: $0, downlink: dlMode) } ?? dlMode
            ft4.uplinkAudioInverted = (ulMode == .lsb)
            // Absolute downlink RF base for PSKReporter spots: the Doppler-corrected
            // downlink dial from CAT when connected (already includes the per-satellite
            // calibration). Without CAT we can't read the dial, so fall back to the
            // transponder downlink center PLUS the operator's saved calibration for this
            // bird — matching what the CAT path reports, so audio-only spots are
            // calibration-aware too. (Doppler isn't added: on a fixed manual dial it's
            // already carried in each decode's audio offset.)
            let calHz = store.downlinkCalibrationHz(for: satellite.id, transponder: transponder?.id,
                                                    invert: transponder?.invert ?? false)
            let dlCenter = Double(transponder?.downlinkCenter ?? 0)
            let calibratedCenter = dlCenter > 0 ? dlCenter + calHz : 0
            ft4.rxBaseHzProvider = { [weak rig] in
                let dial = Double(rig?.downlinkDialHz ?? 0)
                return dial > 0 ? dial : calibratedCenter
            }
            // Automatic transponder calibration (opt-in): fold the error between our own
            // decoded FT4 signal and our TX audio frequency into the saved calibration for
            // THIS transponder (a learned downlink offset on top of the per-satellite value,
            // which is what a transponder without its own entry keeps using), damped and
            // clamped so a stray decode can't yank it. Only for a linear transponder — FM
            // birds don't need audio-domain calibration.
            if ft4AutoCal, let tp = transponder, tp.isLinear {
                let norad = satellite.id, tpID = tp.id
                ft4.ownSignalCalibration = { [weak store] errHz in
                    guard let store else { return }
                    let base = store.calibration(for: norad).downlinkHz
                    let extra = store.transponderCalibrationOffsetHz(for: norad, transponder: tpID) ?? 0
                    let step = max(-2000.0, min(2000.0, errHz)) * 0.4    // damped residual
                    // Clamp the EFFECTIVE downlink calibration to ±20 kHz, as before.
                    let total = max(-20_000, min(20_000, base + extra + step))
                    store.setTransponderCalibrationOffsetHz(total - base, for: norad, transponder: tpID)
                    ODLog.shared.log(String(format: "FT4 auto-cal: sat %u transponder %@ downlink cal → %+.0f Hz",
                                            norad, tpID, total), category: "ft4")
                }
            } else {
                ft4.ownSignalCalibration = nil
            }
            // Opt-in PSKReporter reporting (needs callsign + grid).
            if pskEnabled {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let reporter = PSKReporter(receiverCall: qso.config.myCall,
                                           receiverGrid: store.operatorGrid6,
                                           software: "OrbitDeck \(version)",
                                           antenna: satellite.name)
                ft4.pskReporter = reporter.isConfigured ? reporter : nil
            } else {
                ft4.pskReporter = nil
            }
            // Command the data sub-mode (USB-D/LSB-D) so audio uses the rig's data port,
            // unless the operator opted out (feeding audio via mic/headphone instead). Only
            // engaged when FT4 is started — the radio stays in plain USB/LSB for voice QSOs
            // beforehand — and cleared again on stop. Once set, the flag persists for the FT4
            // session, so a mid-pass RS-BA1 drop/reconnect re-applies it; but it never turns
            // DATA on outside an active FT4 session.
            ODLog.shared.log("FT4 start: data-mode pref=\(ft4DataMode) rigConnected=\(rig.connected)", category: "ft4")
            rig.setDigitalDataMode(rig.connected && ft4DataMode)
            ft4.start(source: source, myCall: qso.config.myCall, myGrid: store.operatorGrid6, satellite: satellite.name)
        } else {
            ft4.errorText = "No audio interface available."
        }
    }

    /// Ephemeris-backed instantaneous downlink/uplink Doppler shift (Hz) for the card's
    /// readout and the (experimental) TX pre-compensation. Uses the transponder centers;
    /// the ~1e-4 error from using center vs edge frequency is negligible.
    private static func makeDopplerProvider(satellite: SatelliteRecord, observer: ObserverSite,
                                            transponder: TransponderRecord?) -> (@Sendable (Date) -> (dl: Double, ul: Double)?)? {
        guard let tp = transponder, tp.downlinkCenter > 0 else { return nil }
        let dl = Double(tp.downlinkCenter), ul = Double(max(0, tp.uplinkCenter))
        return { date in
            guard let look = try? OrbitPredictor.look(satellite, observer: observer, at: date) else { return nil }
            let v = look.rangeRateKmS * 1000.0          // m/s, positive = receding
            let c = 299_792_458.0
            return (dl: -dl * v / c, ul: -ul * v / c)
        }
    }
}

// ###########################################################################
//  PACKET / APRS (Home card)
//
//  Kept in this file (rather than its own) because new source files have to be
//  added to the Xcode target by hand; this file is already in the target.
// ###########################################################################

// ===========================================================================
//  PacketViews.swift — Home "Packet / APRS" card (monitor + compose + setup)
// ===========================================================================

import MapKit

struct HomePacketCard: View {
    @EnvironmentObject private var packet: PacketEngine
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var store: OrbitStore
    @AppStorage(FeatureVisibility.packetKey) private var visibility = FeatureVisibility.auto
    @State private var showSetup = false
    @State private var pickingAdapter = false
    @State private var messageTo = "CQ"
    @State private var messageText = ""
    @State private var tab = 0
    @State private var showSessions = false
    @State private var horizonEvent: NextEvent?
    /// AOS of the pass in progress (kept after LOS), for the map's "This pass" filter.
    @State private var passStart: Date?
    @State private var mapAllStations = false
    let satellite: SatelliteRecord

    /// Auto: show when this satellite has a packet transponder and there's a way to
    /// reach a radio (audio interface or a chosen KISS adapter), or while running.
    private var visible: Bool {
        switch visibility {
        case .off: return false
        case .always: return true
        case .auto:
            if packet.isRunning { return true }
            let hasPacket = satellite.transponders.contains { tp in
                let h = "\(tp.mode) \(tp.description)".uppercased()
                return ["APRS", "AFSK", "PACKET", "DIGI", "G3RUH"].contains { h.contains($0) }
            }
            let reachable = audio.audioAvailable
                || (packet.settings.transport == .bleKISS && !packet.settings.bleIdentifier.isEmpty)
                || (packet.settings.transport == .tcpKISS && !packet.settings.kissHost.isEmpty)
            return hasPacket && reachable
        }
    }

    private var profile: Binding<PacketSatelliteProfile> {
        Binding(get: { packet.profile(for: satellite.id) }, set: { packet.setProfile($0, for: satellite.id) })
    }

    var body: some View {
        if visible {
            SectionCard("Packet / APRS") {
                AudioHealthBanner(active: packet.isRunning && packet.settings.transport == .builtInModem)
                if !packet.errorText.isEmpty {
                    Text(packet.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(packet.isTransmitting ? ODTheme.warning : (packet.isRunning ? ODTheme.good : ODTheme.muted))
                        .frame(width: 10, height: 10)
                    Text(packet.status).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    Button(packet.isRunning ? "Stop" : "Start") {
                        if packet.isRunning { packet.stop() } else { packet.start(satellite: satellite) }
                    }
                    .buttonStyle(.bordered)
                }
                infoLine
                profileRow

                if packet.isRunning {
                    if packet.settings.transport == .builtInModem {
                        AudioLevelControl(title: "RX level", gain: Binding(
                            get: { packet.settings.inputGain },
                            set: { packet.settings.inputGain = $0 }), level: packet.rxLevel)
                    }
                    statsLine
                    quickMessages
                    compose
                    Picker("View", selection: $tab) {
                        Text("Monitor").tag(0)
                        Text("Stations (\(packet.heard.count))").tag(1)
                        Text("Map").tag(2)
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case 0: monitor
                    case 1: stations
                    default: stationMap
                    }
                }

                Button { showSessions = true } label: {
                    Label("Pass log", systemImage: "list.bullet.rectangle")
                }
                .font(.caption).buttonStyle(.borderless)

                DisclosureGroup("Setup", isExpanded: $showSetup) { setup.padding(.top, 4) }
                    .font(.subheadline).tint(ODTheme.accent)
            }
            .task(id: satellite.id) {
                passStart = nil
                await packet.tuneBBLink(for: satellite)
            }
            // AOS/LOS for the horizon line, refreshed each minute.
            .task(id: "\(satellite.id)-\(Int(Date().timeIntervalSince1970 / 60))") {
                let sat = satellite, observer = store.preferences.observer
                horizonEvent = await Task.detached(priority: .utility) {
                    try? OrbitPredictor.nextEvent(sat, observer: observer, horizonDays: 2)
                }.value
                if horizonEvent?.isVisible == true {
                    let pass = await Task.detached(priority: .utility) {
                        try? OrbitPredictor.currentOrNextPass(sat, observer: observer, horizonDays: 1)
                    }.value
                    if let pass, pass.aos <= Date() { passStart = pass.aos }
                }
            }
            .sheet(isPresented: $showSessions) {
                NavigationStack { PacketSessionsView() }
            }
            .sheet(isPresented: $pickingAdapter) {
                NavigationStack {
                    BLEPickerView(selectedID: packet.settings.bleIdentifier) { dev in
                        packet.settings.bleIdentifier = dev.id.uuidString
                        packet.settings.bleName = dev.name
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private var infoLine: some View {
        let tp = packet.packetTransponder(for: satellite)
        var parts: [String] = []
        if let me = packet.myAddress { parts.append(me.description) }
        if let tp { parts.append(ODFormat.frequency(tp.downlinkCenter)) }
        parts.append(packet.isFullDuplex(for: satellite) ? "full duplex" : "half duplex")
        return VStack(alignment: .leading, spacing: 2) {
            Text(parts.joined(separator: " · ")).font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
            TimelineView(.periodic(from: .now, by: 10)) { context in
                if let ev = horizonEvent {
                    let mins = max(0, Int(ev.date.timeIntervalSince(context.date) / 60))
                    if ev.isVisible {
                        Label("\(satellite.name) is up · LOS in \(mins) min", systemImage: "dot.radiowaves.up.forward")
                            .font(.caption).foregroundStyle(ODTheme.good)
                    } else {
                        Label("Below the horizon · AOS \(ODFormat.primaryClock(ev.date)) (in \(mins) min)"
                              + (packet.settings.blockBelowHorizon ? " — sending is blocked until then" : ""),
                              systemImage: "moon.zzz")
                            .font(.caption).foregroundStyle(ODTheme.warning)
                    }
                }
            }
            HStack(spacing: 8) {
                if packet.channelBusy { Label("Channel busy", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(ODTheme.warning) }
                if packet.heardSelfViaSatellite { Label("Heard yourself via the satellite", systemImage: "checkmark.seal.fill").foregroundStyle(ODTheme.good) }
            }
            .font(.caption)
            if let logged = packet.lastAutoLogged {
                Label("Logged \(logged.call) at \(ODFormat.primaryClock(logged.date))", systemImage: "book.closed.fill")
                    .font(.caption).foregroundStyle(ODTheme.good)
            }
            let minEl = packet.minElevation(for: satellite.id)
            if minEl > 0 {
                Text("Sending and beacons only above \(Int(minEl))° elevation.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
            if packet.isRunning && packet.settings.satgateEnabled { PacketSatgateStatus(satgate: packet.satgate) }
        }
    }

    /// Per-satellite format, path and modem (ISS: APRS via ARISS, 1200 AFSK).
    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Format", selection: profile.format) {
                ForEach(PacketMessageFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if packet.settings.transport == .builtInModem {
                HStack {
                    Text("Modem").font(.caption).foregroundStyle(ODTheme.muted)
                    Picker("Modem", selection: profile.modem) {
                        ForEach(PacketModem.allCases) { m in
                            Text(m == .automatic ? "Auto (\(autoModemLabel))" : m.label).tag(m)
                        }
                    }
                    // `.font` doesn't shrink a menu picker; size the control to match the caption label.
                    .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    .disabled(packet.isRunning)
                    Spacer(minLength: 0)
                }
                if packet.modem(for: satellite) == .g3ruh9600 {
                    Text("9600 baud needs the radio's 9600 data port (flat, wide discriminator audio and direct modulator input), with the receiver on the wide FM filter. Speaker and mic audio are too filtered to decode or send it.")
                        .font(.caption2).foregroundStyle(ODTheme.warning)
                }
            }
            HStack {
                Text("Minimum elevation").font(.caption).foregroundStyle(ODTheme.muted)
                Picker("Minimum elevation", selection: profile.minElevationDeg) {
                    Text("Global (\(Int(packet.settings.minElevationDeg))°)").tag(Double?.none)
                    ForEach([0.0, 5, 10, 15, 20, 30], id: \.self) { Text("\(Int($0))°").tag(Double?.some($0)) }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                Spacer(minLength: 0)
            }
            HStack {
                Text("Path").font(.caption).foregroundStyle(ODTheme.muted)
                TextField("ARISS", text: profile.path)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.odField)
                Menu("Presets") {
                    ForEach(["ARISS", "APRSAT", "WIDE2-1", "ARISS,WIDE2-1", ""], id: \.self) { p in
                        Button(p.isEmpty ? "Direct (no path)" : p) { profile.wrappedValue.path = p }
                    }
                }
                .font(.caption)
            }
            Text(profile.wrappedValue.format == .plainText
                 ? "UISS-style unproto text: the To call is the AX.25 destination (CQ by default) and your text is sent as is — e.g. \(packet.myAddress?.description ?? "N0CALL")>CQ,\(profile.wrappedValue.path.isEmpty ? "…" : profile.wrappedValue.path):CQ \(String(store.operatorGrid6.prefix(4)))."
                 : "APRS: To CQ (or blank) sends a status; a callsign sends an APRS message\(packet.settings.requestAcks ? " (numbered, for acks)" : "").")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    private var statsLine: some View {
        let s = packet.stats
        let pct = s.sent > 0 ? Int((Double(s.digipeated) / Double(s.sent) * 100).rounded()) : 0
        return VStack(alignment: .leading, spacing: 2) {
            Text("Sent \(s.sent) · digipeated \(s.digipeated) (\(pct)%)" + (s.digipeated > 0 ? String(format: " · median delay %.1f s", s.medianDelay) : ""))
            if let session = packet.currentSession {
                let st = session.stats
                Text("This pass: \(st.framesHeard) frames · \(st.stationsHeard) stations · " + String(format: "%.1f/min", st.framesPerMinute))
            }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
    }

    private var quickMessages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(packet.settings.macros.enumerated()), id: \.offset) { _, macro in
                    Button {
                        runMacro(macro)
                    } label: {
                        Text(macroLabel(macro)).font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .disabled(packet.isTransmitting)
                }
            }
        }
    }

    private func macroLabel(_ macro: String) -> String {
        if macro == "{POSITION}" { return "Position" }
        if macro == "{HEARD}" { return "Heard list" }
        return packet.expand(macro, to: messageTo.isEmpty ? "CALL" : messageTo)
    }

    private func runMacro(_ macro: String) {
        if macro.trimmingCharacters(in: .whitespaces) == "{POSITION}" { packet.sendPosition(); return }
        let text = packet.expand(macro, to: messageTo)
        // A CQ macro always goes to CQ.
        let to = PacketText.isCQ(text) ? "CQ" : messageTo
        packet.sendText(text, to: to)
    }

    private var compose: some View {
        HStack {
            TextField("To", text: $messageTo)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .textFieldStyle(.odField).frame(width: 96)
            TextField("Message", text: $messageText)
                .textFieldStyle(.odField)
                .onSubmit(sendMessage)
            Button("Send", action: sendMessage)
                .buttonStyle(.borderedProminent)
                .disabled(messageText.isEmpty || packet.isTransmitting)
        }
    }

    private func sendMessage() {
        packet.sendText(messageText, to: messageTo)
        messageText = ""
    }

    private var monitor: some View {
        let filter = packet.settings.monitorFilter
        let entries = packet.log.filter(filter.matches)
        return VStack(alignment: .leading, spacing: 6) {
            PacketFilterBar(filter: $packet.settings.monitorFilter, canClear: !packet.log.isEmpty) { packet.clearLog() }
            if entries.isEmpty {
                Text(filter.activeCount > 0 ? "Nothing matches the filter." : "No packets yet. Frames heard on the downlink appear here.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } else {
                ForEach(entries.suffix(30).reversed()) { entry in
                    PacketLogRow(entry: entry, raw: filter.showRaw) { call in messageTo = call }
                }
            }
        }
    }

    private var stations: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tap Reply to address a station, Log to add the contact (mode PKT).")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
                Spacer()
                if !packet.heard.isEmpty { Button("Clear") { packet.clearHeard() }.font(.caption).buttonStyle(.borderless) }
            }
            if packet.heard.isEmpty {
                Text("No stations heard yet.").font(.caption).foregroundStyle(ODTheme.muted)
            }
            ForEach(packet.heard) { station in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    APRSSymbolBadge(table: station.symbolTable, code: station.symbolCode, size: 22)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(station.call).font(.subheadline.weight(.semibold))
                            if station.cqs > 0 { Text("CQ").font(.caption2.weight(.bold)).foregroundStyle(ODTheme.good) }
                            if station.viaDigipeater { Image(systemName: "dot.radiowaves.up.forward").font(.caption2).foregroundStyle(.cyan) }
                            if station.logged { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(ODTheme.good) }
                        }
                        Text(stationDetail(station)).font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                    }
                    Spacer()
                    Button("Reply") { messageTo = station.call }.font(.caption).buttonStyle(.bordered).controlSize(.small)
                    Button("Log") { packet.logQSO(with: station.call) }.font(.caption).buttonStyle(.bordered).controlSize(.small)
                        .disabled(station.logged)
                }
            }
        }
    }

    /// Heard stations with a position on a map, filtered to this pass or all; tap a
    /// station to address it.
    private var stationMap: some View {
        let since = passStart ?? Date().addingTimeInterval(-20 * 60)
        let shown = packet.heard.filter { $0.latitude != nil && (mapAllStations || $0.lastHeard >= since) }
        let unplaced = packet.heard.filter { $0.latitude == nil }.count
        let objects = packet.objects.filter { mapAllStations || $0.lastHeard >= since }
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Stations", selection: $mapAllStations) {
                Text("This pass").tag(false)
                Text("All heard").tag(true)
            }
            .pickerStyle(.segmented)
            PacketStationMap(stations: shown, objects: objects, observer: store.preferences.observer, satellite: satellite,
                             myTable: packet.settings.symbolTable.first, myCode: packet.settings.symbolCode.first) { call in
                messageTo = call
            }
            Text("\(shown.count) on the map" + (objects.isEmpty ? "" : " · \(objects.count) objects/items")
                 + (unplaced > 0 ? " · \(unplaced) without a position" : "")
                 + ". Tap a station to put its call in To. The shaded area is \(satellite.name)'s footprint.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    private var autoModemLabel: String { packet.autoModem(for: satellite) == .g3ruh9600 ? "9600" : "1200" }

    private func stationDetail(_ s: PacketHeardStation) -> String {
        var parts: [String] = []
        if let g = s.grid { parts.append(String(g.prefix(6))) }
        if let lat = s.latitude, let lon = s.longitude {
            let o = store.preferences.observer
            let (km, brg) = Self.distanceBearing(o.latitude, o.longitude, lat, lon)
            parts.append("\(ODFormat.km(km, decimals: 0)) \(ODFormat.compass(brg))")
        }
        parts.append("\(s.frames)×")
        parts.append(ODFormat.axisClock(s.lastHeard))
        if let wx = s.weather, !wx.summary.isEmpty { parts.append(wx.summary) }
        return parts.joined(separator: " · ")
    }

    static func distanceBearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> (Double, Double) {
        let r = Double.pi / 180
        let p1 = lat1 * r, p2 = lat2 * r, dl = (lon2 - lon1) * r
        let a = sin((p2 - p1) / 2) * sin((p2 - p1) / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        let km = 6371.0 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let brg = (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
        return (km, brg)
    }

    @ViewBuilder private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Connection", selection: $packet.settings.transport) {
                ForEach(PacketSettings.Transport.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(packet.isRunning)

            if packet.settings.transport == .bleKISS {
                Button { pickingAdapter = true } label: {
                    HStack {
                        Text("KISS adapter")
                        Spacer()
                        Text(packet.settings.bleName.isEmpty ? "Choose…" : packet.settings.bleName).foregroundStyle(ODTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(packet.isRunning)
                Toggle("Tune the radio to the packet frequency (B.B. Link)", isOn: $packet.settings.bbLinkTune)
                Text("Uses the radio's built-in TNC through a BLE KISS adapter. The Kenwood TH-D74/D75 only offer Bluetooth Classic, which iOS can't open, so they need the B.B. Link adapter (or a compatible ESP32/Raspberry Pi bridge). Set the radio's KISS interface to Bluetooth (menu 983). The adapter accepts one app at a time, so CAT control over the same adapter isn't available while packet runs.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } else if packet.settings.transport == .tcpKISS {
                HStack {
                    TextField("Host (e.g. 192.168.1.20)", text: $packet.settings.kissHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .textFieldStyle(.odField)
                    TextField("Port", value: $packet.settings.kissPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad).textFieldStyle(.odField).frame(width: 70)
                }
                .disabled(packet.isRunning)
                Text("KISS over TCP to Direwolf (port 8001), UZ7HO soundmodem (8100) or a network TNC on your LAN. That software runs the modem and keys the radio; OrbitDeck sends and receives frames as with the BLE TNC, and reconnects if the link drops.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } else {
                Stepper("TX delay: \(packet.settings.txDelayMs) ms", value: $packet.settings.txDelayMs, in: 50...1000, step: 50)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("TX audio level").font(.caption2.weight(.semibold)).foregroundStyle(ODTheme.muted)
                        Spacer()
                        Text(String(format: "%.0f%%", packet.settings.outputLevel * 100)).font(.caption2.monospacedDigit())
                    }
                    FineSlider(value: $packet.settings.outputLevel, range: 0.05...1, step: 0.05)
                }
                Button { packet.sendTestTone() } label: { Label("Send 3 s test signal", systemImage: "waveform") }
                    .buttonStyle(.bordered)
                    .disabled(!packet.isRunning || packet.isTransmitting)
                Toggle("Off-frequency decoders (±175/±350 Hz, 1200 only)", isOn: $packet.settings.offsetDecoders)
                    .disabled(packet.isRunning)
                Toggle("Put the radio in data mode (CAT)", isOn: $packet.settings.useDataMode)
                    .disabled(packet.isRunning)
                Text("1200-baud AFSK or 9600-baud G3RUH (chosen per satellite above) through your audio interface. OrbitDeck keys the radio over CAT when it can, otherwise use VOX. With CAT connected it also selects the radio's data mode (e.g. FM-D) while packet runs, so audio uses the data port; turn that off if you feed the mic jack. Set about 3 kHz deviation: send the test signal into a dummy load, start low and raise the level until the digipeated copy decodes. 9600 needs the 9600 data port and a receive path flat down to about 50 Hz. Off-frequency decoders catch 1200-baud stations slightly off frequency (residual Doppler); the 9600 decoder tracks the offset itself.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Group {
                Stepper("SSID: -\(packet.settings.ssid)", value: $packet.settings.ssid, in: 0...15)
                Picker("Position precision", selection: $packet.settings.positionPrecision) {
                    ForEach(PacketPositionPrecision.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Position comment")
                    Spacer()
                    TextField("{MYGRID4} via OrbitDeck", text: $packet.settings.beaconComment)
                        .multilineTextAlignment(.trailing).textFieldStyle(.odField).frame(minWidth: 120, maxWidth: 190)
                }
                Stepper(packet.settings.beaconMinutes == 0 ? "Timed beacon: off" : "Timed beacon: every \(packet.settings.beaconMinutes) min",
                        value: $packet.settings.beaconMinutes, in: 0...30)
                Picker("Beacon sends", selection: $packet.settings.beaconContent) {
                    ForEach(PacketBeaconContent.allCases) { Text($0.label).tag($0) }
                }
                if packet.settings.beaconContent != .position {
                    HStack {
                        Text("Status text")
                        Spacer()
                        TextField("OrbitDeck {MYGRID4}", text: $packet.settings.statusText)
                            .multilineTextAlignment(.trailing).textFieldStyle(.odField).frame(minWidth: 120, maxWidth: 190)
                    }
                }
                Toggle("Beacon when the satellite is first heard", isOn: $packet.settings.beaconOnFirstHeard)
                Text("Sends one position as soon as the first digipeated frame of a pass arrives, then the timed beacon continues. Status text goes out as an APRS status (>) or as plain text to CQ, following the satellite's format. Automatic beacons are never closer than 1 minute apart.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
                Toggle("Number my messages (request acks)", isOn: $packet.settings.requestAcks)
                if packet.settings.requestAcks {
                    Toggle("Resend unacknowledged messages (2×, 30 s apart)", isOn: $packet.settings.retryMessages)
                }
                Toggle("Acknowledge messages to me", isOn: $packet.settings.autoAck)
                Toggle("Log QSOs automatically", isOn: $packet.settings.autoLogQSOs)
                Text("Logs a PKT QSO once you and a station have each sent the other's call, and its reply came after yours or yours was heard back through the satellite. Grid and reports come from the frames. A station already logged on this satellite in the last 30 minutes isn't logged again.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
                Toggle("Block sending below the minimum elevation", isOn: $packet.settings.blockBelowHorizon)
                Stepper("Minimum elevation: \(Int(packet.settings.minElevationDeg))°", value: $packet.settings.minElevationDeg, in: 0...45, step: 1)
                Text("Applies to sending, beacons and message retries; a satellite's profile can override it.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
            PacketAlertsSetup()
            PacketSatgateSetup()
            Group {
                Picker("Duplex", selection: $packet.settings.duplex) {
                    ForEach(PacketDuplex.allCases) { Text($0.label).tag($0) }
                }
                Stepper("PTT watchdog: \(packet.settings.pttWatchdogSeconds) s", value: $packet.settings.pttWatchdogSeconds, in: 1...60)
                Stepper("Persistence: \(packet.settings.persistence)", value: $packet.settings.persistence, in: 0...255, step: 16)
                Stepper("Slot time: \(packet.settings.slotTimeMs) ms", value: $packet.settings.slotTimeMs, in: 10...500, step: 10)
                Stepper("Max wait for a clear channel: \(packet.settings.maxChannelWaitSeconds) s", value: $packet.settings.maxChannelWaitSeconds, in: 1...30)
            }
            macroEditor
            Text("Satellite digipeaters (ISS and most amateur birds) answer the path ARISS. Keep transmissions short and infrequent — the channel is shared by everyone in the footprint (a 1-minute beacon is the accepted minimum). Automatic duplex is full duplex only on a crossband transponder, where you can hear your own downlink; half duplex waits for a clear channel and ignores your own echo.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    private var macroEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quick messages").font(.caption.weight(.semibold))
                Spacer()
                Button("Reset") { packet.settings.macros = PacketSettings.defaultMacros }.font(.caption).buttonStyle(.borderless)
                Button { packet.settings.macros.append("") } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(packet.settings.macros.count >= 12)
            }
            ForEach(packet.settings.macros.indices, id: \.self) { i in
                HStack {
                    TextField("Macro", text: Binding(
                        get: { i < packet.settings.macros.count ? packet.settings.macros[i] : "" },
                        set: { if i < packet.settings.macros.count { packet.settings.macros[i] = $0 } }))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .textFieldStyle(.odField).font(.caption.monospaced())
                    Button { packet.settings.macros.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(ODTheme.warning)
                }
            }
            Text("Placeholders: {MYCALL} {MYGRID} {MYGRID4} {CALL} (the To field) {HEARD} (calls heard this pass — UISS's MHeard). A macro of just {POSITION} sends your position. A macro starting with CQ always goes to CQ.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }
}

private struct PacketLogRow: View {
    let entry: PacketLogEntry
    var raw = false
    let reply: (String) -> Void

    private var color: Color {
        if entry.direction == .sent { return .orange }
        if entry.ownDigipeated { return .cyan }
        if entry.toMe { return ODTheme.good }
        if entry.isTelemetry { return ODTheme.muted }
        return .primary
    }

    private var tag: String? {
        if entry.direction == .sent { return "TX" }
        if entry.ownDigipeated { return "MY DIGI" }
        if entry.toMe { return "TO ME" }
        if entry.isTelemetry { return "TLM" }
        if entry.isCQ { return "CQ" }
        switch entry.aprs.kind {
        case .object: return "OBJ"
        case .item: return "ITEM"
        case .weather: return "WX"
        default: break
        }
        if entry.aprs.weather != nil { return "WX" }
        if entry.isStatus { return "STS" }
        if entry.isBeacon { return "BCN" }
        return nil
    }

    /// "via RS0ISS*, WIDE2-1": `*` on the digipeater that repeated it; satellite
    /// digipeaters in cyan.
    private var pathLine: Text? {
        let path = entry.frame.pathText
        guard !path.isEmpty else { return nil }
        var t = Text("via ").foregroundStyle(ODTheme.muted)
        for (i, element) in path.enumerated() {
            if i > 0 { t = t + Text(", ").foregroundStyle(ODTheme.muted) }
            let sat = PacketDigis.isSatellite(element)
            let repeated = element.hasSuffix("*")
            t = t + Text(element)
                .foregroundStyle(sat ? Color.cyan : (repeated ? Color.primary : ODTheme.muted))
                .fontWeight(repeated || sat ? .semibold : .regular)
        }
        return t
    }

    private var retryText: (String, Color)? {
        if entry.acked { return nil }
        if entry.ackFailed { return ("no ack", ODTheme.warning) }
        if entry.retries > 0 { return ("retry \(entry.retries)/\(PacketMessageRetry.maxRetries)", ODTheme.warning) }
        if entry.awaitingAck { return ("awaiting ack", ODTheme.muted) }
        return nil
    }

    var body: some View {
        Button { reply(entry.frame.source.description) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ODFormat.axisClock(entry.date)).font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                    Text(entry.frame.source.description).font(.caption.weight(.semibold)).layoutPriority(1)
                    Text("→ \(entry.aprs.kind == .message || entry.aprs.kind == .ack ? entry.aprs.addressee : entry.frame.destination.description)")
                        .font(.caption2).foregroundStyle(ODTheme.muted).truncationMode(.tail)
                    if let tag { Text(tag).font(.caption2.weight(.bold)).foregroundStyle(color) }
                    if let d = entry.digipeatDelay { Text(String(format: "+%.1f s", d)).font(.caption2.monospacedDigit()).foregroundStyle(.cyan) }
                    if entry.acked { Text("acked").font(.caption2).foregroundStyle(ODTheme.good) }
                    if let r = retryText { Text(r.0).font(.caption2).foregroundStyle(r.1) }
                    Spacer()
                    if let lat = entry.aprs.latitude, let lon = entry.aprs.longitude {
                        Text(FeatureEngine.latLonToGrid6(latitude: lat, longitude: lon).prefix(4))
                            .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.accent)
                    } else if let g = PacketText.grid(in: entry.text) {
                        Text(g.prefix(4)).font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.accent)
                    }
                }
                // One line: on a narrow phone the tags would otherwise wrap letter by letter.
                .lineLimit(1)
                if raw {
                    Text(entry.frame.monitorText)
                        .font(.caption2.monospaced()).foregroundStyle(color).lineLimit(4)
                        .textSelection(.enabled)
                } else {
                    if let pathLine { pathLine.font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle) }
                    Text(entry.text.isEmpty ? entry.frame.monitorText : entry.text)
                        .font(.caption.monospaced()).foregroundStyle(color).lineLimit(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Monitor filter

/// Compact monitor filters for a phone: call and text fields plus a menu of toggles.
private struct PacketFilterBar: View {
    @Binding var filter: PacketMonitorFilter
    let canClear: Bool
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("Call", text: $filter.call)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .textFieldStyle(.odField).font(.caption).frame(width: 74)
            TextField("Text", text: $filter.text)
                .autocorrectionDisabled()
                .textFieldStyle(.odField).font(.caption)
            Menu {
                Toggle("Only my traffic", isOn: $filter.onlyMine)
                Toggle("Digipeated only", isOn: $filter.digipeatedOnly)
                Toggle("Hide beacons", isOn: $filter.hideBeacons)
                Toggle("Hide telemetry", isOn: $filter.hideTelemetry)
                Toggle("Hide status", isOn: $filter.hideStatus)
                Divider()
                Toggle("Raw TNC2", isOn: $filter.showRaw)
                if filter.activeCount > 0 {
                    Button("Reset filters", role: .destructive) {
                        let raw = filter.showRaw
                        filter = PacketMonitorFilter()
                        filter.showRaw = raw
                    }
                }
            } label: {
                let n = filter.activeCount
                Label(n > 0 ? "\(n)" : "Filter", systemImage: n > 0 ? "line.3.horizontal.decrease.circle.fill"
                                                                    : "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .accessibilityLabel("Monitor filters")
            if canClear { Button("Clear", action: clear).font(.caption).buttonStyle(.borderless) }
        }
    }
}

// MARK: - Alerts, speech and satgate setup

private struct PacketAlertsSetup: View {
    @EnvironmentObject private var packet: PacketEngine
    @State private var watchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alerts").font(.caption.weight(.semibold))
            Toggle("A message to me", isOn: alertBinding(\.alertToMe))
            Toggle("A watched callsign or word", isOn: alertBinding(\.alertWatch))
            if packet.settings.alertWatch {
                TextField("Watch list, e.g. W1AW, RS0ISS, field day", text: $watchText)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.odField).font(.caption)
                    .onAppear { watchText = packet.settings.watchList.joined(separator: ", ") }
                    .onChange(of: watchText) { _, v in packet.settings.watchList = PacketWatch.parseList(v) }
            }
            Toggle("My frame was digipeated", isOn: alertBinding(\.alertDigipeated))
            Text("A haptic and a sound while OrbitDeck is open, a notification when it's in the background. The same alert repeats at most once a minute. The sound is skipped when the phone's audio output feeds your radio (USB interface or phone mic), so it can't be transmitted.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
            Toggle("Read messages to me aloud", isOn: $packet.settings.speakMessages)
            Toggle("Also read bulletins", isOn: $packet.settings.speakBulletins)
            Text("Spoken only when the phone's output isn't the radio's audio path — a KISS TNC, or the built-in modem on Icom network audio — and never while transmitting.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    /// Turning an alert on asks for notification permission (once; iOS remembers).
    private func alertBinding(_ key: WritableKeyPath<PacketSettings, Bool>) -> Binding<Bool> {
        Binding(get: { packet.settings[keyPath: key] }, set: { on in
            packet.settings[keyPath: key] = on
            if on { packet.requestAlertPermission() }
        })
    }
}

private struct PacketSatgateSetup: View {
    @EnvironmentObject private var packet: PacketEngine
    @State private var passcode = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Satgate: forward heard packets to APRS-IS", isOn: $packet.settings.satgateEnabled)
            if packet.settings.satgateEnabled {
                HStack {
                    Text("Passcode")
                    Spacer()
                    SecureField("APRS-IS passcode", text: $passcode)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .textFieldStyle(.odField).frame(maxWidth: 140)
                }
                HStack {
                    TextField(APRSISGate.defaultHost, text: $packet.settings.satgateHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .textFieldStyle(.odField)
                    TextField("Port", value: $packet.settings.satgatePort, format: .number.grouping(.never))
                        .keyboardType(.numberPad).textFieldStyle(.odField).frame(width: 70)
                }
                Stepper(packet.settings.satgateSSID == 0 ? "Login: \(packet.satgateCall) (no SSID)" : "Login: \(packet.satgateCall)",
                        value: $packet.settings.satgateSSID, in: 0...15)
                if packet.isRunning {
                    HStack {
                        PacketSatgateStatus(satgate: packet.satgate)
                        Spacer(minLength: 4)
                        Button("Reconnect") { packet.restartSatgate() }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Text("Receive-only: packets heard through the satellite are sent to APRS-IS (aprs.fi and others) with your callsign as the gateway (qAR). Your own frames, duplicates within 30 s and packets marked NOGATE, RFONLY or TCPIP aren't gated, and nothing from the Internet is ever transmitted. Runs only while packet runs (in the foreground, or in the background with audio). Off by default; the passcode stays in the Keychain.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
        .task {
            if !loaded { passcode = OrbitSecretStore.get(.aprsisPasscode); loaded = true }
        }
        .onChange(of: passcode) { _, v in
            guard loaded else { return }
            // Saved as typed; used at the next connect (Start, or Reconnect) so partial
            // passcodes never reach the server.
            OrbitSecretStore.set(v.trimmingCharacters(in: .whitespaces), for: .aprsisPasscode)
        }
    }
}

private struct PacketSatgateStatus: View {
    @ObservedObject var satgate: PacketSatgate

    var body: some View {
        let verifiedText: String = switch satgate.verified {
        case .some(true): " · verified"
        case .some(false): " · unverified — check the passcode"
        case .none: ""
        }
        HStack(spacing: 6) {
            Circle().fill(satgate.verified == false ? ODTheme.warning : satgate.state.color).frame(width: 8, height: 8)
            Text("Satgate: \(satgate.state.label)\(verifiedText) · \(satgate.gatedCount) gated")
                .lineLimit(2).minimumScaleFactor(0.8)
        }
        .font(.caption)
        .foregroundStyle(ODTheme.muted)
    }
}

// MARK: - Pass log

/// Saved packet sessions (one per pass), newest first.
private struct PacketSessionsView: View {
    @EnvironmentObject private var packet: PacketEngine
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [PacketSession] = []
    @State private var loading = true

    var body: some View {
        List {
            if sessions.isEmpty && !loading {
                Text("No passes logged yet. Every frame heard or sent while packet runs is saved here, one session per pass (the last \(PacketSessionFiles.keep) are kept).")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            ForEach(sessions) { s in
                NavigationLink {
                    PacketSessionDetailView(session: s)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.satellite.isEmpty ? "No satellite" : s.satellite).font(.subheadline.weight(.semibold))
                            if s.id == packet.currentSession?.id {
                                Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(ODTheme.good)
                            }
                            Spacer()
                            Text(PacketSessionExport.utc(s.start)).font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                        }
                        let st = s.stats
                        Text("\(st.framesHeard) heard · \(st.stationsHeard) stations · sent \(st.sent)"
                             + (st.successPercent.map { " · \($0) % digipeated" } ?? ""))
                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { packet.deleteSession(sessions[i].id) }
                sessions.remove(atOffsets: offsets)
            }
        }
        .navigationTitle("Pass log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            sessions = await packet.loadSessions()
            loading = false
        }
    }
}

private struct PacketSessionDetailView: View {
    let session: PacketSession
    @State private var files: (text: URL, csv: URL)?

    var body: some View {
        let st = session.stats
        List {
            Section("Statistics") {
                LabeledContent("Frames heard", value: "\(st.framesHeard)")
                LabeledContent("Stations heard", value: "\(st.stationsHeard)")
                LabeledContent("My frames sent", value: "\(st.sent)")
                LabeledContent("Digipeated", value: "\(st.digipeated)" + (st.successPercent.map { " (\($0) %)" } ?? ""))
                if let d = st.medianDelay { LabeledContent("Median digipeat delay", value: String(format: "%.1f s", d)) }
                LabeledContent("Frames per minute", value: String(format: "%.1f", st.framesPerMinute))
                LabeledContent("Time (UTC)", value: "\(PacketSessionExport.utc(session.start)) – \(PacketSessionExport.utc(session.end).suffix(9))")
            }
            Section("Export") {
                if let files {
                    ShareLink(item: files.text) { Label("Text (TNC2)", systemImage: "doc.plaintext") }
                    ShareLink(item: files.csv) { Label("CSV", systemImage: "tablecells") }
                } else {
                    ProgressView()
                }
            }
            Section("Frames (\(session.records.count))") {
                ForEach(session.records.suffix(500).reversed()) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(ODFormat.axisClock(r.date)).foregroundStyle(ODTheme.muted)
                            Text(r.direction == .sent ? (r.retry ? "TX retry" : "TX") : (r.ownDigipeated ? "MY DIGI" : "RX"))
                                .fontWeight(.bold)
                                .foregroundStyle(r.direction == .sent ? Color.orange : (r.ownDigipeated ? Color.cyan : ODTheme.muted))
                            if let d = r.digipeatDelay { Text(String(format: "+%.1f s", d)).foregroundStyle(.cyan) }
                        }
                        .font(.caption2.monospacedDigit())
                        Text(r.tnc2).font(.caption2.monospaced()).lineLimit(4).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(session.satellite.isEmpty ? "Session" : session.satellite)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            let s = session
            files = await Task.detached(priority: .utility) { PacketSessionExport.writeFiles(s) }.value
        }
    }
}

// MARK: - APRS map

/// Heard stations (by APRS symbol), the operator's station and the satellite's
/// footprint. The footprint is redrawn every few seconds as the satellite moves.
private struct PacketStationMap: View {
    let stations: [PacketHeardStation]
    var objects: [PacketObject] = []
    let observer: ObserverSite
    let satellite: SatelliteRecord
    let myTable: Character?
    let myCode: Character?
    let select: (String) -> Void
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let sub = try? OrbitPredictor.subpoint(satellite, at: context.date)
            Map(position: $camera) {
                if let sub {
                    MapPolygon(coordinates: Self.footprint(latitude: sub.latitude, longitude: sub.longitude,
                                                           altitudeKm: sub.altitudeKm))
                        .foregroundStyle(ODTheme.accent.opacity(0.10))
                        .stroke(ODTheme.accent.opacity(0.6), lineWidth: 1)
                }
                Annotation(observer.name, coordinate: CLLocationCoordinate2D(latitude: observer.latitude,
                                                                             longitude: observer.longitude)) {
                    APRSSymbolBadge(table: myTable, code: myCode, size: 24, tint: ODTheme.good)
                }
                ForEach(stations) { s in
                    if let lat = s.latitude, let lon = s.longitude {
                        Annotation(s.call, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                            Button { select(s.call) } label: {
                                APRSSymbolBadge(table: s.symbolTable, code: s.symbolCode, size: 24,
                                                tint: s.viaDigipeater ? .cyan : ODTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Puts \(s.call) in the To field")
                        }
                    }
                }
                ForEach(objects) { o in
                    Annotation(o.name, coordinate: CLLocationCoordinate2D(latitude: o.latitude, longitude: o.longitude)) {
                        APRSSymbolBadge(table: o.symbolTable, code: o.symbolCode, size: 20, tint: .purple)
                            .accessibilityLabel("\(o.isItem ? "Item" : "Object") \(o.name) from \(o.owner)")
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The 0°-elevation footprint ring around the sub-satellite point (the same
    /// geodesic construction as the ground-track view's footprint).
    static func footprint(latitude: Double, longitude: Double, altitudeKm: Double, samples: Int = 120) -> [CLLocationCoordinate2D] {
        let re = 6371.0
        let gamma = acos(max(-1, min(1, re / (re + max(0, altitudeKm)))))
        let lat0 = latitude * .pi / 180, lon0 = longitude * .pi / 180
        return (0...samples).map { i in
            let theta = Double(i) / Double(samples) * 2 * .pi
            let lat = asin(sin(lat0) * cos(gamma) + cos(lat0) * sin(gamma) * cos(theta))
            let lon = lon0 + atan2(sin(theta) * sin(gamma) * cos(lat0), cos(gamma) - sin(lat0) * sin(lat))
            var lonDeg = lon * 180 / .pi
            while lonDeg > 180 { lonDeg -= 360 }
            while lonDeg < -180 { lonDeg += 360 }
            return CLLocationCoordinate2D(latitude: lat * 180 / .pi, longitude: lonDeg)
        }
    }
}

// MARK: - APRS symbols

/// An APRS symbol drawn as an SF Symbol in a colored disc, with the overlay
/// character (alternate-table symbols such as a numbered digipeater) in the corner.
private struct APRSSymbolBadge: View {
    let table: Character?
    let code: Character?
    var size: CGFloat = 24
    var tint: Color = ODTheme.accent

    var body: some View {
        let symbol = APRSSymbol(table: table, code: code)
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol.systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint, in: Circle())
            if let overlay = symbol.overlay {
                Text(String(overlay))
                    .font(.system(size: size * 0.36, weight: .bold).monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 1.5)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: 3, y: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(symbol.name)
    }
}

/// APRS symbol table/code (APRS 1.0.1 ch. 20) → an SF Symbol and a name, for the
/// common symbols; anything else gets a generic pin. Table `/` is primary, `\` the
/// alternate table, and 0–9/A–Z an alternate symbol with that overlay character.
struct APRSSymbol {
    let systemImage: String
    let name: String
    let overlay: Character?

    init(table: Character?, code: Character?) {
        let t = table ?? "/"
        overlay = t != "/" && t != "\\" && (t.isNumber || ("A"..."Z").contains(t)) ? t : nil
        guard let code else {
            systemImage = "mappin.circle.fill"; name = "Station"
            return
        }
        let entry = t == "/" ? Self.primary[code] : (Self.alternate[code] ?? Self.sharedAlternate(code))
        if let entry {
            systemImage = entry.0; name = entry.1
        } else if t == "/", let n = code.wholeNumberValue {
            systemImage = "\(n).circle.fill"; name = "Numbered circle \(n)"
        } else {
            systemImage = "mappin.circle.fill"; name = "Station"
        }
    }

    /// Alternate-table codes that mean the same thing as in the primary table.
    private static func sharedAlternate(_ code: Character) -> (String, String)? {
        ["#", "&", "-", ">", "_", "k", "u", "s"].contains(code) ? primary[code] : nil
    }

    private static let primary: [Character: (String, String)] = [
        "!": ("shield.fill", "Police"),
        "#": ("antenna.radiowaves.left.and.right", "Digipeater"),
        "$": ("phone.fill", "Phone"),
        "%": ("desktopcomputer", "DX cluster"),
        "&": ("server.rack", "Gateway"),
        "'": ("airplane", "Small aircraft"),
        "(": ("dot.radiowaves.up.forward", "Mobile satellite station"),
        ")": ("figure.roll", "Wheelchair"),
        "+": ("cross.fill", "Red Cross"),
        "-": ("house.fill", "House"),
        "/": ("circle.fill", "Dot"),
        ":": ("flame.fill", "Fire"),
        ";": ("tent.fill", "Campground"),
        "<": ("bicycle", "Motorcycle"),
        "=": ("tram.fill", "Railroad engine"),
        ">": ("car.fill", "Car"),
        "?": ("server.rack", "File server"),
        "@": ("hurricane", "Hurricane prediction"),
        "A": ("cross.case.fill", "Aid station"),
        "B": ("envelope.fill", "BBS"),
        "C": ("ferry.fill", "Canoe"),
        "E": ("eye.fill", "Eyeball event"),
        "G": ("square.grid.3x3", "Grid square"),
        "H": ("bed.double.fill", "Hotel"),
        "I": ("network", "TCP/IP"),
        "K": ("graduationcap.fill", "School"),
        "L": ("desktopcomputer", "PC user"),
        "N": ("envelope.fill", "NTS station"),
        "O": ("balloon.fill", "Balloon"),
        "P": ("shield.fill", "Police"),
        "R": ("bus.fill", "RV"),
        "S": ("dot.radiowaves.up.forward", "Space station"),
        "T": ("tv", "SSTV"),
        "U": ("bus.fill", "Bus"),
        "V": ("tv", "ATV"),
        "W": ("cloud.sun.fill", "Weather service site"),
        "X": ("airplane", "Helicopter"),
        "Y": ("sailboat.fill", "Sailboat"),
        "[": ("figure.walk", "Person"),
        "]": ("envelope.fill", "Mailbox"),
        "^": ("airplane", "Aircraft"),
        "_": ("cloud.sun.fill", "Weather station"),
        "`": ("antenna.radiowaves.left.and.right.circle.fill", "Dish antenna"),
        "a": ("cross.case.fill", "Ambulance"),
        "b": ("bicycle", "Bicycle"),
        "d": ("flame.fill", "Fire department"),
        "f": ("flame.fill", "Fire truck"),
        "g": ("airplane", "Glider"),
        "h": ("cross.fill", "Hospital"),
        "j": ("suv.side.fill", "Jeep"),
        "k": ("truck.box.fill", "Truck"),
        "l": ("laptopcomputer", "Laptop"),
        "n": ("point.3.connected.trianglepath.dotted", "Node"),
        "o": ("building.2.fill", "Emergency operations center"),
        "p": ("pawprint.fill", "Rover"),
        "r": ("dot.radiowaves.left.and.right", "Repeater"),
        "s": ("ferry.fill", "Ship"),
        "u": ("truck.box.fill", "Truck"),
        "v": ("car.side.fill", "Van"),
        "w": ("drop.fill", "Water station"),
        "y": ("antenna.radiowaves.left.and.right", "Yagi at QTH"),
    ]

    private static let alternate: [Character: (String, String)] = [
        "!": ("exclamationmark.triangle.fill", "Emergency"),
        "$": ("dollarsign.circle.fill", "Bank or ATM"),
        "%": ("bolt.fill", "Power plant"),
        "(": ("cloud.fill", "Cloudy"),
        "*": ("snowflake", "Snow"),
        "@": ("hurricane", "Hurricane"),
        "O": ("balloon.fill", "Balloon"),
        "S": ("dot.radiowaves.up.forward", "Satellite"),
        "T": ("cloud.bolt.fill", "Thunderstorm"),
        "[": ("cloud.fill", "Wall cloud"),
        "^": ("airplane", "Aircraft"),
        "a": ("cross.case.fill", "ARES/RACES"),
        "n": ("triangle.fill", "Triangle"),
        "t": ("tornado", "Tornado"),
        "w": ("drop.fill", "Flooding"),
        "0": ("circle.fill", "Circle"),
    ]
}

// ###########################################################################
//  CW DECODER (Home card)
//
//  Kept in this file for the same reason as the packet card: it's already in the
//  Xcode target. The engine (`CWDecoder` / `CWDemodulator`) is in FT4Engine.swift.
// ###########################################################################

struct HomeCWCard: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var cw: CWDecoder
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    @AppStorage(FeatureVisibility.cwKey) private var visibility = FeatureVisibility.auto
    @State private var showSetup = false
    @State private var handOff: String?
    @State private var copied = false
    let satellite: SatelliteRecord

    private var visible: Bool {
        switch visibility { case .auto: audio.audioAvailable || cw.isRunning; case .always: true; case .off: false }
    }

    var body: some View {
        if visible {
            SectionCard("CW decoder") {
                AudioHealthBanner(active: cw.isRunning)
                if !cw.errorText.isEmpty {
                    Text(cw.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(cw.isRunning ? (cw.markOn ? ODTheme.accent : (cw.acquired ? ODTheme.good : ODTheme.warning)) : ODTheme.muted)
                        .frame(width: 10, height: 10)
                    Text(headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(cw.isRunning ? "Stop" : "Start") { toggle() }
                        .buttonStyle(.bordered)
                }
                SatelliteStatusLine(satellite: satellite)
                DopplerFrequencyLine(satellite: satellite, transponderOverride: rig.transponder(for: satellite))
                tuningHint

                if cw.isRunning {
                    statusLine
                    AudioLevelBar(level: cw.inputLevel)
                    spectrumStrip
                }
                if cw.isRunning || !cw.lines.isEmpty { transcript }
                if let handOff {
                    Label(handOff, systemImage: "book.closed").font(.caption).foregroundStyle(ODTheme.good)
                }

                DisclosureGroup("Setup", isExpanded: $showSetup) { setup.padding(.top, 4) }
                    .font(.subheadline).tint(ODTheme.accent)

                Text("Decodes Morse from your USB (or network) audio interface: CW beacons and CW on linear transponders. Runs alongside pass recording and keeps decoding with the screen locked.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private var headline: String {
        guard cw.isRunning else { return cw.lines.isEmpty ? "Idle" : "Stopped" }
        let s = cw.settings
        if cw.pitchLocked { return "Locked at \(Int(cw.pitchHz.rounded())) Hz" }
        return cw.acquired ? "Tracking \(Int(cw.pitchHz.rounded())) Hz"
                           : "Searching \(Int(s.searchLowHz))–\(Int(s.searchHighHz)) Hz…"
    }

    /// On a linear transponder the radio needs CW mode and the pitch in the passband.
    @ViewBuilder private var tuningHint: some View {
        if let tp = rig.transponder(for: satellite), tp.isLinear {
            if !rig.config.tuning.linearCW {
                Text("On a linear transponder, set the mode to CW on the Live Doppler card so the radio uses its CW filter, then tune so the CW tone (pitch) falls inside the search range below.")
                    .font(.caption2).foregroundStyle(ODTheme.warning)
            } else {
                Text("Tune so the CW pitch falls inside the \(Int(cw.settings.searchLowHz))–\(Int(cw.settings.searchHighHz)) Hz search range; tap the spectrum to pick a signal.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// Pitch · speed · SNR, plus the pitch lock.
    private var statusLine: some View {
        HStack(spacing: 8) {
            Group {
                Text(cw.acquired ? "\(Int(cw.pitchHz.rounded())) Hz" : "— Hz")
                Text(cw.acquired ? String(format: "%.0f WPM", cw.wpm) : "— WPM")
                Text(cw.acquired ? String(format: "SNR %.0f dB", cw.snrDb) : "SNR —")
                    .foregroundStyle(cw.acquired && cw.snrDb >= cw.settings.squelchDb ? ODTheme.good : ODTheme.muted)
            }
            .font(.caption.monospacedDigit())
            Spacer()
            Button {
                cw.pitchLocked.toggle()
            } label: {
                Label(cw.pitchLocked ? "Locked" : "Lock", systemImage: cw.pitchLocked ? "lock.fill" : "lock.open")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(cw.pitchLocked ? ODTheme.warning : ODTheme.accent)
            .accessibilityLabel(cw.pitchLocked ? "Unlock pitch" : "Lock pitch")
        }
    }

    /// Spectrum waterfall over the search range with the detector passband marked; tap
    /// to tune the detector to a signal.
    private var spectrumStrip: some View {
        let lo = cw.settings.searchLowHz, hi = cw.settings.searchHighHz
        let span = max(1, hi - lo)
        return VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    if let img = cw.waterfall {
                        Image(uiImage: img).resizable().interpolation(.none)
                            .frame(width: w, height: 64)
                    } else {
                        Rectangle().fill(ODTheme.panel)
                            .overlay(Text("Spectrum").font(.caption2).foregroundStyle(ODTheme.muted))
                    }
                    if cw.acquired {
                        let x = w * CGFloat(min(1, max(0, (cw.pitchHz - lo) / span)))
                        let bw = max(2, w * CGFloat(cw.settings.bandwidthHz / span))
                        Rectangle().fill(Color.orange.opacity(0.18)).frame(width: bw, height: 64).offset(x: x - bw / 2)
                        Rectangle().fill(.orange).frame(width: 2, height: 64).offset(x: x - 1)
                    }
                }
                .frame(width: w, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    cw.setPitch(lo + span * Double(min(1, max(0, p.x / max(1, w)))))
                }
            }
            .frame(height: 64)
            .accessibilityLabel("CW spectrum")
            .accessibilityHint("Tap a signal to tune the decoder to it")
            HStack {
                Text("\(Int(lo)) Hz").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
                Spacer(); Text("Tap a trace to tune").font(.system(size: 8)).foregroundStyle(ODTheme.muted)
                Spacer(); Text("\(Int(hi)) Hz").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// Framed, self-scrolling monospaced transcript (newest at the bottom). Callsigns are
    /// links that hand the call to the Log QSO card.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Decoded", systemImage: "text.alignleft")
                    .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.accent)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = cw.transcriptText
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .disabled(cw.lines.isEmpty)
                ShareLink(item: cw.transcriptText) { Image(systemName: "square.and.arrow.up") }
                    .disabled(cw.lines.isEmpty)
                    .accessibilityLabel("Share transcript")
                Button("Clear") { cw.clear() }.disabled(cw.lines.isEmpty)
            }
            .font(.caption).buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))

            Divider().overlay(ODTheme.muted.opacity(0.3))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if cw.lines.isEmpty {
                        Text(cw.acquired ? "Listening…" : "Waiting for a CW signal…")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    ForEach(cw.lines) { line in
                        transcriptRow(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .frame(height: 150)
            .defaultScrollAnchor(.bottom)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.callScheme,
                      let call = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "call" })?.value,
                      !call.isEmpty else { return .systemAction }
                takeCall(call.uppercased())
                return .handled
            })

            Divider().overlay(ODTheme.muted.opacity(0.3))
            Text(qso.config.enabled ? "Tap an underlined callsign to put it in the Log QSO card (mode CW)."
                                    : "Turn on logging (Log settings) to log tapped callsigns.")
                .font(.system(size: 10)).foregroundStyle(ODTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color.black.opacity(0.9), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ODTheme.muted.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static let callScheme = "orbitdeck-cw"

    /// In-card link for a spotted callsign (handled by the transcript's openURL action).
    private static func callURL(_ call: String) -> URL? {
        var c = URLComponents()
        c.scheme = callScheme; c.host = "log"
        c.queryItems = [URLQueryItem(name: "call", value: call)]
        return c.url
    }

    private func transcriptRow(_ line: CWTranscriptLine) -> some View {
        var text = AttributedString()
        if cw.settings.timestamps {
            var ts = AttributedString(CWDecoder.utc.string(from: line.date) + "  ")
            ts.foregroundColor = ODTheme.muted
            text += ts
        }
        let words = line.text.split(separator: " ", omittingEmptySubsequences: false)
        for (i, w) in words.enumerated() {
            if i > 0 { text += AttributedString(" ") }
            var run = AttributedString(String(w))
            if qso.config.enabled, CWMorse.isCallsign(String(w)), let url = Self.callURL(String(w)) {
                run.link = url
                run.underlineStyle = .single
                run.foregroundColor = ODTheme.accent
            }
            text += run
        }
        return Text(text)
            .font(.system(size: 13).monospaced())
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func takeCall(_ call: String) {
        qso.prefillQuickLog(call: call, mode: "CW")
        handOff = "\(call) is in the Log QSO card (mode CW)."
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); handOff = nil }
    }

    private var settingsBinding: Binding<CWSettings> { $cw.settings }

    private var setup: some View {
        let s = settingsBinding
        return VStack(alignment: .leading, spacing: 10) {
            AudioLevelControl(title: "Input level", gain: $cw.inputGain, level: cw.inputLevel)
            Text("Keep the meter out of the red; the decoder adapts to the level, but clipping smears the tone.")
                .font(.caption2).foregroundStyle(ODTheme.muted)

            VStack(alignment: .leading, spacing: 3) {
                Text("Search range").font(.caption2.weight(.semibold)).foregroundStyle(ODTheme.muted)
                // Compact menus: `.font` doesn't shrink a menu picker's label, so size the
                // control itself and keep both on one row without crowding the card.
                HStack(spacing: 6) {
                    Picker("From", selection: s.searchLowHz) {
                        ForEach([200.0, 300, 400, 500, 600, 800], id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    Text("to").font(.caption2).foregroundStyle(ODTheme.muted)
                    Picker("To", selection: s.searchHighHz) {
                        ForEach([900.0, 1000, 1200, 1500, 2000], id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    Spacer(minLength: 0)
                }
                Text("The decoder looks for a CW tone between these pitches.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Filter bandwidth").font(.caption2.weight(.semibold)).foregroundStyle(ODTheme.muted)
                Picker("Bandwidth", selection: s.bandwidthHz) {
                    ForEach(CWSettings.bandwidths, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Narrower rejects more noise and neighbors; wider follows fast code (over ~30 WPM use 200 Hz) and Doppler better.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Squelch").font(.caption2.weight(.semibold)).foregroundStyle(ODTheme.muted)
                    Spacer()
                    Text(String(format: "%.0f dB", s.wrappedValue.squelchDb)).font(.caption2.monospacedDigit())
                }
                FineSlider(value: s.squelchDb, range: 0...20, step: 1)
                Text("Only prints while the tone stands this far above the noise. Lower it for weak signals; raise it if noise prints as stray letters.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }

            Toggle("Fixed speed", isOn: s.fixedSpeed).font(.subheadline).toggleStyle(.switch)
            if s.wrappedValue.fixedSpeed {
                Stepper(value: s.fixedWPM, in: 5...50, step: 1) {
                    Text("\(Int(s.wrappedValue.fixedWPM)) WPM").font(.subheadline.monospacedDigit())
                }
            } else {
                Stepper(value: s.minWPM, in: 5...(s.wrappedValue.maxWPM - 5), step: 1) {
                    Text("Slowest \(Int(s.wrappedValue.minWPM)) WPM").font(.subheadline.monospacedDigit())
                }
                Stepper(value: s.maxWPM, in: (s.wrappedValue.minWPM + 5)...60, step: 1) {
                    Text("Fastest \(Int(s.wrappedValue.maxWPM)) WPM").font(.subheadline.monospacedDigit())
                }
                Text("The speed is measured from the code itself, within this range. Farnsworth-spaced code is handled.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }

            Toggle(isOn: s.afc) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AFC (follow drift)").font(.subheadline)
                    Text("Follows the tone as Doppler or your dial moves it. Lock the pitch to stop both searching and AFC.")
                        .font(.caption2).foregroundStyle(ODTheme.muted)
                }
            }
            .toggleStyle(.switch)
            Toggle("Timestamps (UTC) on each line", isOn: s.timestamps).font(.subheadline).toggleStyle(.switch)
            Button("Restore defaults") { cw.settings = CWSettings() }
                .font(.caption).buttonStyle(.borderless)
        }
    }

    private func toggle() {
        if cw.isRunning {
            cw.stop()
        } else if let source = audio.makeSource(allowMicFallback: visibility == .always) {
            cw.start(source: source)
        } else {
            cw.errorText = "No audio interface available."
        }
    }
}
