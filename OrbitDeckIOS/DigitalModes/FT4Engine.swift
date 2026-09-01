import Foundation
import Combine
import UIKit
import Network

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

/// How far before each slot boundary the TX "pre-arm" fires: it steps the CAT dial and
/// keys PTT in the dead-air tail of the previous slot (FT4's signal occupies only 5.04 s
/// of the 7.5 s slot, so retuning ~0.5 s early lands after the signal), so the burst can
/// start right at the boundary instead of after two serial CAT round-trips. This is also
/// the maximum key-up "dead carrier" before the burst — kept short out of transponder
/// courtesy while still covering typical BLE CAT latency.
private let kFT4PreArmLead = 0.5

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

    // Audio levels (linear multipliers) applied to the shared source. Persisted so the
    // operator's setup survives relaunch.
    @Published var inputGain: Float = AudioGainStore.load("orbitdeck.ft4.inputGain") {
        didSet { source?.inputGain = inputGain; AudioGainStore.save("orbitdeck.ft4.inputGain", inputGain) }
    }
    @Published var outputGain: Float = AudioGainStore.load("orbitdeck.ft4.outputGain") {
        didSet { source?.outputGain = outputGain; AudioGainStore.save("orbitdeck.ft4.outputGain", outputGain) }
    }

    // Operator-set TX state.
    @Published var txEnabled = false
    @Published var txOnEvenSlots = true
    @Published var txMessage = ""
    @Published var txAudioFreq = 1500.0
    /// Pre-compensate the transmitted audio for the uplink Doppler drift across the burst
    /// so the emitted RF stays steady in the transponder passband (others decode you at a
    /// fixed spot instead of a smear). ON by default: while FT4 runs, `holdDoppler` freezes
    /// the CAT dial for the whole slot, so the within-burst uplink drift MUST be removed in
    /// the audio domain — without this the burst drifts ~tens of Hz and others report smear.
    /// Requires `dopplerProvider` (a configured transponder). No-op when it's unavailable.
    @Published var audioDopplerTX = true
    /// De-Doppler the whole received slot in the audio domain before decoding, using the
    /// ephemeris downlink-Doppler drift (common to every signal on the transponder). ON by
    /// default: the slot-gated CAT loop holds the dial steady within each slot and only
    /// re-tunes at boundaries, so this removes the residual within-slot drift (no double
    /// correction). Requires `dopplerProvider`. No-op when it's unavailable.
    @Published var audioDopplerRX = true { didSet { rxDeDopplerEnabled = audioDopplerRX } }

    /// Supplies instantaneous downlink/uplink Doppler SHIFT (Hz) at a given time, from
    /// the ephemeris. Set by the view at start(); used for the readout and TX pre-comp.
    var dopplerProvider: (@Sendable (Date) -> (dl: Double, ul: Double)?)?
    /// True when the uplink is keyed in LSB (inverting linear transponders). In LSB the
    /// audio→RF mapping is inverted (RF = dial − audio), so the TX Doppler pre-comp slope
    /// must flip sign — otherwise it DOUBLES the drift on an inverting bird instead of
    /// cancelling it. Set by the view from the transponder's inversion + downlink mode.
    var uplinkAudioInverted = false

    /// Opt-in PSKReporter uploader (nil = disabled). Set by the view at start() when the
    /// operator has enabled reporting and has a callsign + grid.
    var pskReporter: PSKReporter?
    /// Current absolute downlink RF base (Hz) — the Doppler-corrected downlink dial from
    /// CAT, or the transponder downlink center. A decode's reported frequency is this plus
    /// its audio offset. Called on the main actor. Returns 0 when unknown (then no spot).
    var rxBaseHzProvider: (() -> Double)?
    /// Automatic transponder calibration (opt-in). When set, each time we decode our OWN
    /// FT4 signal via full duplex the engine reports the measured downlink-frequency error
    /// (Hz) — the gap between where our signal landed and our TX audio frequency, which is
    /// the transponder's LO offset (downlink-referred). The view folds it into the
    /// per-satellite calibration. Nil = off. See `advanceCalibration`.
    var ownSignalCalibration: ((_ errHz: Double) -> Void)?

    // Nonisolated mirrors read from the slot queue (onSlotBoundary is nonisolated).
    private nonisolated(unsafe) var rxDeDopplerEnabled = false
    private nonisolated(unsafe) var dopplerProviderShared: (@Sendable (Date) -> (dl: Double, ul: Double)?)?
    private nonisolated(unsafe) let deDoppler = HilbertDeDoppler()

    /// Quietest spot in the passband (Hz), updated from the waterfall — for "clear TX".
    @Published private(set) var suggestedTxFreq: Double = 1500

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
    /// When set, the sequence completes (stops auto-TX) once the current/queued
    /// transmission finishes — used to send a single final 73 and then stop.
    private var stopAfterThisTx = false

    /// True when the connected radio can be keyed over CAT; false ⇒ VOX/manual.
    @Published private(set) var pttOverCAT = false

    private weak var rig: RigController?
    private weak var qso: QSOStore?
    private var source: AudioSource?
    private var satName = ""      // for FT4 activity-log entries

    private let slotQueue = DispatchQueue(label: "org.orbitdeck.ft4.slot")
    private nonisolated(unsafe) var slotTimer: DispatchSourceTimer?

    // TX pre-arm: fires `kFT4PreArmLead` before each boundary. For an upcoming TX slot it
    // steps the dial and keys PTT ahead of time (in the previous slot's dead-air tail) so
    // the boundary handler can start the burst immediately (dT ≈ 0) rather than after the
    // serial CAT round-trips. All arm state is main-actor-isolated (touched only from the
    // pre-arm hop and the boundary's main-actor Task).
    private nonisolated(unsafe) var preArmTimer: DispatchSourceTimer?
    private var preArmTask: Task<Void, Never>?
    private var pttArmed = false            // PTT pre-keyed for the upcoming TX slot
    private var armedSlotIndex = -1         // starting-slot index we've armed for
    private var dialSteppedForSlot = -1     // guard against double-stepping the dial

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
    private nonisolated(unsafe) var waterFloor: Float = 0          // EMA of the noise floor (dB)
    private let waterHeight = 120

    func attach(rig: RigController, qso: QSOStore) { self.rig = rig; self.qso = qso }

    // MARK: Lifecycle

    func start(source: AudioSource, myCall: String, myGrid: String, satellite: String = "") {
        guard !isRunning else { return }
        // Only one input capture at a time (FT4/SSTV/recording each open their own engine).
        guard AudioActivity.claimCapture("FT4") else {
            errorText = "Audio is in use by \(AudioActivity.captureHolder ?? "another feature"). Stop it first."
            return
        }
        errorText = ""; decodes.removeAll()
        self.source = source
        self.satName = satellite
        self.sampleRate = source.sampleRate
        rxDeDopplerEnabled = audioDopplerRX
        dopplerProviderShared = dopplerProvider
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
        } catch {
            errorText = error.localizedDescription; self.source = nil
            AudioActivity.releaseCapture("FT4")
            return
        }
        isRunning = true; status = "Listening…"
        AudioActivity.begin()
        // Slot-gate CAT Doppler while FT4 runs: hold the continuous loop and step the
        // dial once per slot boundary, so the radio never retunes mid-slot (which would
        // break the coherent decode). The within-slot drift is smooth and is removed in
        // the audio domain when RX de-Doppler is on.
        if let rig, rig.connected, rig.config.tuning.trackDoppler {
            rig.holdDoppler = true
            Task { await rig.stepDopplerNow() }
        }
        // Fresh waterfall state (safe: the analysis timer isn't running yet).
        waterMagRows.removeAll(keepingCapacity: true); waterFloor = 0
        preArmTask = nil; pttArmed = false; armedSlotIndex = -1; dialSteppedForSlot = -1
        scheduleSlotTimer()
        schedulePreArmTimer()
        scheduleAnalysisTimer()
    }

    func stop() {
        guard isRunning else { return }
        slotTimer?.cancel(); slotTimer = nil
        preArmTimer?.cancel(); preArmTimer = nil
        preArmTask?.cancel(); preArmTask = nil
        analysisTimer?.cancel(); analysisTimer = nil
        source?.stopPlayback()
        source?.stop()
        source = nil
        pskReporter?.stop(); pskReporter = nil
        // Resume continuous CAT Doppler tracking (undo the FT4 slot-gating).
        if let rig, rig.holdDoppler {
            rig.holdDoppler = false
            Task { await rig.stepDopplerNow() }
        }
        if isTransmitting || pttArmed { Task { await rig?.setPTT(false) } }
        pttArmed = false; armedSlotIndex = -1; dialSteppedForSlot = -1
        isTransmitting = false
        isRunning = false
        AudioActivity.end()
        AudioActivity.releaseCapture("FT4")
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

    /// Fires `kFT4PreArmLead` before each slot boundary so an upcoming TX slot can key up
    /// early (see `preArmUpcomingSlot`).
    private nonisolated func schedulePreArmTimer() {
        let period = kFT4SlotSeconds
        let now = Date().timeIntervalSince1970
        var delay = (floor(now / period) + 1) * period - kFT4PreArmLead - now
        while delay < 0 { delay += period }
        let t = DispatchSource.makeTimerSource(queue: slotQueue)
        t.schedule(deadline: .now() + delay, repeating: period)
        t.setEventHandler { [weak self] in Task { @MainActor in self?.preArmUpcomingSlot() } }
        t.resume()
        preArmTimer = t
    }

    /// If the slot starting at the next boundary is ours to transmit, step the CAT dial and
    /// key PTT now — during the dead-air tail of the current slot — so the burst can start
    /// at the boundary with the RF already up and settled (dT ≈ 0). Only meaningful with a
    /// slot-gated CAT radio (`holdDoppler`); without one the boundary path is already fast.
    /// The boundary handler awaits `preArmTask` before transmitting, so no retune is ever in
    /// flight while a burst is on the air.
    private func preArmUpcomingSlot() {
        guard isRunning, !isTransmitting, let rig, rig.connected, rig.holdDoppler else { return }
        guard txEnabled, !txMessage.isEmpty else { return }
        let period = kFT4SlotSeconds
        let upcoming = Int((Date().timeIntervalSince1970 / period).rounded(.down)) + 1
        guard (upcoming % 2 == 0) == txOnEvenSlots else { return }   // our TX slot?
        guard armedSlotIndex != upcoming else { return }             // already armed
        armedSlotIndex = upcoming
        let keyPTT = pttOverCAT
        preArmTask = Task { @MainActor in
            if self.dialSteppedForSlot != upcoming {
                await rig.stepDopplerNow()
                self.dialSteppedForSlot = upcoming
            }
            if keyPTT {
                await rig.setPTT(true)
                self.pttArmed = true
            }
        }
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
        var clearHz: Double?
        if win.count >= analyzer.n {
            let db = analyzer.magnitudesDB(win)
            if !db.isEmpty {
                let binHz = rate / Double(analyzer.n)
                let maxBin = max(1, min(db.count, Int(3000.0 / binHz)))
                image = appendWaterfall(Array(db[0..<maxBin]))
                clearHz = quietestFreq(db, binHz: binHz)
            }
        }
        Task { @MainActor in
            // Fast attack, slow release so the meter reads like a VU meter (no flash).
            self.rxLevel = max(peak, self.rxLevel * 0.75)
            if let image { self.waterfall = image }
            if let clearHz { self.suggestedTxFreq = clearHz }
        }
    }

    /// The center of the quietest ~150 Hz spot in the 500–2500 Hz FT4 sub-band — a good
    /// place to drop your TX so you don't sit on another signal.
    private nonisolated func quietestFreq(_ db: [Float], binHz: Double) -> Double? {
        let lo = max(1, Int(500 / binHz)), hi = min(db.count - 1, Int(2500 / binHz))
        guard hi > lo else { return nil }
        let win = max(1, Int(75 / binHz))               // ±75 Hz window
        var bestC = lo, bestSum = Float.greatestFiniteMagnitude
        var c = lo + win
        while c <= hi - win {
            var s: Float = 0; for k in (c - win)...(c + win) { s += db[k] }
            if s < bestSum { bestSum = s; bestC = c }
            c += win                                     // step by the window for speed
        }
        return Double(bestC) * binHz
    }

    /// Push a new magnitude row and render the scrolling waterfall (newest at bottom).
    private nonisolated func appendWaterfall(_ row: [Float]) -> UIImage? {
        waterMagRows.append(row)
        if waterMagRows.count > waterHeight { waterMagRows.removeFirst(waterMagRows.count - waterHeight) }
        let w = row.count, h = waterMagRows.count
        guard w > 0, h > 0 else { return nil }
        // Noise floor = a low percentile of the CURRENT spectrum (signals occupy a
        // minority of bins), EMA-smoothed. The old absolute-minimum let a single near-
        // null bin sit ~50 dB below the real floor, so the noise itself mapped to the
        // top of the palette (everything red). A percentile tracks the true floor and
        // is gain-independent (the floor rises with the signal).
        var sortedRow = row; sortedRow.sort()
        let floorNow = sortedRow[min(sortedRow.count - 1, max(0, Int(Float(sortedRow.count) * 0.4)))]
        waterFloor = waterFloor == 0 ? floorNow : waterFloor * 0.9 + floorNow * 0.1
        let lo = waterFloor
        let range: Float = 55   // dB from noise floor to white; only strong signals go red
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
        lock.lock(); var slot = rxBuffer; rxBuffer.removeAll(keepingCapacity: true); let rate = sampleRate; lock.unlock()

        let endedSlotIndex = Int((Date().timeIntervalSince1970 / kFT4SlotSeconds).rounded()) - 1

        // EXPERIMENTAL RX de-Doppler: flatten the downlink Doppler drift across this slot
        // (common to all signals on the transponder) before decoding. Sample the ephemeris
        // downlink shift at the slot's start and end for a linear drift rate; a smooth
        // audio de-chirp counters it. Gated off by default; needs on-air validation.
        if rxDeDopplerEnabled, slot.count > Int(rate * 3.0), let provider = dopplerProviderShared {
            let slotStart = Date(timeIntervalSince1970: Double(endedSlotIndex) * kFT4SlotSeconds)
            if let d0 = provider(slotStart), let d1 = provider(slotStart.addingTimeInterval(kFT4SlotSeconds)) {
                let slope = (d1.dl - d0.dl) / kFT4SlotSeconds     // Hz/s of downlink drift
                slot = deDoppler.removeLinearDrift(slot, rate: rate, slopeHzPerSec: slope)
            }
        }

        let haveAudio = slot.count > Int(rate * 3.0)
        let result = haveAudio ? FT4Engine.decodeSlot(slot, rate: rate) : FT4Engine.SlotResult()
        let found = result.messages
        let startingSlot = endedSlotIndex + 1

        Task { @MainActor in
            // Ensure any pre-arm (dial step + PTT) for this starting slot has settled, so a
            // retune is never in flight once the burst goes on the air.
            await self.preArmTask?.value
            // Slot-gated CAT Doppler: step the dial once now, at the boundary between the
            // slot that just ended and the one starting — the only moment we retune, so the
            // radio holds one frequency through each RX/TX slot. Skip it if the pre-arm
            // already stepped for this slot (a TX slot arms in the previous slot's tail).
            if let rig = self.rig, rig.holdDoppler, self.dialSteppedForSlot != startingSlot {
                self.dialSteppedForSlot = startingSlot
                await rig.stepDopplerNow()
            }

            for f in found {
                self.decodes.append(FT4DecodedMessage(text: f.text, snr: f.snr, freqHz: f.freq, atSlot: endedSlotIndex))
            }
            if self.decodes.count > 100 { self.decodes.removeFirst(self.decodes.count - 100) }
            self.advanceCalibration(found)
            // Persist the full activity log (reviewable later on the Log screen).
            if !found.isEmpty {
                let when = Date(timeIntervalSince1970: Double(endedSlotIndex) * kFT4SlotSeconds)
                self.qso?.addFT4Traffic(found.map {
                    FT4TrafficEntry(date: when, sat: self.satName, text: $0.text, snr: $0.snr, freqHz: Int($0.freq), sent: false)
                })
                // Opt-in PSKReporter spots: report each received station at its absolute
                // downlink RF (downlink dial + audio offset). Skips our own signal and
                // decodes with no known RF base.
                if let psk = self.pskReporter {
                    let base = self.rxBaseHzProvider?() ?? 0
                    if base > 0 {
                        for f in found {
                            guard let fields = FT4Engine.parse(f.text) else { continue }
                            let sender = fields.de
                            guard !sender.isEmpty, sender != self.myCallSeq else { continue }
                            let grid = FT4Engine.isGrid(fields.extra) ? fields.extra : ""
                            psk.enqueue(PSKSpot(call: sender, grid: grid,
                                                freqHz: Int64((base + f.freq).rounded()),
                                                snr: f.snr, mode: "FT4", when: when))
                        }
                        psk.flush()
                    }
                }
            }
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

            let armed = self.pttArmed
            self.pttArmed = false
            let wantTx = self.txEnabled && !self.txMessage.isEmpty
                && ((startingSlot % 2 == 0) == self.txOnEvenSlots)
            if wantTx {
                self.beginTransmit(pttAlreadyKeyed: armed)
            } else if armed {
                // Pre-armed PTT but this slot won't transmit after all — release it.
                await self.rig?.setPTT(false)
            }
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

    /// Automatic transponder calibration. On a properly-netted linear transponder your OWN
    /// signal returns at ~the audio frequency you transmit — inverting or not, because
    /// OrbitDeck sets the uplink sideband to match. So when we decode our own callsign via
    /// full duplex, the gap between the decoded audio frequency and our TX audio frequency is
    /// the residual transponder LO error (downlink-referred, after the current calibration).
    /// Report it to the sink (the view damps it into the per-satellite calibration). The RX
    /// de-Doppler anchors positions to the slot start, so it doesn't bias this measurement.
    private func advanceCalibration(_ found: [(text: String, snr: Int, freq: Double)]) {
        guard let sink = ownSignalCalibration, txEnabled else { return }
        for f in found where isFromMe(f.text) {
            let errHz = f.freq - txAudioFreq
            guard abs(errHz) < 3000 else { continue }   // reject an implausible/mis-decoded outlier
            sink(errHz)
            ODLog.shared.log(String(format: "FT4 auto-cal: own signal %.0f Hz (tx %.0f) → err %+.0f Hz",
                                    f.freq, txAudioFreq, errHz), category: "ft4")
        }
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
                // They consider the QSO complete. Log it, send ONE courtesy 73, then
                // stop — do NOT keep re-sending the report (that was the bug).
                logQSO()
                txMessage = "\(workedCall) \(myCallSeq) 73"
                seqStatus = "Logged \(workedCall) — sending 73"
                txEnabled = true
                stopAfterThisTx = true
                return
            }
            if FT4Engine.isReportToken(extra) {
                reportIn = FT4Engine.parseReport(extra)
                if extra.hasPrefix("R") {
                    // They rogered our report — send RR73 (keep sending until they
                    // acknowledge with 73/RR73, which completes above). Log now.
                    txMessage = "\(workedCall) \(myCallSeq) RR73"; seqStatus = "Sending RR73 to \(workedCall)"
                    logQSO()
                } else {
                    // They sent a report — roger it back with ours.
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
        workedCall = ""; workedGrid = ""; reportIn = nil; logged = false; stopAfterThisTx = false
        if autoSequence { seqStatus = "" }
    }

    /// Called after the final 73 finishes transmitting: the QSO is logged, so stop
    /// auto-transmitting and reset the sequence (the operator can start another).
    private func completeSequence() {
        let last = workedCall
        workedCall = ""; workedGrid = ""; reportIn = nil; logged = false; stopAfterThisTx = false
        txEnabled = false; txMessage = ""
        seqStatus = last.isEmpty ? "" : "Logged \(last) ✓"
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

    private func beginTransmit(pttAlreadyKeyed: Bool = false) {
        guard let source, !isTransmitting else { return }
        guard let tones = FT4Engine.encodeTones(txMessage) else { errorText = "Could not encode \"\(txMessage)\"."; return }
        // The slot we're transmitting on (its UTC start anchors both the Doppler slope and
        // the dT diagnostic below).
        let txSlot = Int((Date().timeIntervalSince1970 / kFT4SlotSeconds).rounded())
        let slotStart = Date(timeIntervalSince1970: Double(txSlot) * kFT4SlotSeconds)
        // Uplink-Doppler pre-compensation: `holdDoppler` freezes the CAT dial for the whole
        // slot, so we cancel the within-burst uplink drift in the audio domain — a smooth
        // chirp that keeps the emitted RF fixed in the transponder passband. Sample the
        // uplink Doppler at the slot START and one burst later for the drift rate (anchored
        // to the slot start, matching the dial that was stepped at the boundary — not the
        // late wall-clock, which would bias the burst by the launch latency). Linear over a
        // ~5 s burst is a good approximation.
        var offset: ((Double) -> Double)?
        if audioDopplerTX, let provider = dopplerProvider {
            let burst = Double(FT4_NN) * Double(FT4_SYMBOL_PERIOD)
            if let d0 = provider(slotStart), let d1 = provider(slotStart.addingTimeInterval(burst)) {
                let slope = (d1.ul - d0.ul) / burst      // Hz/s of uplink Doppler
                // USB uplink: RF = dial + audio, so cancel with -slope. LSB uplink
                // (inverting linear transponders): RF = dial - audio, so the sign flips —
                // otherwise the comp doubles the drift on the majority of linear birds.
                let sign: Double = uplinkAudioInverted ? 1.0 : -1.0
                offset = { elapsed in sign * slope * elapsed }  // cancel the drift
            }
        }
        let tx = FT4Engine.synthesize(tones: tones, rate: source.sampleRate, f0: txAudioFreq, offsetHz: offset)
        txLock.lock(); txBuffer = tx; txIndex = 0; txDone = false; txPeak = 0; txLock.unlock()
        isTransmitting = true
        status = "Transmitting: \(txMessage)"
        // Log our own transmission so it shows in the activity panel even when the
        // full-duplex receiver doesn't decode it back.
        decodes.append(FT4DecodedMessage(text: txMessage, snr: 0, freqHz: txAudioFreq, atSlot: txSlot, kind: .sent))
        if decodes.count > 100 { decodes.removeFirst(decodes.count - 100) }
        qso?.addFT4Traffic([FT4TrafficEntry(date: Date(timeIntervalSince1970: Double(txSlot) * kFT4SlotSeconds),
                                            sat: satName, text: txMessage, snr: 0, freqHz: Int(txAudioFreq), sent: true)])
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
            // PTT is already up when the slot was pre-armed; otherwise key it now.
            if !pttAlreadyKeyed { await rig?.setPTT(true) }
            // Diagnostic: how late the burst starts relative to the slot boundary. WSJT-X
            // stations see this as the decode's dT; aim for well under a few hundred ms.
            let dT = Date().timeIntervalSince1970 - Double(txSlot) * kFT4SlotSeconds
            ODLog.shared.log(String(format: "FT4 TX dT=%+.2fs%@ · \"%@\"", dT,
                                    pttAlreadyKeyed ? " (pre-armed)" : "", txMessage), category: "ft4")
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
        // If this was the final 73 of a completed QSO, stop auto-transmitting now.
        if stopAfterThisTx { completeSequence() }
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

        // Noise floor from the waterfall ft8_lib already built (computed once, reused
        // for every candidate) — no extra FFT, so measuring SNR is essentially free.
        let noiseDb = FT4Engine.waterfallNoiseFloorDb(mon.wf, minBin: Int(mon.min_bin),
                                                      symbolPeriod: Double(mon.symbol_period))

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
            if !s.isEmpty {
                let report = FT4Engine.measuredSNR(mon.wf, cands[idx], noiseFloorDb: noiseDb)
                result.messages.append((s, report, hz))
            }
        }
        return result
    }

    /// Noise floor (dB), a low percentile of the waterfall magnitudes — but computed ONLY
    /// over the SSB audio passband (~300–2700 Hz), not the full 100–3600 Hz monitor range.
    /// The filter skirts outside the passband are near-silent; including them dragged a
    /// whole-spectrum percentile ~10–20 dB below the true floor, which inflated every SNR
    /// (the "reports read high" bug). Restricting to the passband tracks the real floor, so
    /// the 2500 Hz-referenced report lands close to WSJT-X. The innermost mag dimension is
    /// the frequency bin (width `num_bins`), so `index % num_bins` recovers the bin.
    private nonisolated static func waterfallNoiseFloorDb(_ wf: ftx_waterfall_t, minBin: Int, symbolPeriod: Double) -> Float {
        guard let mag = wf.mag, wf.num_blocks > 0, wf.block_stride > 0, wf.num_bins > 0, symbolPeriod > 0 else { return -110 }
        let numBins = Int(wf.num_bins)
        let total = Int(wf.num_blocks) * Int(wf.block_stride)
        // bin = freq·symbolPeriod − minBin (inverse of the decode's freq formula).
        let kLo = max(0, Int(300.0 * symbolPeriod) - minBin)
        let kHi = min(numBins - 1, Int(2700.0 * symbolPeriod) - minBin)
        var hist = [Int](repeating: 0, count: 256)
        var counted = 0
        if kHi > kLo {
            var i = 0
            while i < total {
                let bin = i % numBins
                if bin >= kLo && bin <= kHi { hist[Int(mag[i])] += 1; counted += 1 }
                i += 1
            }
        }
        // Fallback to the whole array if the band came out empty (unexpected geometry).
        if counted == 0 { for i in 0..<total { hist[Int(mag[i])] += 1 }; counted = total }
        let target = Int(Double(counted) * 0.30)
        var cum = 0, floorByte = 0
        for v in 0..<256 { cum += hist[v]; if cum >= target { floorByte = v; break } }
        return Float(floorByte) * 0.5 - 120.0        // ft8_lib byte → dB
    }

    /// Real per-candidate SNR from the existing waterfall (no extra FFT): the median
    /// over symbols of the strongest tone-bin magnitude near the candidate, minus the
    /// noise floor, referenced to the standard 2500 Hz noise bandwidth. Gives proper
    /// +/- reports instead of the old sync-score heuristic.
    private nonisolated static func measuredSNR(_ wf: ftx_waterfall_t, _ cand: ftx_candidate_t, noiseFloorDb: Float) -> Int {
        guard let mag = wf.mag else { return 0 }
        let nb = Int(wf.num_blocks), bins = Int(wf.num_bins), stride = Int(wf.block_stride)
        let fsub = Int(cand.freq_sub), foff = Int(cand.freq_offset)
        let lo = max(0, foff - 1), hi = min(bins - 1, foff + 7)   // spans FT4's 4 tones
        guard nb > 0, hi >= lo else { return 0 }
        var sig = [Float](); sig.reserveCapacity(nb)
        for b in 0..<nb {
            let base = b * stride + fsub * bins                    // time_sub 0
            var m: UInt8 = 0
            var bin = lo
            while bin <= hi { let v = mag[base + bin]; if v > m { m = v }; bin += 1 }
            sig.append(Float(m) * 0.5 - 120.0)
        }
        sig.sort()
        let sigDb = sig[sig.count / 2]
        // Bin BW ≈ 1/(symbol_period·freq_osr) ≈ 10.4 Hz for FT4 → 10·log10(2500/10.4) ≈ 24 dB.
        return max(-24, min(30, Int((sigDb - noiseFloorDb - 24.0).rounded())))
    }

    /// Approximate signal report (dB) from a candidate's sync score. ft8_lib does
    /// not expose a calibrated SNR, so this is a rough, clamped estimate that stands
    /// in for the report we send. Recalibrated upward (the old mapping read ~10 dB
    /// low versus on-air signals); still approximate — refine against known signals.
    nonisolated static func snr(fromScore s: Int) -> Int { max(-24, min(24, s / 7 - 12)) }

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
    /// `offsetHz` (optional) returns an audio-frequency offset (Hz) as a function of
    /// elapsed seconds into the burst — used to pre-compensate uplink Doppler drift so
    /// the emitted RF stays constant across the transmission.
    nonisolated static func synthesize(tones: [UInt8], rate: Double, f0: Double,
                                       offsetHz: ((Double) -> Double)? = nil) -> [Float] {
        let symbolPeriod = Double(FT4_SYMBOL_PERIOD)
        let sps = max(1, Int(rate * symbolPeriod))
        let toneSpacing = 1.0 / symbolPeriod
        var out = [Float](); out.reserveCapacity(sps * tones.count)
        var phase = 0.0
        for (i, t) in tones.enumerated() {
            let f = f0 + Double(t) * toneSpacing + (offsetHz?(Double(i) * symbolPeriod) ?? 0)
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

// ===========================================================================
//  PSKReporter — reception-report upload (opt-in)
//
//  Sends FT4 reception reports (spots) to PSKReporter over UDP using its IPFIX wire
//  format, byte-compatible with WSJT-X's implementation. Each datagram carries the
//  receiver (options) template + the sender template + one receiver-info record + a
//  batch of sender spots. Templates are included in every datagram so the message is
//  self-contained (PSKReporter tolerates repeated templates).
//
//  Reporting is OPT-IN (Settings → PSKReporter). We only upload when the operator has
//  turned it on and set their callsign + grid. The reported frequency is the absolute
//  downlink RF (Doppler-corrected downlink dial from CAT, or the transponder downlink
//  center) plus the decode's audio offset.
//
//  Wire format reference: pskreporter.info/pskdev.html and WSJT-X Network/PSKReporter.cpp.
// ===========================================================================

/// Settings keys for PSKReporter (opt-in).
enum PSKReporterSettings {
    static let enabledKey = "orbitdeck.pskreporter.enabled"
}

/// FT4 settings.
enum FT4Settings {
    /// Command the rig's DATA sub-mode (USB-D/LSB-D) while FT4 runs so audio uses the
    /// ACC/USB data port. Default on; operators feeding audio via the mic/headphone jack
    /// can turn it off. Only affects data-capable CI-V rigs.
    static let dataModeKey = "orbitdeck.ft4.dataMode"
    /// Automatically refine the per-satellite transponder calibration from our own decoded
    /// FT4 signal (full duplex). Opt-in — it edits the saved calibration for the satellite.
    static let autoCalibrateKey = "orbitdeck.ft4.autoCalibrate"
}

/// One reception report.
struct PSKSpot {
    let call: String        // decoded sender callsign (their DE)
    let grid: String        // their grid, if the message carried one ("" otherwise)
    let freqHz: Int64       // absolute RF of the received signal (downlink RF + audio offset)
    let snr: Int            // measured SNR (dB)
    let mode: String        // "FT4"
    let when: Date          // slot start (UTC)
}

@MainActor
final class PSKReporter {
    static let host = "report.pskreporter.info"
    static let port: UInt16 = 4739
    private static let enterprise: UInt32 = 30351   // PSKReporter IANA enterprise number

    private let receiverCall: String
    private let receiverGrid: String
    private let software: String
    private let antenna: String

    private var queued: [PSKSpot] = []
    private var sequence: UInt32 = 0
    private let observationID: UInt32

    /// True only when we have the minimum required receiver identity.
    var isConfigured: Bool { !receiverCall.isEmpty && !receiverGrid.isEmpty }

    init(receiverCall: String, receiverGrid: String, software: String, antenna: String = "") {
        self.receiverCall = receiverCall.uppercased()
        self.receiverGrid = receiverGrid
        self.software = software
        self.antenna = antenna
        self.observationID = UInt32.random(in: 1...UInt32.max)
    }

    /// Queue a spot for the next flush. Ignores empty/own calls and unknown frequency.
    func enqueue(_ spot: PSKSpot) {
        guard isConfigured, !spot.call.isEmpty, spot.freqHz > 0 else { return }
        queued.append(spot)
    }

    /// Build one datagram from the queued spots and send it, then clear the queue.
    func flush() {
        guard isConfigured, !queued.isEmpty else { return }
        let spots = queued
        queued.removeAll(keepingCapacity: true)
        sequence &+= 1
        let datagram = buildDatagram(spots: spots, sequence: sequence)
        ODLog.shared.log("pskreporter: sending \(spots.count) spot(s), \(datagram.count) bytes", category: "psk")
        send(datagram)
    }

    /// Flush anything remaining (call when FT4 stops).
    func stop() { flush() }

    // MARK: Datagram assembly

    private func buildDatagram(spots: [PSKSpot], sequence: UInt32) -> Data {
        var body = [UInt8]()
        body.append(contentsOf: receiverTemplate())
        body.append(contentsOf: senderTemplate())
        body.append(contentsOf: receiverDataSet())
        body.append(contentsOf: senderDataSet(spots))

        // 16-byte IPFIX message header, with the total length back-patched.
        var msg = [UInt8]()
        appendU16(&msg, 0x000A)                       // version
        appendU16(&msg, 0)                            // length placeholder
        appendU32(&msg, UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))  // export time
        appendU32(&msg, sequence)                     // sequence number
        appendU32(&msg, observationID)                // random observation domain id
        msg.append(contentsOf: body)
        let total = UInt16(truncatingIfNeeded: msg.count)
        msg[2] = UInt8(total >> 8); msg[3] = UInt8(total & 0xFF)
        return Data(msg)
    }

    /// Receiver (options) template: set id 3, template 0x50E2, 4 enterprise fields.
    private func receiverTemplate() -> [UInt8] {
        var s = [UInt8]()
        appendU16(&s, 0x0003)          // options template set id
        appendU16(&s, 0)               // length placeholder
        appendU16(&s, 0x50E2)          // template id
        appendU16(&s, 4)               // field count
        appendU16(&s, 0)               // scope field count
        appendField(&s, 0x8002, 0xFFFF)   // receiverCallsign (variable)
        appendField(&s, 0x8004, 0xFFFF)   // receiverLocator
        appendField(&s, 0x8008, 0xFFFF)   // decodingSoftware
        appendField(&s, 0x8009, 0xFFFF)   // antennaInformation
        return finalizeSet(&s)
    }

    /// Sender template: set id 2, template 0x50E3, 7 fields.
    private func senderTemplate() -> [UInt8] {
        var s = [UInt8]()
        appendU16(&s, 0x0002)          // template set id
        appendU16(&s, 0)               // length placeholder
        appendU16(&s, 0x50E3)          // template id
        appendU16(&s, 7)               // field count
        appendField(&s, 0x8001, 0xFFFF)   // senderCallsign (variable)
        appendField(&s, 0x8005, 5)        // frequency, 5 bytes
        appendField(&s, 0x8006, 1)        // sNR, 1 byte
        appendField(&s, 0x800A, 0xFFFF)   // mode (variable)
        appendField(&s, 0x8003, 0xFFFF)   // senderLocator (variable)
        appendField(&s, 0x800B, 1)        // informationSource, 1 byte
        appendU16(&s, 150)                // dateTimeSeconds (standard element)
        appendU16(&s, 4)                  //   length 4
        return finalizeSet(&s)
    }

    private func receiverDataSet() -> [UInt8] {
        var s = [UInt8]()
        appendU16(&s, 0x50E2)          // set id = receiver template id
        appendU16(&s, 0)               // length placeholder
        appendString(&s, receiverCall)
        appendString(&s, receiverGrid)
        appendString(&s, software)
        appendString(&s, antenna)
        return finalizeSet(&s)
    }

    private func senderDataSet(_ spots: [PSKSpot]) -> [UInt8] {
        var s = [UInt8]()
        appendU16(&s, 0x50E3)          // set id = sender template id
        appendU16(&s, 0)               // length placeholder
        for spot in spots {
            appendString(&s, spot.call)
            appendU40(&s, UInt64(max(0, spot.freqHz)))
            s.append(UInt8(bitPattern: Int8(clamping: spot.snr)))
            appendString(&s, spot.mode)
            appendString(&s, spot.grid)
            s.append(1)                // informationSource = 1 (automatically extracted)
            appendU32(&s, UInt32(truncatingIfNeeded: Int(spot.when.timeIntervalSince1970)))
        }
        return finalizeSet(&s)
    }

    // MARK: byte helpers

    private func appendU16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v >> 8)); b.append(UInt8(v & 0xFF))
    }
    private func appendU32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8((v >> 24) & 0xFF)); b.append(UInt8((v >> 16) & 0xFF))
        b.append(UInt8((v >> 8) & 0xFF)); b.append(UInt8(v & 0xFF))
    }
    /// 5-byte big-endian (the PSKReporter frequency field width).
    private func appendU40(_ b: inout [UInt8], _ v: UInt64) {
        b.append(UInt8((v >> 32) & 0xFF)); b.append(UInt8((v >> 24) & 0xFF))
        b.append(UInt8((v >> 16) & 0xFF)); b.append(UInt8((v >> 8) & 0xFF)); b.append(UInt8(v & 0xFF))
    }
    /// IPFIX enterprise field specifier: id (enterprise bit already set) + length + enterprise number.
    private func appendField(_ b: inout [UInt8], _ id: UInt16, _ length: UInt16) {
        appendU16(&b, id); appendU16(&b, length); appendU32(&b, Self.enterprise)
    }
    /// Length-prefixed UTF-8 string (1-byte length, max 254 bytes).
    private func appendString(_ b: inout [UInt8], _ s: String) {
        let bytes = Array(s.utf8.prefix(254))
        b.append(UInt8(bytes.count))
        b.append(contentsOf: bytes)
    }
    /// Back-patch the set's length field and pad the set to a 4-byte boundary
    /// (padding is counted in the length, per IPFIX).
    private func finalizeSet(_ s: inout [UInt8]) -> [UInt8] {
        let pad = (4 - s.count % 4) % 4
        for _ in 0..<pad { s.append(0) }
        let len = UInt16(truncatingIfNeeded: s.count)
        s[2] = UInt8(len >> 8); s[3] = UInt8(len & 0xFF)
        return s
    }

    // MARK: UDP send

    private func send(_ data: Data) {
        let conn = NWConnection(host: NWEndpoint.Host(Self.host),
                                port: NWEndpoint.Port(rawValue: Self.port)!,
                                using: .udp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: data, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .utility))
    }
}
