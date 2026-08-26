import Foundation
import Combine
import UIKit

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

enum FT4MsgKind: Sendable { case received, sent }

struct FT4DecodedMessage: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let snr: Int          // estimated signal report (dB) — sent as our report to this station
    let freqHz: Double
    let atSlot: Int
    var kind: FT4MsgKind = .received
    /// UTC start of the slot this decode came from.
    var slotDate: Date { Date(timeIntervalSince1970: Double(atSlot) * kFT4SlotSeconds) }
}

@MainActor
final class FT4Engine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var decodes: [FT4DecodedMessage] = []
    @Published private(set) var status = "Idle"
    @Published private(set) var isTransmitting = false
    @Published private(set) var txLevel: Float = 0     // live TX output level (0…1)
    @Published private(set) var rxLevel: Float = 0     // live RX input level (0…1)
    @Published private(set) var waterfall: UIImage?    // scrolling spectrum waterfall
    @Published var errorText = ""

    // Audio levels (linear multipliers) applied to the shared source.
    @Published var inputGain: Float = 1 { didSet { source?.inputGain = inputGain } }
    @Published var outputGain: Float = 1 { didSet { source?.outputGain = outputGain } }

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

    // Spectrum waterfall + RX level (computed on `analysisQueue`).
    private let analysisQueue = DispatchQueue(label: "org.orbitdeck.ft4.spec")
    private nonisolated(unsafe) var analysisTimer: DispatchSourceTimer?
    private nonisolated(unsafe) let specLock = NSLock()
    private nonisolated(unsafe) var specWindow: [Float] = []
    private nonisolated(unsafe) var rxPeak: Float = 0
    private nonisolated(unsafe) let analyzer = SpectrumAnalyzer(n: 4096)
    private nonisolated(unsafe) var waterMagRows: [[Float]] = []   // newest last
    private let waterHeight = 120

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
        source.inputGain = inputGain
        source.outputGain = outputGain
        source.onError = { [weak self] m in self?.errorText = m }
        do {
            try source.start(onFrames: { [weak self] frames in
                guard let self else { return }
                self.lock.lock(); self.rxBuffer.append(contentsOf: frames); self.lock.unlock()
                self.ingestAnalysis(frames)
            })
        } catch { errorText = error.localizedDescription; self.source = nil; return }
        isRunning = true; status = "Listening…"
        AudioActivity.begin()
        scheduleSlotTimer()
        scheduleAnalysisTimer()
    }

    func stop() {
        guard isRunning else { return }
        slotTimer?.cancel(); slotTimer = nil
        analysisTimer?.cancel(); analysisTimer = nil
        source?.stopPlayback()
        source?.stop()
        source = nil
        if isTransmitting { Task { await rig?.setPTT(false) } }
        isTransmitting = false
        isRunning = false
        AudioActivity.end()
        specLock.lock(); specWindow.removeAll(keepingCapacity: true); rxPeak = 0; specLock.unlock()
        rxLevel = 0
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

    // MARK: Spectrum + level metering

    /// Accumulate the running spectrum window and RX peak (on the audio thread).
    private nonisolated func ingestAnalysis(_ frames: [Float]) {
        var peak: Float = 0
        for s in frames { let a = abs(s); if a > peak { peak = a } }
        specLock.lock()
        specWindow.append(contentsOf: frames)
        if specWindow.count > 8192 { specWindow.removeFirst(specWindow.count - 8192) }
        if peak > rxPeak { rxPeak = peak }
        specLock.unlock()
    }

    private nonisolated func scheduleAnalysisTimer() {
        let t = DispatchSource.makeTimerSource(queue: analysisQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.analyze() }
        t.resume()
        analysisTimer = t
    }

    /// Compute one spectrum row + peak (on `analysisQueue`), publish to the UI.
    private nonisolated func analyze() {
        specLock.lock()
        let win = specWindow
        let peak = rxPeak; rxPeak = 0
        specLock.unlock()
        let rate = sampleRate

        var image: UIImage?
        if win.count >= analyzer.n {
            let db = analyzer.magnitudesDB(win)
            if !db.isEmpty {
                let binHz = rate / Double(analyzer.n)
                let maxBin = max(1, min(db.count, Int(3000.0 / binHz)))
                image = appendWaterfall(Array(db[0..<maxBin]))
            }
        }
        Task { @MainActor in
            // Fast attack, slow release so the meter reads like a VU meter (no flash).
            self.rxLevel = max(peak, self.rxLevel * 0.75)
            if let image { self.waterfall = image }
        }
    }

    /// Push a new magnitude row and render the scrolling waterfall (newest at bottom).
    private nonisolated func appendWaterfall(_ row: [Float]) -> UIImage? {
        waterMagRows.append(row)
        if waterMagRows.count > waterHeight { waterMagRows.removeFirst(waterMagRows.count - waterHeight) }
        let w = row.count, h = waterMagRows.count
        guard w > 0, h > 0 else { return nil }
        // Anchor the palette to the noise floor with a FIXED dynamic range (like
        // WSJT-X): the floor stays dark navy and only real signals light up.
        var lo = Float.greatestFiniteMagnitude
        for r in waterMagRows { for v in r where v < lo { lo = v } }
        let range: Float = 45   // dB shown from noise floor to white
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for (y, r) in waterMagRows.enumerated() {
            let count = min(w, r.count)
            for x in 0..<count {
                let c = Heatmap.color((r[x] - lo) / range)
                let o = (y * w + x) * 4
                rgba[o] = c.r; rgba[o + 1] = c.g; rgba[o + 2] = c.b; rgba[o + 3] = 255
            }
        }
        return Self.imageFromRGBA(rgba, width: w, height: h)
    }

    nonisolated static func imageFromRGBA(_ bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        var data = bytes
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs, bitmapInfo: info),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Runs on `slotQueue` at each 7.5 s boundary: decode the slot that just ended,
    /// then start a TX if it's our turn.
    private nonisolated func onSlotBoundary() {
        // Grab and reset the just-ended slot's audio.
        lock.lock(); let slot = rxBuffer; rxBuffer.removeAll(keepingCapacity: true); let rate = sampleRate; lock.unlock()

        let endedSlotIndex = Int((Date().timeIntervalSince1970 / kFT4SlotSeconds).rounded()) - 1
        let haveAudio = slot.count > Int(rate * 3.0)
        let result = haveAudio ? FT4Engine.decodeSlot(slot, rate: rate) : FT4Engine.SlotResult()
        let found = result.messages
        let startingSlot = endedSlotIndex + 1

        Task { @MainActor in
            // Finalize a QSO that completed on the previous cycle (after its final
            // frame was transmitted).
            if self.finalizeNext { self.finalizeNext = false; self.endSequence() }

            for f in found {
                self.decodes.append(FT4DecodedMessage(text: f.text, snr: f.snr, freqHz: f.freq, atSlot: endedSlotIndex))
            }
            if self.decodes.count > 100 { self.decodes.removeFirst(self.decodes.count - 100) }
            // Always report what the decoder saw this slot — distinguishes "no audio"
            // from "signal but no sync candidates" from "candidates but no decode".
            if !self.isTransmitting {
                if !haveAudio {
                    self.status = "No RX audio this slot"
                } else {
                    self.status = "\(found.count) decoded · \(result.candidates) cand · \(result.blocks) blk"
                }
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

    nonisolated static func parse(_ text: String) -> FT4Fields? {
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

    /// Start working a decoded station (tap any decode). Answers a CQ, or calls a
    /// station heard in a directed message; the auto-sequencer takes it from there.
    func work(_ d: FT4DecodedMessage) {
        guard let f = FT4Engine.parse(d.text), !myCallSeq.isEmpty else { return }
        let their = f.isCQ ? f.de : (f.de.isEmpty ? f.to : f.de)
        guard !their.isEmpty else { return }
        workedCall = their; workedGrid = FT4Engine.isGrid(f.extra) ? f.extra : ""; reportIn = nil; logged = false
        reportOut = d.snr        // our report to them = their decoded SNR
        let mine = myGridSeq.isEmpty ? FT4Engine.reportString(reportOut) : myGridSeq
        txMessage = "\(their) \(myCallSeq) \(mine)"
        autoSequence = true; txEnabled = true
        txOnEvenSlots = (d.atSlot % 2 != 0)     // transmit opposite to their slot
        seqStatus = "Working \(their)"
    }

    /// Whether a decode is addressed to us (for highlighting).
    func isToMe(_ text: String) -> Bool {
        guard let f = FT4Engine.parse(text), !f.isCQ else { return false }
        return f.to == myCallSeq && !myCallSeq.isEmpty
    }

    /// Whether a decode was sent BY us (our own signal heard via full duplex).
    func isFromMe(_ text: String) -> Bool {
        guard !myCallSeq.isEmpty, let f = FT4Engine.parse(text) else { return false }
        return f.de == myCallSeq
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
        txLock.lock(); txBuffer = tx; txIndex = 0; txDone = false; txPeak = 0; txLock.unlock()
        isTransmitting = true
        status = "Transmitting: \(txMessage)"
        // Log our own transmission so it shows in the activity panel even when the
        // full-duplex receiver doesn't decode it back.
        let txSlot = Int((Date().timeIntervalSince1970 / kFT4SlotSeconds).rounded())
        decodes.append(FT4DecodedMessage(text: txMessage, snr: 0, freqHz: txAudioFreq, atSlot: txSlot, kind: .sent))
        if decodes.count > 100 { decodes.removeFirst(decodes.count - 100) }
        // Live TX meter (reads the peak the render callback actually emitted) so the
        // operator can confirm audio is going out even without monitoring the rig.
        Task { @MainActor in
            while self.isTransmitting {
                let p = self.txLock.withLock { () -> Float in let v = self.txPeak; self.txPeak = 0; return v }
                self.txLevel = max(p, self.txLevel * 0.75)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.txLevel = 0
        }
        // Transmission is a fixed length; end it on a timer so PTT always unkeys and
        // the UI clears even if the audio output node never pulls the buffer dry.
        let txDuration = Double(tx.count) / source.sampleRate + 0.4
        Task {
            await rig?.setPTT(true)
            do {
                try source.startPlayback(pull: { [weak self] count in self?.pullTX(count) ?? [] })
            } catch { errorText = error.localizedDescription; await endTransmit(); return }
            try? await Task.sleep(nanoseconds: UInt64(txDuration * 1_000_000_000))
            await endTransmit()
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
        var p: Float = 0; for s in out { let a = abs(s); if a > p { p = a } }
        if p > txPeak { txPeak = p }
        txLock.unlock()
        return out
    }
    private nonisolated(unsafe) var txDone = false
    private nonisolated(unsafe) var txPeak: Float = 0

    private func endTransmit() async {
        guard isTransmitting else { return }
        source?.stopPlayback()
        await rig?.setPTT(false)
        isTransmitting = false
        status = isRunning ? "Listening…" : "Idle"
    }

    // MARK: ft8_lib interop (nonisolated — off the main actor)

    /// One slot's decode plus diagnostics so the UI can show why a slot was empty.
    struct SlotResult: Sendable {
        var messages: [(text: String, snr: Int, freq: Double)] = []
        var blocks = 0        // waterfall blocks accumulated (≈156 for a full slot)
        var candidates = 0    // sync candidates found
    }

    /// Decode one slot of audio into messages (+ diagnostics).
    nonisolated static func decodeSlot(_ samples: [Float], rate: Double) -> SlotResult {
        var cfg = monitor_config_t(f_min: 100, f_max: 3600, sample_rate: Int32(rate),
                                   time_osr: 2, freq_osr: 2, protocol: FTX_PROTOCOL_FT4)
        var mon = monitor_t()
        monitor_init(&mon, &cfg)
        defer { monitor_free(&mon) }
        let block = Int(mon.block_size)
        guard block > 0 else { return SlotResult() }

        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i + block <= buf.count { monitor_process(&mon, base + i); i += block }
        }

        let maxC = 200
        var cands = [ftx_candidate_t](repeating: ftx_candidate_t(), count: maxC)
        // Lower min-score than the CLI default so marginal candidates still reach the
        // LDPC decoder (the transponder/HF path is noisier than a clean WAV).
        let n = ftx_find_candidates(&mon.wf, Int32(maxC), &cands, 8)

        var result = SlotResult(blocks: Int(mon.wf.num_blocks), candidates: Int(n))
        var seen = Set<UInt16>()
        for idx in 0..<Int(n) {
            var msg = ftx_message_t()
            var st = ftx_decode_status_t()
            let ok = ftx_decode_candidate(&mon.wf, &cands[idx], 25, &msg, &st)
            guard ok, !seen.contains(msg.hash) else { continue }
            seen.insert(msg.hash)
            var text = [CChar](repeating: 0, count: 64)
            // ftx_message_decode dereferences `offsets` unconditionally — passing
            // nil (as before) null-derefs and crashes on the first real decode.
            var offsets = ftx_message_offsets_t()
            _ = ftx_message_decode(&msg, nil, &text, &offsets)
            let s = String(cString: text)
            // ftx_decode_candidate leaves status.freq at 0 — compute the audio
            // frequency from the candidate bin: Hz = (min_bin + freq_offset +
            // freq_sub/freq_osr) / symbol_period.
            let hz = (Double(mon.min_bin) + Double(cands[idx].freq_offset)
                      + Double(cands[idx].freq_sub) / Double(max(1, mon.wf.freq_osr)))
                     / Double(mon.symbol_period)
            if !s.isEmpty { result.messages.append((s, snr(fromScore: Int(cands[idx].score)), hz)) }
        }
        return result
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
