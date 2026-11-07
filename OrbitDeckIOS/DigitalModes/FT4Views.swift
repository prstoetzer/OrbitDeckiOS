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
            Text("Tap a station to work it").font(.system(size: 10)).foregroundStyle(ODTheme.muted)
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
                TextField("TX message (e.g. CQ N8HM FM18)", text: $ft4.txMessage)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
                Toggle("Transmit on even slots", isOn: $ft4.txOnEvenSlots)
            }
            if !ft4.pttOverCAT {
                Text("No CAT PTT — use VOX or key manually when the TX indicator shows. Configure a CAT radio (CI-V / Yaesu / Kenwood / rigctld / Icom network) for automatic keying.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
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
            let calHz = store.downlinkCalibrationHz(for: satellite.id, invert: transponder?.invert ?? false)
            let dlCenter = Double(transponder?.downlinkCenter ?? 0)
            let calibratedCenter = dlCenter > 0 ? dlCenter + calHz : 0
            ft4.rxBaseHzProvider = { [weak rig] in
                let dial = Double(rig?.downlinkDialHz ?? 0)
                return dial > 0 ? dial : calibratedCenter
            }
            // Automatic transponder calibration (opt-in): fold the error between our own
            // decoded FT4 signal and our TX audio frequency into the saved per-satellite
            // calibration, damped and clamped so a stray decode can't yank it. Only for a
            // linear transponder — FM birds don't need audio-domain calibration.
            if ft4AutoCal, transponder?.isLinear == true {
                let norad = satellite.id
                ft4.ownSignalCalibration = { [weak store] errHz in
                    guard let store else { return }
                    var cal = store.calibration(for: norad)
                    let step = max(-2000.0, min(2000.0, errHz)) * 0.4    // damped residual
                    cal.downlinkHz = max(-20_000, min(20_000, cal.downlinkHz + step))
                    store.setCalibration(cal, for: norad)
                    ODLog.shared.log(String(format: "FT4 auto-cal: sat %u downlink cal → %+.0f Hz", norad, cal.downlinkHz), category: "ft4")
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
                return ["APRS", "AFSK", "PACKET", "DIGI"].contains { h.contains($0) }
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
                    }
                    .pickerStyle(.segmented)
                    if tab == 0 { monitor } else { stations }
                }

                DisclosureGroup("Setup", isExpanded: $showSetup) { setup.padding(.top, 4) }
                    .font(.subheadline).tint(ODTheme.accent)
            }
            .task(id: satellite.id) {
                await packet.tuneBBLink(for: satellite)
            }
            // AOS/LOS for the horizon line, refreshed each minute.
            .task(id: "\(satellite.id)-\(Int(Date().timeIntervalSince1970 / 60))") {
                let sat = satellite, observer = store.preferences.observer
                horizonEvent = await Task.detached(priority: .utility) {
                    try? OrbitPredictor.nextEvent(sat, observer: observer, horizonDays: 2)
                }.value
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

    /// Per-satellite format and path (ISS: APRS via ARISS).
    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Format", selection: profile.format) {
                ForEach(PacketMessageFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
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
                    Button("Reply") { messageTo = station.call }.font(.caption).buttonStyle(.bordered)
                    Button("Log") { packet.logQSO(with: station.call) }.font(.caption).buttonStyle(.bordered)
                        .disabled(station.logged)
                }
            }
        }
    }

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
                Button { packet.sendTestTone() } label: { Label("Send 3 s test tone", systemImage: "waveform") }
                    .buttonStyle(.bordered)
                    .disabled(!packet.isRunning || packet.isTransmitting)
                Toggle("Off-frequency decoders (±175/±350 Hz)", isOn: $packet.settings.offsetDecoders)
                    .disabled(packet.isRunning)
                Text("1200-baud AFSK through your audio interface. OrbitDeck keys the radio over CAT when it can, otherwise use VOX. Set about 3 kHz deviation: send the test tone into a dummy load, start low and raise the level until the digipeated copy decodes. Off-frequency decoders catch stations slightly off frequency (residual Doppler).")
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
                        .multilineTextAlignment(.trailing).textFieldStyle(.odField).frame(width: 190)
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
                    Text(entry.frame.source.description).font(.caption.weight(.semibold))
                    Text("→ \(entry.aprs.kind == .message || entry.aprs.kind == .ack ? entry.aprs.addressee : entry.frame.destination.description)")
                        .font(.caption2).foregroundStyle(ODTheme.muted)
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
                Text(entry.text.isEmpty ? entry.frame.monitorText : entry.text)
                    .font(.caption.monospaced()).foregroundStyle(color).lineLimit(3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
