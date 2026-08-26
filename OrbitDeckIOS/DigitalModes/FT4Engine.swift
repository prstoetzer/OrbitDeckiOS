import Foundation
import Combine

// ===========================================================================
//  FT4Engine.swift — full-duplex FT4 over an AudioSource, using ft8_lib (MIT)
//
//  Linear-transponder FT4: decode the downlink while transmitting the uplink at
//  the same time (full duplex). RX audio is fed to ft8_lib's monitor/decoder on
//  UTC-aligned 7.5 s slots; TX is a continuous-phase 4-FSK synthesis of the
//  encoded tones played back through the same interface. PTT is keyed over CAT
//  when the radio supports it (RigController.setPTT); otherwise the operator uses
//  VOX or manual PTT, aided by the on-screen TX indicator.
//
//  FT4 is ~100% duty cycle — the UI warns operators to limit power out of respect
//  for others sharing the transponder.
// ===========================================================================

/// FT4 slot period (seconds). File-scope so the nonisolated slot handler can use it.
private let kFT4SlotSeconds = 7.5

struct FT4DecodedMessage: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let snr: Int          // estimated signal report (dB) — sent as our report to this station
    let freqHz: Double
    let atSlot: Int
}

@MainActor
final class FT4Engine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var decodes: [FT4DecodedMessage] = []
    @Published private(set) var status = "Idle"
    @Published private(set) var isTransmitting = false
    @Published var errorText = ""

    // Operator-set TX state.
    @Published var txEnabled = false
    @Published var txOnEvenSlots = true
    @Published var txMessage = ""
    @Published var txAudioFreq = 1500.0

    // Auto-sequencing (WSJT-style): the engine advances the standard FT4 exchange
    // and logs on completion. Report we send (dB); the station we're working.
    @Published var autoSequence = false
    /// The report we send this station — set automatically from their decoded SNR.
    private var reportOut = -10
    @Published private(set) var workedCall = ""
    @Published private(set) var seqStatus = ""

    /// Called when an auto-sequenced QSO completes so the UI can log it with the
    /// current satellite/transponder context.
    var onQSOComplete: ((_ call: String, _ grid: String, _ rstSent: String, _ rstRcvd: String) -> Void)?

    private var myCallSeq = ""
    private var myGridSeq = ""
    private var workedGrid = ""
    private var reportIn: Int?
    private var logged = false
    private var finalizeNext = false

    /// True when the connected radio can be keyed over CAT; false ⇒ VOX/manual.
    @Published private(set) var pttOverCAT = false

    private weak var rig: RigController?
    private weak var qso: QSOStore?
    private var source: AudioSource?

    private let slotQueue = DispatchQueue(label: "org.orbitdeck.ft4.slot")
    private nonisolated(unsafe) var slotTimer: DispatchSourceTimer?

    // RX buffer for the current slot (filled on the audio thread).
    private nonisolated(unsafe) var rxBuffer: [Float] = []
    private nonisolated(unsafe) var sampleRate: Double = 48_000
    private nonisolated(unsafe) let lock = NSLock()

    // TX playback buffer.
    private nonisolated(unsafe) var txBuffer: [Float] = []
    private nonisolated(unsafe) var txIndex = 0
    private nonisolated(unsafe) let txLock = NSLock()

    func attach(rig: RigController, qso: QSOStore) { self.rig = rig; self.qso = qso }

    // MARK: Lifecycle

    func start(source: AudioSource, myCall: String, myGrid: String) {
        guard !isRunning else { return }
        errorText = ""; decodes.removeAll()
        self.source = source
        self.sampleRate = source.sampleRate
        lock.lock(); rxBuffer.removeAll(keepingCapacity: true); lock.unlock()
        myCallSeq = myCall.uppercased()
        myGridSeq = String(myGrid.prefix(4)).uppercased()
        endSequence()
        if txMessage.isEmpty, !myCall.isEmpty {
            txMessage = myGrid.isEmpty ? "CQ \(myCall)" : "CQ \(myCall) \(String(myGrid.prefix(4)))"
        }
        pttOverCAT = rig?.pttSupported ?? false
        source.onError = { [weak self] m in self?.errorText = m }
        do {
            try source.start(onFrames: { [weak self] frames in
                guard let self else { return }
                self.lock.lock(); self.rxBuffer.append(contentsOf: frames); self.lock.unlock()
            })
        } catch { errorText = error.localizedDescription; self.source = nil; return }
        isRunning = true; status = "Listening…"
        scheduleSlotTimer()
    }

    func stop() {
        guard isRunning else { return }
        slotTimer?.cancel(); slotTimer = nil
        source?.stopPlayback()
        source?.stop()
        source = nil
        if isTransmitting { Task { await rig?.setPTT(false) } }
        isTransmitting = false
        isRunning = false
        status = "Idle"
    }

    // MARK: Slot timing (UTC-aligned)

    private nonisolated func scheduleSlotTimer() {
        let period = kFT4SlotSeconds
        let now = Date().timeIntervalSince1970
        let delay = (floor(now / period) + 1) * period - now
        let t = DispatchSource.makeTimerSource(queue: slotQueue)
        t.schedule(deadline: .now() + delay, repeating: period)
        t.setEventHandler { [weak self] in self?.onSlotBoundary() }
        t.resume()
        slotTimer = t
    }

    /// Runs on `slotQueue` at each 7.5 s boundary: decode the slot that just ended,
    /// then start a TX if it's our turn.
    private nonisolated func onSlotBoundary() {
        // Grab and reset the just-ended slot's audio.
        lock.lock(); let slot = rxBuffer; rxBuffer.removeAll(keepingCapacity: true); let rate = sampleRate; lock.unlock()

        let endedSlotIndex = Int((Date().timeIntervalSince1970 / kFT4SlotSeconds).rounded()) - 1
        let found = slot.count > Int(rate * 3.0) ? FT4Engine.decodeSlot(slot, rate: rate) : []
        let startingSlot = endedSlotIndex + 1

        Task { @MainActor in
            // Finalize a QSO that completed on the previous cycle (after its final
            // frame was transmitted).
            if self.finalizeNext { self.finalizeNext = false; self.endSequence() }

            if !found.isEmpty {
                for f in found {
                    self.decodes.append(FT4DecodedMessage(text: f.text, snr: f.snr, freqHz: f.freq, atSlot: endedSlotIndex))
                }
                if self.decodes.count > 100 { self.decodes.removeFirst(self.decodes.count - 100) }
                self.status = "Decoded \(found.count) this slot"
            }

            // Auto-sequencer updates txMessage/txEnabled before the TX decision.
            if self.autoSequence { self.advance(found, endedSlot: endedSlotIndex) }

            guard self.txEnabled, !self.txMessage.isEmpty else { return }
            let ourSlot = (startingSlot % 2 == 0) == self.txOnEvenSlots
            if ourSlot { self.beginTransmit() }
        }
    }

    // MARK: Auto-sequencer

    /// Message field parse: `CQ`, or `<to> <de> <extra>`.
    struct FT4Fields { let isCQ: Bool; let to: String; let de: String; let extra: String }

    static func parse(_ text: String) -> FT4Fields? {
        let t = text.split(separator: " ").map { $0.uppercased() }
        guard !t.isEmpty else { return nil }
        if t[0] == "CQ" {
            // CQ [DX|region] <call> [grid]
            var i = 1
            if t.count > 2, t[1] == "DX" || (t[1].count <= 3 && !t[1].contains(where: { $0.isNumber })) { i = 2 }
            let call = t.count > i ? t[i] : ""
            let grid = t.count > i + 1 ? t[i + 1] : ""
            return FT4Fields(isCQ: true, to: "", de: call, extra: grid)
        }
        return FT4Fields(isCQ: false, to: t[0], de: t.count > 1 ? t[1] : "", extra: t.count > 2 ? t[2] : "")
    }

    /// Begin calling CQ (auto-seq will engage the first station that answers).
    func callCQ() {
        guard !myCallSeq.isEmpty else { errorText = "Set your callsign in Log settings first."; return }
        workedCall = ""; workedGrid = ""; reportIn = nil; logged = false
        txMessage = myGridSeq.isEmpty ? "CQ \(myCallSeq)" : "CQ \(myCallSeq) \(myGridSeq)"
        autoSequence = true; txEnabled = true
        seqStatus = "Calling CQ"
    }

    /// Answer a decoded CQ (starts the exchange with that station).
    func answerCQ(_ d: FT4DecodedMessage) {
        guard let f = FT4Engine.parse(d.text), f.isCQ, !myCallSeq.isEmpty else { return }
        workedCall = f.de; workedGrid = FT4Engine.isGrid(f.extra) ? f.extra : ""; reportIn = nil; logged = false
        reportOut = d.snr        // our report to them = their decoded SNR
        // Reply with our grid (or a report if we have no grid).
        let mine = myGridSeq.isEmpty ? FT4Engine.reportString(reportOut) : myGridSeq
        txMessage = "\(workedCall) \(myCallSeq) \(mine)"
        autoSequence = true; txEnabled = true
        txOnEvenSlots = (d.atSlot % 2 != 0)     // transmit opposite to their slot
        seqStatus = "Answering \(workedCall)"
    }

    /// Advance the exchange based on messages addressed to us this slot.
    private func advance(_ found: [(text: String, snr: Int, freq: Double)], endedSlot: Int) {
        guard !myCallSeq.isEmpty else { return }
        for d in found {
            guard let f = FT4Engine.parse(d.text), !f.isCQ, f.to == myCallSeq else { continue }
            if workedCall.isEmpty { workedCall = f.de; txOnEvenSlots = (endedSlot % 2 != 0); reportOut = d.snr }
            guard f.de == workedCall else { continue }
            let extra = f.extra

            if extra == "RR73" || extra == "RRR" || extra == "73" {
                logQSO(); seqStatus = "Logged \(workedCall)"; endSequence(); return
            }
            if FT4Engine.isReportToken(extra) {
                reportIn = FT4Engine.parseReport(extra)
                if extra.hasPrefix("R") {
                    // They rogered our report — send RR73 and complete.
                    txMessage = "\(workedCall) \(myCallSeq) RR73"; seqStatus = "Sending RR73 to \(workedCall)"
                    logQSO(); finalizeNext = true
                } else {
                    // They sent a report — roger it back.
                    txMessage = "\(workedCall) \(myCallSeq) R\(FT4Engine.reportString(reportOut))"
                    seqStatus = "Rogered \(workedCall)"
                }
                txEnabled = true; return
            }
            if FT4Engine.isGrid(extra) {
                workedGrid = extra
                txMessage = "\(workedCall) \(myCallSeq) \(FT4Engine.reportString(reportOut))"
                seqStatus = "Reporting \(workedCall)"
                txEnabled = true; return
            }
        }
    }

    private func logQSO() {
        guard !logged, !workedCall.isEmpty else { return }
        logged = true
        onQSOComplete?(workedCall, workedGrid, FT4Engine.reportString(reportOut),
                       reportIn.map { FT4Engine.reportString($0) } ?? "")
    }

    private func endSequence() {
        workedCall = ""; workedGrid = ""; reportIn = nil; logged = false; finalizeNext = false
        if autoSequence { seqStatus = "" }
    }

    static func reportString(_ r: Int) -> String { String(format: "%+03d", r) }
    static func parseReport(_ s: String) -> Int? { Int(s.hasPrefix("R") ? String(s.dropFirst()) : s) }
    static func isReportToken(_ s: String) -> Bool {
        var t = s; if t.hasPrefix("R") { t.removeFirst() }
        guard t.hasPrefix("+") || t.hasPrefix("-") else { return false }
        return Int(t) != nil
    }
    static func isGrid(_ s: String) -> Bool {
        s.count == 4 && s.prefix(2).allSatisfy { $0.isLetter } && s.suffix(2).allSatisfy { $0.isNumber }
    }

    // MARK: Transmit

    private func beginTransmit() {
        guard let source, !isTransmitting else { return }
        guard let tones = FT4Engine.encodeTones(txMessage) else { errorText = "Could not encode \"\(txMessage)\"."; return }
        let tx = FT4Engine.synthesize(tones: tones, rate: source.sampleRate, f0: txAudioFreq)
        txLock.lock(); txBuffer = tx; txIndex = 0; txDone = false; txLock.unlock()
        isTransmitting = true
        status = "Transmitting"
        Task {
            await rig?.setPTT(true)
            do {
                try source.startPlayback(pull: { [weak self] count in self?.pullTX(count) ?? [] })
            } catch { errorText = error.localizedDescription; await endTransmit() }
        }
    }

    private nonisolated func pullTX(_ count: Int) -> [Float] {
        txLock.lock()
        let remaining = txBuffer.count - txIndex
        if remaining <= 0 {
            // Buffer exhausted. The audio render callback fires every few ms, so
            // schedule the end-of-transmit exactly once (a Task per callback would
            // flood — and freeze — the main actor).
            let firstTime = !txDone
            txDone = true
            txLock.unlock()
            if firstTime { Task { @MainActor in await self.endTransmit() } }
            return []
        }
        let n = min(count, remaining)
        let out = Array(txBuffer[txIndex..<(txIndex + n)])
        txIndex += n
        txLock.unlock()
        return out
    }
    private nonisolated(unsafe) var txDone = false

    private func endTransmit() async {
        guard isTransmitting else { return }
        source?.stopPlayback()
        await rig?.setPTT(false)
        isTransmitting = false
        status = isRunning ? "Listening…" : "Idle"
    }

    // MARK: ft8_lib interop (nonisolated — off the main actor)

    /// Decode one slot of audio into (text, score, freq).
    nonisolated static func decodeSlot(_ samples: [Float], rate: Double) -> [(text: String, snr: Int, freq: Double)] {
        var cfg = monitor_config_t(f_min: 100, f_max: 3600, sample_rate: Int32(rate),
                                   time_osr: 2, freq_osr: 2, protocol: FTX_PROTOCOL_FT4)
        var mon = monitor_t()
        monitor_init(&mon, &cfg)
        defer { monitor_free(&mon) }
        let block = Int(mon.block_size)
        guard block > 0 else { return [] }

        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i + block <= buf.count { monitor_process(&mon, base + i); i += block }
        }

        let maxC = 140
        var cands = [ftx_candidate_t](repeating: ftx_candidate_t(), count: maxC)
        let n = ftx_find_candidates(&mon.wf, Int32(maxC), &cands, 10)

        var out: [(String, Int, Double)] = []
        var seen = Set<UInt16>()
        for idx in 0..<Int(n) {
            var msg = ftx_message_t()
            var st = ftx_decode_status_t()
            let ok = ftx_decode_candidate(&mon.wf, &cands[idx], 20, &msg, &st)
            guard ok, !seen.contains(msg.hash) else { continue }
            seen.insert(msg.hash)
            var text = [CChar](repeating: 0, count: 64)
            _ = ftx_message_decode(&msg, nil, &text, nil)
            out.append((String(cString: text), snr(fromScore: Int(cands[idx].score)), Double(st.freq)))
        }
        return out
    }

    /// Approximate signal report (dB) from a candidate's sync score. ft8_lib does
    /// not expose a calibrated SNR, so this is a rough, clamped estimate that stands
    /// in for the report we send — refine against on-air signals.
    nonisolated static func snr(fromScore s: Int) -> Int { max(-24, min(15, s / 8 - 20)) }

    /// Encode a text message to FT4 tones (0…3), or nil if it can't be packed.
    nonisolated static func encodeTones(_ text: String) -> [UInt8]? {
        var msg = ftx_message_t()
        let rc = text.withCString { ftx_message_encode(&msg, nil, $0) }
        guard rc == FTX_MESSAGE_RC_OK else { return nil }
        var tones = [UInt8](repeating: 0, count: Int(FT4_NN))
        withUnsafeMutablePointer(to: &msg.payload) { pl in
            pl.withMemoryRebound(to: UInt8.self, capacity: Int(FTX_PAYLOAD_LENGTH_BYTES)) { plBytes in
                tones.withUnsafeMutableBufferPointer { tb in ft4_encode(plBytes, tb.baseAddress) }
            }
        }
        return tones
    }

    /// Continuous-phase 4-FSK synthesis of FT4 tones (approximate GFSK; decodes
    /// fine in practice). Tone spacing = 1/symbol period = 20.833 Hz.
    nonisolated static func synthesize(tones: [UInt8], rate: Double, f0: Double) -> [Float] {
        let symbolPeriod = Double(FT4_SYMBOL_PERIOD)
        let sps = max(1, Int(rate * symbolPeriod))
        let toneSpacing = 1.0 / symbolPeriod
        var out = [Float](); out.reserveCapacity(sps * tones.count)
        var phase = 0.0
        for t in tones {
            let f = f0 + Double(t) * toneSpacing
            let dphi = 2.0 * Double.pi * f / rate
            for _ in 0..<sps {
                out.append(Float(0.5 * sin(phase)))
                phase += dphi
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
        }
        // Short raised-cosine amplitude ramps to suppress key clicks.
        let ramp = min(sps, out.count / 2)
        for i in 0..<ramp {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(ramp)))
            out[i] *= g; out[out.count - 1 - i] *= g
        }
        return out
    }
}
