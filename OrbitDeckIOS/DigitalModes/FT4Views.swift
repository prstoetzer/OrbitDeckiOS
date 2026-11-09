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
    /// Band Activity filter: "all", or "me" (calling me, my transmissions and my echoes).
    @AppStorage(FT4Settings.decodeFilterKey) private var decodeFilter = "all"
    /// Calls and 4-character grids already in the log (for the "new" shading), rebuilt
    /// only when the log changes — not on every waterfall refresh.
    @State private var workedCalls: Set<String> = []
    @State private var workedGrids: Set<String> = []
    let satellite: SatelliteRecord

    /// Why FT4 can't start on the current transponder (FM-only), or nil.
    private var fmOnlyReason: String? { FT4Engine.fmOnlyReason(rig.transponder(for: satellite)) }

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
                if let why = ft4.watchdogTripped { noticeBanner(why, systemImage: "timer") }
                if let warn = ft4.rfPowerWarning { noticeBanner(warn, systemImage: "bolt.fill") }
                if let why = fmOnlyReason, !ft4.isRunning {
                    Text(why).font(.caption).foregroundStyle(ODTheme.warning)
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
                        .disabled(!ft4.isRunning && (halfDuplex || fmOnlyReason != nil))
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
            .onAppear { setupLogging(); rebuildWorked() }
            .onChange(of: qso.qsos.count) { _, _ in rebuildWorked() }
        }
    }

    /// Calls and VUCC grids (first 4 characters) already in the log. Read-only.
    private func rebuildWorked() {
        var calls = Set<String>(), grids = Set<String>()
        for q in qso.qsos {
            let c = q.call.uppercased().trimmingCharacters(in: .whitespaces)
            if !c.isEmpty { calls.insert(c) }
            for g in q.grid.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let g4 = String(g.prefix(4))
                if FT4Engine.isGrid(g4) { grids.insert(g4) }
            }
        }
        workedCalls = calls; workedGrids = grids
    }

    private func noticeBanner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(ODTheme.warning.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    // Slot-start lines (drawn into the image) get their UTC time here.
                    if ft4.waterfallSlotLines {
                        ForEach(ft4.waterfallMarks) { m in
                            Text(Self.utcShort.string(from: m.date))
                                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 2)
                                .background(Color.black.opacity(0.45))
                                .offset(x: 2, y: max(0, min(118, 130 * m.position - 10)))
                        }
                    }
                    // TX frequency marker (0–3 kHz spans the full width).
                    let x = geo.size.width * CGFloat(min(1, max(0, ft4.txAudioFreq / 3000)))
                    Rectangle().fill(.orange).frame(width: 2, height: 130).offset(x: x - 1)
                    Text("TX").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        .offset(x: min(geo.size.width - 18, max(0, x - 6)), y: 2)
                }
            }
            .frame(height: 130)
            .contentShape(Rectangle())
            // Long-press: decode the previous slot again, harder.
            .onLongPressGesture(minimumDuration: 0.5) { if ft4.canDecodeDeep { ft4.decodeAgainDeep() } }
            .accessibilityAction(named: "Decode again (deep)") { ft4.decodeAgainDeep() }
            HStack {
                Text("0").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
                Spacer(); Text("1.5 kHz").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
                Spacer(); Text("3 kHz").font(.system(size: 8).monospacedDigit()).foregroundStyle(ODTheme.muted)
            }
            HStack(spacing: 8) {
                Button {
                    ft4.decodeAgainDeep()
                } label: {
                    if ft4.deepDecoding {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Decoding…") }
                    } else {
                        Label("Decode again (deep)", systemImage: "magnifyingglass")
                    }
                }
                .font(.caption2).buttonStyle(.bordered).controlSize(.small)
                .disabled(!ft4.canDecodeDeep || ft4.deepDecoding)
                Spacer(minLength: 0)
                Text("or long-press the waterfall").font(.system(size: 9)).foregroundStyle(ODTheme.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private static let utcShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    private static let utcCompact: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

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
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Band Activity", systemImage: "waveform.badge.magnifyingglass")
                        .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.accent)
                    Spacer()
                    legendDot(ODTheme.good, "CQ"); legendDot(ODTheme.accent, "you")
                    legendDot(.orange, "TX"); legendDot(.cyan, "self")
                }
                HStack(spacing: 8) {
                    Picker("Show", selection: $decodeFilter) {
                        Text("All").tag("all")
                        Text("Me & my echoes").tag("me")
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    legendSwatch(Self.newCallShade, "new")
                    legendSwatch(Self.newGridShade, "grid")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))

            Divider().overlay(ODTheme.muted.opacity(0.3))

            ScrollView {
                let items = Array(filteredDecodes.suffix(60))
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

    /// Decodes after the Band Activity filter. "Me" keeps messages to me, my own
    /// transmissions and my signal heard back through the transponder.
    private var filteredDecodes: [FT4DecodedMessage] {
        guard decodeFilter == "me" else { return ft4.decodes }
        return ft4.decodes.filter { $0.kind == .sent || ft4.isToMe($0.text) || ft4.isFromMe($0.text) }
    }

    static let newCallShade = Color.green.opacity(0.22)
    static let newGridShade = Color.purple.opacity(0.35)

    private func legendSwatch(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 8)
            Text(label).font(.system(size: 9)).foregroundStyle(ODTheme.muted)
        }
        .fixedSize()
    }

    /// Whether a decode's sender (or grid) is one of the pounce targets.
    private func isTarget(_ f: FT4Engine.FT4Fields?) -> Bool {
        guard let f else { return false }
        for t in ft4.pounceTokens {
            if FT4Engine.isGrid(t) {
                if FT4Engine.isGrid(f.extra), f.extra.uppercased().hasPrefix(String(t.prefix(4))) { return true }
            } else if FT4Engine.callMatches(f.de, t) || (f.de.isEmpty && FT4Engine.callMatches(f.to, t)) {
                return true
            }
        }
        return false
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
        // "New" shading for received stations not yet in the log: a new grid (VUCC) wins
        // over a new call. Our own messages and echoes are never shaded.
        var shade: Color = .clear
        if d.kind == .received, let f, !ft4.isFromMe(d.text) {
            let sender = f.de.isEmpty || f.de == "<...>" ? "" : f.de.uppercased()
            if FT4Engine.isGrid(f.extra), !workedGrids.contains(String(f.extra.uppercased().prefix(4))) {
                shade = Self.newGridShade
            } else if !sender.isEmpty, !workedCalls.contains(sender),
                      !sender.split(separator: "/").contains(where: { workedCalls.contains(String($0)) }) {
                shade = Self.newCallShade
            }
        }
        let target = d.kind == .received && isTarget(f)
        // WSJT-X row: time · dB · DT · freq · message, monospaced and aligned.
        let db = d.kind == .sent ? " TX" : String(format: "%3d", d.snr)
        let dt = d.kind == .sent ? "    " : String(format: "%4.1f", d.dt)
        return Button { if d.kind != .sent { ft4.work(d) } } label: {
            HStack(spacing: 5) {
                Text(Self.utcCompact.string(from: d.slotDate)).foregroundStyle(color.opacity(0.7))
                Text(db).foregroundStyle(color.opacity(0.9))
                Text(dt).foregroundStyle(color.opacity(0.7))
                Text(String(format: "%4d", Int(d.freqHz))).foregroundStyle(color.opacity(0.7))
                Text(d.text).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                if target { rowTag("Target", .orange) }
                if d.deep { rowTag("deep", .cyan) } else if d.subtracted { rowTag("sub", .gray) }
            }
            .font(.system(size: 12, weight: (toMe || isCQ) ? .semibold : .regular).monospaced())
            .padding(.vertical, 3)
            .background(shade)
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

    private func rowTag(_ text: String, _ c: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .bold)).foregroundStyle(c)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(c.opacity(0.7), lineWidth: 1))
            .fixedSize()
    }

    /// The essentials, always visible: enable TX, auto-sequence, and the big Call CQ.
    private var txControlsPrimary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Transmit", isOn: $ft4.txEnabled).fixedSize()
                Toggle("Auto-seq", isOn: $ft4.autoSequence).fixedSize()
                Spacer()
                if ft4.isRunning {
                    // Steady carrier at the TX audio frequency (≤ 10 s) to set drive/ALC.
                    Button(ft4.isTuning ? "Stop" : "Tune") { ft4.toggleTune() }
                        .buttonStyle(.bordered).tint(ft4.isTuning ? ODTheme.warning : nil)
                        .disabled(fmOnlyReason != nil || (ft4.isTransmitting && !ft4.isTuning))
                        .accessibilityHint("Transmits a steady tone for up to 10 seconds to set the drive level")
                }
            }
            Button {
                guard fmOnlyReason == nil else { return }
                ft4.callCQ()
                if !ft4.isRunning { toggleRun() }
            } label: {
                Label("Call CQ", systemImage: "megaphone.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(qso.config.myCall.isEmpty || fmOnlyReason != nil)

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

            decoderSetup
            Divider().opacity(0.4)

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

    /// Watchdog, waterfall and decoder options.
    private var decoderSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("TX watchdog", isOn: $ft4.watchdogEnabled).font(.caption)
            if ft4.watchdogEnabled {
                Stepper("Stop after \(ft4.watchdogMinutes) min without a reply",
                        value: $ft4.watchdogMinutes, in: 2...15).font(.caption)
            }
            Text("Stops transmitting (CQ, auto-sequence or a repeated message) when nothing addressed to you has been decoded for that long.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
            HStack {
                Text("Waterfall").font(.caption)
                Spacer()
                Picker("Waterfall history", selection: $ft4.waterfallSeconds) {
                    Text("12 s").tag(12); Text("24 s").tag(24); Text("48 s").tag(48)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            Toggle("Slot lines with UTC time", isOn: $ft4.waterfallSlotLines).font(.caption)
            Toggle("Subtract decoded signals (find weaker ones)", isOn: $ft4.subtraction).font(.caption)
            Toggle("Hide decodes with |DT| over 1.5 s", isOn: $ft4.dtFilter).font(.caption)
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
        if !ft4.isRunning, let why = fmOnlyReason {
            ft4.errorText = why
        } else if ft4.isRunning {
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
    @State private var onlyMine = false
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
        return Text("Sent \(s.sent) · digipeated \(s.digipeated) (\(pct)%)" + (s.digipeated > 0 ? String(format: " · median delay %.1f s", s.medianDelay) : ""))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Only my traffic", isOn: $onlyMine).font(.caption).toggleStyle(.switch).fixedSize()
                Spacer()
                if !packet.log.isEmpty { Button("Clear") { packet.clearLog() }.font(.caption).buttonStyle(.borderless) }
            }
            let entries = packet.log.filter { e in
                !onlyMine || e.direction == .sent || e.ownDigipeated || e.toMe
            }
            if entries.isEmpty {
                Text(onlyMine ? "Nothing to or from you yet." : "No packets yet. Frames heard on the downlink appear here.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } else {
                ForEach(entries.suffix(30).reversed()) { entry in
                    PacketLogRow(entry: entry) { call in messageTo = call }
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
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Stations", selection: $mapAllStations) {
                Text("This pass").tag(false)
                Text("All heard").tag(true)
            }
            .pickerStyle(.segmented)
            PacketStationMap(stations: shown, observer: store.preferences.observer, satellite: satellite,
                             myTable: packet.settings.symbolTable.first, myCode: packet.settings.symbolCode.first) { call in
                messageTo = call
            }
            Text("\(shown.count) on the map" + (unplaced > 0 ? " · \(unplaced) without a position" : "")
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
                Toggle("Number my messages (request acks)", isOn: $packet.settings.requestAcks)
                Toggle("Acknowledge messages to me", isOn: $packet.settings.autoAck)
                Toggle("Log QSOs automatically", isOn: $packet.settings.autoLogQSOs)
                Text("Logs a PKT QSO once you and a station have each sent the other's call, and its reply came after yours or yours was heard back through the satellite. Grid and reports come from the frames. A station already logged on this satellite in the last 30 minutes isn't logged again.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
                Toggle("Block sending while the satellite is below the horizon", isOn: $packet.settings.blockBelowHorizon)
            }
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
        if entry.isBeacon { return "BCN" }
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
                Text(entry.text.isEmpty ? entry.frame.monitorText : entry.text)
                    .font(.caption.monospaced()).foregroundStyle(color).lineLimit(3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - APRS map

/// Heard stations (by APRS symbol), the operator's station and the satellite's
/// footprint. The footprint is redrawn every few seconds as the satellite moves.
private struct PacketStationMap: View {
    let stations: [PacketHeardStation]
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
