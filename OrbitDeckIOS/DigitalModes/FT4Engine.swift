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

/// How far into a slot a TX request for that slot's parity still starts transmitting in
/// the same slot (late start), rather than waiting for the next matching slot. The
/// elapsed part of the burst is skipped so the remaining symbols stay on the slot clock.
private let kFT4LateStartWindow = 2.0

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

    // Operator-set TX state. Any change re-checks for a late start in the current slot
    // (see `requestLateStart`) or swaps the message of a burst that just began.
    @Published var txEnabled = false { didSet { if txEnabled != oldValue { requestLateStart() } } }
    @Published var txOnEvenSlots = true { didSet { if txOnEvenSlots != oldValue { requestLateStart() } } }
    @Published var txMessage = "" { didSet { if txMessage != oldValue { requestLateStart() } } }

    /// Wait-and-pounce: callsigns and/or grids (space- or comma-separated). When a CQ from
    /// a target call (or from a station in a target grid), or a message to me from a
    /// target call, is decoded while idle, the engine works it automatically. Persisted.
    @Published var pounceTargets = UserDefaults.standard.string(forKey: FT4Settings.pounceTargetsKey) ?? "" {
        didSet { UserDefaults.standard.set(pounceTargets, forKey: FT4Settings.pounceTargetsKey) }
    }
    /// Armed state is deliberately not persisted (the targets are): a session started
    /// later just to monitor must never transmit on its own.
    @Published var pounceEnabled = false {
        didSet { if pounceEnabled != oldValue { ODLog.shared.log("FT4 pounce \(pounceEnabled ? "armed" : "off")", category: "ft4") } }
    }
    /// Callsigns never auto-answered while calling CQ (a manual tap still works them).
    /// Persisted.
    @Published var cqBlockList: [String] = UserDefaults.standard.stringArray(forKey: FT4Settings.cqBlockListKey) ?? [] {
        didSet { UserDefaults.standard.set(cqBlockList, forKey: FT4Settings.cqBlockListKey) }
    }
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
    /// canceling it. Set by the view from the transponder's inversion + downlink mode.
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
    private var dialStepTask: Task<Void, Never>?   // the boundary's in-flight dial step

    // Late start / in-burst message switch (see `requestLateStart`).
    private var lateStartPending = false    // a re-check is already queued
    private var txSlotIndex = -1            // slot the current burst belongs to
    private var txOnAirMessage = ""         // message the current burst is sending

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
        rxDeDopplerEnabled = audioDopplerRX
        dopplerProviderShared = dopplerProvider
        lock.lock(); rxBuffer.removeAll(keepingCapacity: true); lock.unlock()
        myCallSeq = myCall.uppercased()
        // Only a valid locator goes on the air; anything else counts as missing.
        let grid4 = String(myGrid.prefix(4)).uppercased()
        myGridSeq = FT4Engine.isGrid(grid4) ? grid4 : ""
        endSequence()
        if txMessage.isEmpty, !myCallSeq.isEmpty {
            txMessage = myGridSeq.isEmpty ? "CQ \(myCallSeq)" : "CQ \(myCallSeq) \(myGridSeq)"
        }
        // Hashed-callsign memory: our own call plus recent log calls resolve `<...>`.
        FT4CallsignHashes.shared.preload(myCall: myCallSeq, logCalls: (qso?.qsos ?? []).prefix(200).map(\.call))
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
        // Read the sample rate AFTER start(): the shared-hub AudioSubscription only learns
        // the real capture rate once it attaches (it defaults to 48 kHz beforehand). Reading
        // it too early pinned network audio (16 kHz) at 48 kHz — which pushed the per-slot
        // "have audio" threshold above a full 16 kHz slot ("No RX audio this slot") and fed
        // the decoder the wrong rate. USB is genuinely 48 kHz, so only network audio broke.
        self.sampleRate = source.sampleRate
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
        dialStepTask = nil; txSlotIndex = -1; txOnAirMessage = ""
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
                // Refused (e.g. a receive-only transponder): not armed, so the boundary
                // path tries again and aborts the burst with the reason.
                self.pttArmed = await rig.setPTT(true)
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
                // Kept as a task so a late start in this slot can wait for it to land.
                let step = Task { @MainActor in await rig.stepDopplerNow() }
                self.dialStepTask = step
                await step.value
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

            // Pounce (if armed and idle) engages a target first; then the auto-sequencer
            // updates txMessage/txEnabled before the TX decision.
            self.pounceIfMatched(found, endedSlot: endedSlotIndex)
            if self.autoSequence { self.advance(found, endedSlot: endedSlotIndex) }

            let armed = self.pttArmed
            self.pttArmed = false
            let wantTx = self.txEnabled && !self.txMessage.isEmpty
                && ((startingSlot % 2 == 0) == self.txOnEvenSlots)
            if wantTx {
                self.beginTransmit(slot: startingSlot, pttAlreadyKeyed: armed)
            } else if armed {
                // Pre-armed PTT but this slot won't transmit after all — release it.
                await self.rig?.setPTT(false)
            }
        }
    }

    // MARK: Auto-sequencer

    /// Message field parse. `isCQ` messages carry the caller in `de` (and an optional CQ
    /// modifier such as DX / POTA / TEST / a 3-digit frequency). Directed messages are
    /// `<to> <de> [extra]`; a bare `<call> <grid>` (a station announcing itself without CQ)
    /// has an empty `to`. Resolved hashed calls (`<PJ4/K1ABC>`) are unbracketed; an
    /// unresolved hash stays `<...>`. `extra` is a grid, report, RR73/RRR/73, or "".
    struct FT4Fields {
        let isCQ: Bool; let to: String; let de: String; let extra: String
        var cqModifier = ""
        /// A general call (CQ, or `<call> <grid>` with no addressee) — what pounce answers.
        var isGeneralCall: Bool { isCQ || (to.isEmpty && !de.isEmpty) }
    }

    nonisolated static func parse(_ text: String) -> FT4Fields? {
        let t = text.split(whereSeparator: { $0 == " " }).map { normalizeCallToken($0.uppercased()) }
        guard !t.isEmpty else { return nil }
        if t[0] == "CQ" {
            // CQ [modifier] <call> [grid]. A modifier is a letters-only word (DX, POTA,
            // TEST, NA, EU…) or a 1–3 digit number (CQ 123). Neither can be a callsign —
            // every callsign carries a digit and a letter — so a real call never gets
            // mistaken for one.
            var i = 1
            var modifier = ""
            if t.count > 1, isCQModifier(t[1]) { modifier = t[1]; i = 2 }
            let call = t.count > i && isCallToken(t[i]) ? t[i] : ""
            let rest = Array(t.dropFirst(i + 1))
            return FT4Fields(isCQ: true, to: "", de: call, extra: extraField(rest), cqModifier: modifier)
        }
        if t[0] == "DE", t.count > 1, isCallToken(t[1]) {
            // DE <call> [grid] — a self-announcement.
            return FT4Fields(isCQ: false, to: "", de: t[1], extra: extraField(Array(t.dropFirst(2))))
        }
        guard isCallToken(t[0]) else { return nil }                  // free text / telemetry
        if t.count == 1 { return FT4Fields(isCQ: false, to: t[0], de: "", extra: "") }
        if isCallToken(t[1]) {
            return FT4Fields(isCQ: false, to: t[0], de: t[1], extra: extraField(Array(t.dropFirst(2))))
        }
        // `<call> <grid>`: the call is the SENDER (no addressee). Anything else after a
        // lone call (a report or RR73 with no sender) is addressed to that call.
        if isGrid(t[1]) { return FT4Fields(isCQ: false, to: "", de: t[0], extra: t[1]) }
        return FT4Fields(isCQ: false, to: t[0], de: "", extra: extraField(Array(t.dropFirst(1))))
    }

    /// The meaningful trailing field: a grid, report, or sign-off token. A roger-grid
    /// (`R FN42`, EU VHF style) yields the grid.
    private nonisolated static func extraField(_ rest: [String]) -> String {
        guard let first = rest.first else { return "" }
        if first == "R", rest.count > 1, isGrid(rest[1]) { return rest[1] }
        return first
    }

    /// Strip the brackets ft8_lib puts around a call resolved from its hash (`<K1ABC>` →
    /// `K1ABC`); an unresolved `<...>` is kept as is.
    nonisolated static func normalizeCallToken(_ s: String) -> String {
        guard s.count > 2, s.hasPrefix("<"), s.hasSuffix(">"), s != "<...>" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// A CQ modifier: letters only (DX, POTA, TEST, NA, EU…) or a 1–3 digit number.
    nonisolated static func isCQModifier(_ s: String) -> Bool {
        guard !s.isEmpty, s != "<...>" else { return false }
        if s.allSatisfy({ $0.isASCII && $0.isLetter }) { return true }
        return s.count <= 3 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Callsign-shaped token: a standard or compound call (`K1ABC`, `K1ABC/P`, `SM/R1CR`,
    /// `PJ4/K1ABC`) or an unresolved hash `<...>`. Needs at least one letter and one digit,
    /// only A–Z / 0–9 / `/`, and is never a grid, report, or sign-off token.
    nonisolated static func isCallToken(_ s: String) -> Bool {
        if s == "<...>" { return true }
        guard (3...11).contains(s.count), !s.hasPrefix("/"), !s.hasSuffix("/"), !s.contains("//") else { return false }
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") }) else { return false }
        guard s.contains(where: { $0.isLetter }), s.contains(where: { $0.isNumber }) else { return false }
        return !isGrid(s) && !isReportToken(s) && !isSignoffToken(s)
    }

    /// RR73 / RRR / 73.
    nonisolated static func isSignoffToken(_ s: String) -> Bool { s == "RR73" || s == "RRR" || s == "73" }

    /// Begin calling CQ (auto-seq will engage the first station that answers).
    func callCQ() {
        guard !myCallSeq.isEmpty else { errorText = "Set your callsign in Log settings first."; return }
        workedCall = ""; workedGrid = ""; reportIn = nil; logged = false
        txMessage = myGridSeq.isEmpty ? "CQ \(myCallSeq)" : "CQ \(myCallSeq) \(myGridSeq)"
        autoSequence = true; txEnabled = true
        // Never send a grid-less CQ silently: the Next-TX panel says so (and the card
        // shows a persistent missing-grid warning).
        seqStatus = myGridSeq.isEmpty ? "Calling CQ without a grid" : "Calling CQ"
    }

    /// Whether the session's locator is missing (CQ/replies go out without a grid).
    var gridMissing: Bool { myGridSeq.isEmpty }

    /// Start working a decoded station (tap any decode). Answers a CQ, or calls a
    /// station heard in a directed message; the auto-sequencer takes it from there.
    func work(_ d: FT4DecodedMessage) {
        guard let f = FT4Engine.parse(d.text), !myCallSeq.isEmpty else { return }
        // The other station: the caller of a CQ / `<call> <grid>`; in a directed message
        // the sender — unless that's us (our own echo), then the addressee.
        let their: String
        if f.isGeneralCall { their = f.de }
        else if !f.de.isEmpty && f.de != myCallSeq { their = f.de }
        else { their = f.to }
        // Can't call ourselves, or a hashed call we never resolved.
        guard !their.isEmpty, their != myCallSeq, their != "<...>" else { return }
        workedCall = their; workedGrid = FT4Engine.isGrid(f.extra) ? f.extra : ""; reportIn = nil; logged = false
        stopAfterThisTx = false
        reportOut = d.snr        // our report to them = their decoded SNR
        let mine = myGridSeq.isEmpty ? FT4Engine.reportString(reportOut) : myGridSeq
        txMessage = "\(their) \(myCallSeq) \(mine)"
        autoSequence = true
        txOnEvenSlots = (d.atSlot % 2 != 0)     // transmit opposite to their slot
        txEnabled = true                        // last: may late-start this slot
        seqStatus = "Working \(their)"
    }

    // MARK: Wait-and-pounce + CQ block list

    /// The pounce targets as normalized tokens (callsigns and/or grids).
    var pounceTokens: [String] { FT4Engine.listTokens(pounceTargets) }

    nonisolated static func listTokens(_ s: String) -> [String] {
        s.uppercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "\n" })
            .map(String.init).filter { !$0.isEmpty }
    }

    /// Whether `call` matches a target callsign, ignoring a compound prefix/suffix
    /// (target `K1ABC` matches `K1ABC/P` and `PJ4/K1ABC`).
    nonisolated static func callMatches(_ call: String, _ target: String) -> Bool {
        let c = call.uppercased(), t = target.uppercased()
        guard !c.isEmpty, !t.isEmpty, c != "<...>" else { return false }
        return c == t || c.split(separator: "/").contains { String($0) == t }
    }

    /// Does this decode match a pounce target? A CQ (or `<call> <grid>`) from a target
    /// call or from a station in a target grid, or any message to me from a target call.
    nonisolated static func pounceMatches(_ f: FT4Fields, targets: [String], myCall: String) -> Bool {
        for target in targets {
            if isGrid(target) {
                guard f.isGeneralCall, isGrid(f.extra) else { continue }
                let g = f.extra.uppercased()
                if g.hasPrefix(target) || target.hasPrefix(g) { return true }
            } else if callMatches(f.de, target) {
                if f.isGeneralCall || (!myCall.isEmpty && f.to == myCall) { return true }
            }
        }
        return false
    }

    /// Pounce: while idle (not mid-QSO), automatically work the first decode this slot
    /// that matches a target. Fires once, then turns itself off so a completed QSO isn't
    /// repeated on the station's next CQ.
    private func pounceIfMatched(_ found: [(text: String, snr: Int, freq: Double)], endedSlot: Int) {
        // Idle only: no QSO in progress and no manual (non-sequenced) transmission running.
        guard pounceEnabled, workedCall.isEmpty, !myCallSeq.isEmpty,
              !(txEnabled && !autoSequence) else { return }
        let targets = pounceTokens
        guard !targets.isEmpty else { return }
        for d in found {
            guard let f = FT4Engine.parse(d.text), f.de != myCallSeq,
                  FT4Engine.pounceMatches(f, targets: targets, myCall: myCallSeq) else { continue }
            let msg = FT4DecodedMessage(text: d.text, snr: d.snr, freqHz: d.freq, atSlot: endedSlot)
            work(msg)
            guard !workedCall.isEmpty else { continue }
            pounceEnabled = false
            seqStatus = "Pounced on \(workedCall)"
            ODLog.shared.log("FT4 pounce: \(d.text)", category: "ft4")
            return
        }
    }

    /// Whether a call is on the CQ block list (never auto-answered while calling CQ).
    func isBlocked(_ call: String) -> Bool {
        cqBlockList.contains { FT4Engine.callMatches(call, $0) }
    }

    func block(_ call: String) {
        let c = FT4Engine.normalizeCallToken(call.uppercased())
        guard FT4Engine.isCallToken(c), c != "<...>", !cqBlockList.contains(c) else { return }
        cqBlockList.append(c)
    }

    /// Remove every block-list entry that covers `call` (exact, or its base call).
    func unblock(_ call: String) { cqBlockList.removeAll { FT4Engine.callMatches(call, $0) || $0 == call.uppercased() } }

    /// Set a single pounce target from a decode (context menu) and arm pounce.
    func pounce(on d: FT4DecodedMessage) {
        guard let f = FT4Engine.parse(d.text) else { return }
        let call = (!f.de.isEmpty && f.de != myCallSeq) ? f.de : f.to
        guard FT4Engine.isCallToken(call), call != "<...>", call != myCallSeq else { return }
        pounceTargets = call
        pounceEnabled = true
    }

    /// The other station in a decode (for the context-menu labels), or nil.
    func otherStation(_ d: FT4DecodedMessage) -> String? {
        guard let f = FT4Engine.parse(d.text) else { return nil }
        let call = (!f.de.isEmpty && f.de != myCallSeq) ? f.de : f.to
        return (FT4Engine.isCallToken(call) && call != "<...>" && call != myCallSeq) ? call : nil
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
            guard let f = FT4Engine.parse(d.text), !f.isCQ, f.to == myCallSeq,
                  !f.de.isEmpty, f.de != "<...>" else { continue }
            if workedCall.isEmpty {
                // Calling CQ: engage the first answering station — unless it's on the
                // block list (a manual tap on its decode still works it).
                if isBlocked(f.de) { continue }
                workedCall = f.de; txOnEvenSlots = (endedSlot % 2 != 0); reportOut = d.snr
            }
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

    nonisolated static func reportString(_ r: Int) -> String { String(format: "%+03d", r) }
    nonisolated static func parseReport(_ s: String) -> Int? { Int(s.hasPrefix("R") ? String(s.dropFirst()) : s) }
    /// A signal report: `-10`, `+05`, or a roger report `R-10` / `R+05`.
    nonisolated static func isReportToken(_ s: String) -> Bool {
        var t = s; if t.hasPrefix("R") { t.removeFirst() }
        guard t.count >= 2, t.hasPrefix("+") || t.hasPrefix("-") else { return false }
        return t.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
    /// A 4- or 6-character Maidenhead locator (`FN42`, `FN42ab`). `RR73` matches the
    /// pattern but is the sign-off token in FT4/FT8, so it's never a grid.
    nonisolated static func isGrid(_ s: String) -> Bool {
        let c = Array(s.uppercased())
        guard c.count == 4 || c.count == 6, s.uppercased() != "RR73" else { return false }
        func inRange(_ ch: Character, _ lo: Character, _ hi: Character) -> Bool { ch >= lo && ch <= hi }
        guard inRange(c[0], "A", "R"), inRange(c[1], "A", "R"),
              inRange(c[2], "0", "9"), inRange(c[3], "0", "9") else { return false }
        return c.count == 4 || (inRange(c[4], "A", "X") && inRange(c[5], "A", "X"))
    }

    // MARK: Transmit

    /// Late start: TX requested (tap a decode, Call CQ, Enable TX, or an edited message) for
    /// the CURRENT slot's parity within the first `kFT4LateStartWindow` s of the slot goes
    /// out now instead of waiting a full slot pair. If a burst for this slot is already on
    /// the air and the message changed inside the window, the burst switches to the new
    /// message. Coalesced: the re-check runs once after the current main-actor turn, so
    /// several property changes (as `work()` makes) trigger one decision.
    private func requestLateStart() {
        guard isRunning, !lateStartPending else { return }
        lateStartPending = true
        Task { @MainActor in
            self.lateStartPending = false
            await self.lateStartIfWanted()
        }
    }

    /// The current slot index and seconds into it, if it's our TX parity and still inside
    /// the late-start window.
    private func lateStartSlot() -> Int? {
        let now = Date().timeIntervalSince1970
        let slot = Int((now / kFT4SlotSeconds).rounded(.down))
        let into = now - Double(slot) * kFT4SlotSeconds
        guard into <= kFT4LateStartWindow, (slot % 2 == 0) == txOnEvenSlots else { return nil }
        return slot
    }

    private func lateStartIfWanted() async {
        guard isRunning, txEnabled, !txMessage.isEmpty, let slot = lateStartSlot() else { return }
        if isTransmitting {
            if txSlotIndex == slot, txMessage != txOnAirMessage { switchTransmitMessage(slot: slot) }
            return
        }
        // Usual ordering: let any pre-arm / boundary dial step land, step the dial for this
        // slot if nothing has yet, THEN key PTT and play — never retune on the air.
        await preArmTask?.value
        await dialStepTask?.value
        func stillWanted() -> Bool {
            isRunning && !isTransmitting && txEnabled && !txMessage.isEmpty && lateStartSlot() == slot
        }
        guard stillWanted() else { return }
        if let rig, rig.holdDoppler, dialSteppedForSlot != slot {
            dialSteppedForSlot = slot
            let step = Task { @MainActor in await rig.stepDopplerNow() }
            dialStepTask = step
            await step.value
            guard stillWanted() else { return }
        }
        // A pre-arm for this slot (TX was already due) has PTT up — hand it over.
        let armed = pttArmed && armedSlotIndex == slot
        if armed { pttArmed = false }
        ODLog.shared.log("FT4 late start in slot \(slot)", category: "ft4")
        beginTransmit(slot: slot, pttAlreadyKeyed: armed, lateStart: true)
    }

    /// Swap the on-air burst to the current `txMessage`, keeping the play position: both
    /// waveforms are laid on the same slot timeline, so the remaining symbols stay aligned.
    private func switchTransmitMessage(slot: Int) {
        guard let source else { return }
        guard let tones = FT4Engine.encodeTones(txMessage) else { errorText = "Could not encode \"\(txMessage)\"."; return }
        let tx = makeTXWaveform(tones: tones, slot: slot, rate: source.sampleRate)
        let swapped = txLock.withLock { () -> Bool in
            guard !txDone, tx.count == txBuffer.count else { return false }
            txBuffer = tx
            return true
        }
        guard swapped else { return }
        txOnAirMessage = txMessage
        status = "Transmitting: \(txMessage)"
        if let i = decodes.lastIndex(where: { $0.kind == .sent && $0.atSlot == slot }) {
            decodes[i] = FT4DecodedMessage(text: txMessage, snr: 0, freqHz: txAudioFreq, atSlot: slot, kind: .sent)
        }
        qso?.addFT4Traffic([FT4TrafficEntry(date: Date(timeIntervalSince1970: Double(slot) * kFT4SlotSeconds),
                                            sat: satName, text: txMessage, snr: 0, freqHz: Int(txAudioFreq), sent: true)])
        ODLog.shared.log("FT4 TX switched mid-window → \"\(txMessage)\"", category: "ft4")
    }

    /// Synthesize the burst for `slot`, with the uplink-Doppler pre-compensation.
    private func makeTXWaveform(tones: [UInt8], slot: Int, rate: Double) -> [Float] {
        let slotStart = Date(timeIntervalSince1970: Double(slot) * kFT4SlotSeconds)
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
        return FT4Engine.synthesize(tones: tones, rate: rate, f0: txAudioFreq, offsetHz: offset)
    }

    /// Start the burst for `slot`. `lateStart` plays from the slot clock's current offset
    /// (the elapsed part of the waveform is skipped) so the symbols land where the other
    /// stations' decoders expect them; otherwise the burst plays from its start.
    private func beginTransmit(slot txSlot: Int, pttAlreadyKeyed: Bool = false, lateStart: Bool = false) {
        guard let source, !isTransmitting else { return }
        // No uplink on the tracked transponder: don't key, and don't play TX audio either
        // (a radio on VOX would transmit it on the downlink).
        if let why = rig?.pttBlockedReason {
            errorText = why
            if pttAlreadyKeyed { Task { await rig?.setPTT(false) } }
            return
        }
        guard let tones = FT4Engine.encodeTones(txMessage) else { errorText = "Could not encode \"\(txMessage)\"."; return }
        let rate = source.sampleRate
        let tx = makeTXWaveform(tones: tones, slot: txSlot, rate: rate)
        txLock.lock(); txBuffer = tx; txIndex = 0; txDone = false; txPeak = 0; txLock.unlock()
        isTransmitting = true
        txSlotIndex = txSlot
        txOnAirMessage = txMessage
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
        Task {
            // PTT is already up when the slot was pre-armed; otherwise key it now. If CAT
            // PTT refuses (the transponder changed to receive-only meanwhile), abort.
            if !pttAlreadyKeyed, let rig = self.rig {
                let keyed = await rig.setPTT(true)
                if !keyed, self.pttOverCAT {
                    self.errorText = rig.pttBlockedReason ?? "CAT PTT failed — burst not sent."
                    await self.endTransmit()
                    return
                }
            }
            // Diagnostic: how late the burst starts relative to the slot boundary. WSJT-X
            // stations see this as the decode's dT; aim for well under a few hundred ms.
            let dT = Date().timeIntervalSince1970 - Double(txSlot) * kFT4SlotSeconds
            // Late start: skip the part of the burst whose time has already passed (sampled
            // AFTER the PTT round-trip, right before playback), with a short fade-in at the
            // cut so it doesn't click.
            var skip = 0
            if lateStart, dT > 0 {
                skip = min(tx.count, Int(dT * rate))
                self.txLock.withLock {
                    self.txIndex = skip
                    let ramp = min(Int(rate * 0.005), self.txBuffer.count - skip)
                    for i in 0..<max(0, ramp) {
                        self.txBuffer[skip + i] *= Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(ramp)))
                    }
                }
            }
            let txDuration = Double(tx.count - skip) / rate + 0.4
            ODLog.shared.log(String(format: "FT4 TX dT=%+.2fs%@ · \"%@\"", dT,
                                    pttAlreadyKeyed ? " (pre-armed)" : (lateStart ? " (late start, aligned)" : ""),
                                    txMessage), category: "ft4")
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
            // The hash interface resolves `<...>` calls from FT4CallsignHashes and teaches
            // it every call this decode carries.
            var hashIF = FT4CallsignHashes.cInterface
            _ = ftx_message_decode(&msg, &hashIF, &text, &offsets)
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
    /// Calls shown in brackets (`<PJ4/K1ABC>`, resolved from a hash) are sent as plain
    /// calls — ft8_lib can't pack the brackets and hashes non-standard calls itself; the
    /// hash interface records them so our own echo and the replies resolve. An unresolved
    /// `<...>` can't be sent.
    nonisolated static func encodeTones(_ text: String) -> [UInt8]? {
        let tokens = text.uppercased().split(separator: " ").map { normalizeCallToken(String($0)) }
        guard !tokens.contains("<...>") else { return nil }
        let packed = tokens.joined(separator: " ")
        var msg = ftx_message_t()
        var hashIF = FT4CallsignHashes.cInterface
        let rc = packed.withCString { ftx_message_encode(&msg, &hashIF, $0) }
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
//  FT4CallsignHashes — ft8_lib callsign-hash memory
//
//  FT4/FT8 send non-standard and compound calls (PJ4/K1ABC, SM/R1CR) as 22/12/10-bit
//  hashes in most messages; the receiver shows them as `<...>` unless it has seen the
//  full call before. ft8_lib asks the host through `ftx_callsign_hash_interface_t`:
//  `save_hash` for every call it packs or unpacks, `lookup_hash` to resolve a hash.
//
//  The C callbacks are plain function pointers (no captured context), so they reach a
//  single global store guarded by a lock — decodes run on the slot queue while encodes
//  run on the main actor. Remembered: up to 150 non-standard/compound calls (persisted
//  between sessions), a session-only ring of recent standard calls (a type-4 message
//  hashes the standard partner call), our own call, and up to 50 recent log calls.
// ===========================================================================

final class FT4CallsignHashes: @unchecked Sendable {
    static let shared = FT4CallsignHashes()

    static let nonStandardCap = 150
    static let standardCap = 150
    static let logCap = 50

    private let lock = NSLock()
    private var nonStandard: [String] = []     // persisted, newest last
    private var standard: [String] = []        // session only, newest last
    private var logCalls: [String] = []        // preloaded from the QSO log
    private var myCall = ""
    private var byHash: [UInt32: String] = [:] // n22 → call (rebuilt on change)

    init(persist: Bool = true) {
        self.persist = persist
        if persist {
            nonStandard = Array((UserDefaults.standard.stringArray(forKey: FT4Settings.hashedCallsKey) ?? [])
                .compactMap(Self.clean).suffix(Self.nonStandardCap))
        }
        rebuild()
    }
    private let persist: Bool

    /// The C interface handed to `ftx_message_decode` / `ftx_message_encode`. The closures
    /// capture nothing (required for `@convention(c)`); they reach `shared`.
    static let cInterface = ftx_callsign_hash_interface_t(
        lookup_hash: { type, hash, out in
            guard let out, let call = FT4CallsignHashes.shared.lookup(type: type, hash: hash) else { return false }
            // ft8_lib's buffer is char[12]: at most 11 characters + NUL.
            let bytes = Array(call.utf8.prefix(11))
            for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
            out[bytes.count] = 0
            return true
        },
        save_hash: { callsign, n22 in
            guard let callsign else { return }
            FT4CallsignHashes.shared.save(String(cString: callsign), n22: n22)
        }
    )

    /// Resolve a 22/12/10-bit hash. Priority: our call, recent non-standard, recent
    /// standard, then log calls — newest first within each, so a short-hash collision
    /// picks the most recently heard station.
    func lookup(type: ftx_callsign_hash_type_t, hash: UInt32) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch type {
        case FTX_CALLSIGN_HASH_22_BITS:
            return byHash[hash & 0x3F_FFFF]
        default:
            let shift: UInt32 = type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 12
            for call in priorityOrder() {
                if let h = Self.hash22(call), h >> shift == hash { return call }
            }
            return nil
        }
    }

    /// Record a call ft8_lib packed/unpacked (from the C callback).
    func save(_ raw: String, n22: UInt32? = nil) {
        guard let call = Self.clean(raw) else { return }
        var snapshot: [String]?
        lock.lock()
        if Self.isStandard(call) {
            if standard.last != call {
                standard.removeAll { $0 == call }; standard.append(call)
                if standard.count > Self.standardCap { standard.removeFirst(standard.count - Self.standardCap) }
                rebuild()
            }
        } else if nonStandard.last != call {
            nonStandard.removeAll { $0 == call }; nonStandard.append(call)
            if nonStandard.count > Self.nonStandardCap { nonStandard.removeFirst(nonStandard.count - Self.nonStandardCap) }
            rebuild()
            snapshot = nonStandard
        }
        lock.unlock()
        if persist, let snapshot { UserDefaults.standard.set(snapshot, forKey: FT4Settings.hashedCallsKey) }
    }

    /// Our own call (so a station replying with `<OURCALL>` resolves) and the most recent
    /// distinct log calls (newest first in `logCalls`).
    func preload(myCall: String, logCalls calls: [String]) {
        var seen = Set<String>(), picked: [String] = []
        for c in calls {
            guard let call = Self.clean(c), !seen.contains(call) else { continue }
            seen.insert(call); picked.append(call)
            if picked.count == Self.logCap { break }
        }
        lock.lock()
        self.myCall = Self.clean(myCall) ?? ""
        logCalls = picked.reversed()            // newest last, like the other lists
        rebuild()
        lock.unlock()
    }

    /// Every remembered call, highest priority first. Caller holds the lock.
    private func priorityOrder() -> [String] {
        (myCall.isEmpty ? [] : [myCall]) + nonStandard.reversed() + standard.reversed() + logCalls.reversed()
    }

    /// Caller holds the lock. Lower-priority entries are inserted first so higher ones win.
    private func rebuild() {
        var map: [UInt32: String] = [:]
        for call in priorityOrder().reversed() { if let h = Self.hash22(call) { map[h] = call } }
        byHash = map
    }

    /// Uppercased, bracket-free call in ft8_lib's hash alphabet (A–Z 0–9 /), 3–11 chars.
    static func clean(_ raw: String) -> String? {
        var s = raw.uppercased().trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<") && s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        guard (3...11).contains(s.count), s != "...",
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") }) else { return nil }
        return s
    }

    /// A standard call (ft8_lib's basecall: 1–2 char prefix, a digit, 1–3 letter suffix;
    /// /P and /R suffixes allowed) — everything else is "non-standard/compound".
    static func isStandard(_ call: String) -> Bool {
        var base = call
        if base.hasSuffix("/P") || base.hasSuffix("/R") { base.removeLast(2) }
        guard !base.contains("/") else { return false }
        let c = Array(base)
        guard (3...6).contains(c.count) else { return false }
        // The area digit is the last digit (position 2 or 3); the 1–2 character prefix
        // before it needs a letter, and the suffix after it is 1–3 letters.
        guard let d = c.lastIndex(where: { $0.isNumber }), d >= 1, d <= 2 else { return false }
        let suffix = c[(d + 1)...]
        return (1...3).contains(suffix.count) && suffix.allSatisfy { $0.isLetter }
            && c[..<d].contains { $0.isLetter }
    }

    /// ft8_lib's 22-bit callsign hash (message.c `save_callsign`): the call as base-38
    /// digits over " 0-9A-Z/", right-padded with spaces to 11, times 47055833459, top 22
    /// bits of the 64-bit product.
    static func hash22(_ call: String) -> UInt32? {
        var n58: UInt64 = 0
        var count = 0
        for ch in call.utf8.prefix(11) {
            let j: UInt64
            switch ch {
            case 0x20: j = 0
            case 0x30...0x39: j = UInt64(ch - 0x30) + 1
            case 0x41...0x5A: j = UInt64(ch - 0x41) + 11
            case 0x2F: j = 37
            default: return nil
            }
            n58 = n58 &* 38 &+ j
            count += 1
        }
        while count < 11 { n58 = n58 &* 38; count += 1 }
        return UInt32((47_055_833_459 &* n58) >> (64 - 22)) & 0x3F_FFFF
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
    /// Wait-and-pounce targets (free text: calls/grids) and whether pounce is armed.
    static let pounceTargetsKey = "orbitdeck.ft4.pounceTargets"
    /// Callsigns never auto-answered while calling CQ ([String]).
    static let cqBlockListKey = "orbitdeck.ft4.cqBlockList"
    /// Remembered non-standard/compound callsigns for ft8_lib hash resolution ([String]).
    static let hashedCallsKey = "orbitdeck.ft4.hashedCalls"
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

// ###########################################################################
//  PACKET / APRS (protocol, modem and engine)
//
//  Kept in this file (rather than its own) because new source files have to be
//  added to the Xcode target by hand; this file is already in the target.
// ###########################################################################

// ===========================================================================
//  AX25.swift — AX.25 UI framing, FCS, KISS and APRS (pure, testable)
//
//  Written from the public specifications: AX.25 Link Access Protocol v2.2,
//  the KISS TNC protocol (Chepponis & Karn, 1987) and the APRS Protocol
//  Reference 1.0.1 (+ the Mic-E chapter). OscarWatch (AGPL) was consulted only as
//  a behavioral reference; no code was taken from it.
// ===========================================================================

// MARK: - FCS (CRC-16/X.25)

enum AX25FCS {
    /// CRC-16/X.25: reflected polynomial 0x8408, init 0xFFFF, final XOR 0xFFFF.
    /// Sent low byte first after the frame. ("123456789" → 0x906E.)
    nonisolated static func compute<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc ^ 0xFFFF
    }
}

// MARK: - Address

/// One AX.25 address (callsign + SSID). `repeated` is the H bit on a digipeater
/// field ("has been repeated", shown as `*`).
struct AX25Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    var call: String
    var ssid: Int
    var repeated = false

    init(call: String, ssid: Int = 0, repeated: Bool = false) {
        self.call = String(call.uppercased().prefix(6))
        self.ssid = max(0, min(15, ssid))
        self.repeated = repeated
    }

    /// Parse "N8HM", "N8HM-7" or "WIDE2-1*".
    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces).uppercased()
        var rep = false
        if t.hasSuffix("*") { rep = true; t.removeLast() }
        let parts = t.split(separator: "-", maxSplits: 1).map(String.init)
        guard let call = parts.first, !call.isEmpty, call.count <= 6,
              call.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var ssid = 0
        if parts.count == 2 {
            guard let s = Int(parts[1]), (0...15).contains(s) else { return nil }
            ssid = s
        }
        self.init(call: call, ssid: ssid, repeated: rep)
    }

    var description: String { ssid == 0 ? call : "\(call)-\(ssid)" }

    /// 7-byte address field: callsign shifted left one bit, space padded; then the
    /// SSID byte `C/H 1 1 S S S S last`.
    nonisolated func encoded(last: Bool, highBit: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0x40, count: 6)           // ' ' << 1
        for (i, ch) in call.utf8.prefix(6).enumerated() { out[i] = ch << 1 }
        var s: UInt8 = 0x60 | UInt8(ssid & 0x0F) << 1
        if highBit { s |= 0x80 }
        if last { s |= 0x01 }
        out.append(s)
        return out
    }

    nonisolated static func decode(_ b: ArraySlice<UInt8>) -> (address: AX25Address, highBit: Bool, last: Bool)? {
        guard b.count >= 7 else { return nil }
        let s = b.startIndex
        var call = ""
        for i in 0..<6 {
            let c = b[s + i] >> 1
            guard c >= 0x20, c < 0x7F else { return nil }
            if c != 0x20 { call.append(Character(UnicodeScalar(c))) }
        }
        guard !call.isEmpty else { return nil }
        let ssidByte = b[s + 6]
        let high = ssidByte & 0x80 != 0
        return (AX25Address(call: call, ssid: Int((ssidByte >> 1) & 0x0F), repeated: high), high, ssidByte & 0x01 != 0)
    }
}

// MARK: - Frame

/// An AX.25 frame (UI frames are what APRS and satellite digipeaters use).
struct AX25Frame: Equatable, Sendable {
    var destination: AX25Address
    var source: AX25Address
    var digipeaters: [AX25Address] = []
    var control: UInt8 = 0x03          // UI
    var pid: UInt8? = 0xF0             // no layer 3
    var info: [UInt8] = []

    var isUI: Bool { control & 0xEF == 0x03 }
    var infoText: String { String(decoding: info, as: UTF8.self) }

    /// Address + control + PID + info (no FCS). Destination carries the command C bit
    /// (AX.25 v2 command frame); digipeaters carry their H bit.
    nonisolated func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out += destination.encoded(last: false, highBit: true)
        out += source.encoded(last: digipeaters.isEmpty, highBit: false)
        for (i, d) in digipeaters.enumerated() {
            out += d.encoded(last: i == digipeaters.count - 1, highBit: d.repeated)
        }
        out.append(control)
        if let pid { out.append(pid) }
        out += info
        return out
    }

    /// Parse address + control + PID + info (FCS already stripped).
    nonisolated static func decode(_ bytes: [UInt8]) -> AX25Frame? {
        guard bytes.count >= 15 else { return nil }
        var addresses: [AX25Address] = []
        var i = 0
        while true {
            guard i + 7 <= bytes.count, addresses.count < 10,
                  let a = AX25Address.decode(bytes[i..<(i + 7)]) else { return nil }
            addresses.append(a.address)
            i += 7
            if a.last { break }
        }
        guard addresses.count >= 2, i < bytes.count else { return nil }
        let control = bytes[i]; i += 1
        // I frames and UI frames carry a PID; S/U (other than UI) frames don't.
        var pid: UInt8?
        if control & 0x01 == 0 || control & 0xEF == 0x03 {
            guard i < bytes.count else { return nil }
            pid = bytes[i]; i += 1
        }
        var dest = addresses[0], src = addresses[1]
        dest.repeated = false; src.repeated = false       // C bits, not "repeated"
        return AX25Frame(destination: dest, source: src, digipeaters: Array(addresses.dropFirst(2)),
                         control: control, pid: pid, info: Array(bytes[i...]))
    }

    /// TNC2 monitor format: `SRC>DST,DIGI1,DIGI2*:info`, the `*` on the last digipeater
    /// that has repeated the frame.
    var monitorText: String {
        var path = [destination.description]
        let lastRepeated = digipeaters.lastIndex { $0.repeated }
        for (i, d) in digipeaters.enumerated() {
            path.append(d.description + (i == lastRepeated ? "*" : ""))
        }
        let printable = String(info.map { (0x20..<0x7F).contains($0) || $0 >= 0x80 ? Character(UnicodeScalar($0)) : "." })
        let text = String(data: Data(info), encoding: .utf8) ?? printable
        return "\(source)>\(path.joined(separator: ",")):\(text.replacingOccurrences(of: "\r", with: " "))"
    }

    /// True when a digipeater has repeated this frame (it came back through the bird).
    var wasDigipeated: Bool { digipeaters.contains { $0.repeated } }
}

// MARK: - KISS

/// KISS TNC framing: `FEND <type> <escaped data> FEND`, type = port << 4 | command.
enum KISS {
    static let fend: UInt8 = 0xC0, fesc: UInt8 = 0xDB, tfend: UInt8 = 0xDC, tfesc: UInt8 = 0xDD

    nonisolated static func encode(_ payload: [UInt8], port: UInt8 = 0, command: UInt8 = 0) -> [UInt8] {
        var out: [UInt8] = [fend, (port & 0x0F) << 4 | (command & 0x0F)]
        for b in payload {
            switch b {
            case fend: out += [fesc, tfend]
            case fesc: out += [fesc, tfesc]
            default: out.append(b)
            }
        }
        out.append(fend)
        return out
    }

    /// Streaming decoder: feed bytes as they arrive, get complete frames out.
    struct Decoder {
        private var buffer: [UInt8] = []
        private var inFrame = false
        private var escaped = false

        init() {}

        mutating func feed(_ bytes: [UInt8]) -> [(port: UInt8, command: UInt8, data: [UInt8])] {
            var frames: [(UInt8, UInt8, [UInt8])] = []
            for b in bytes {
                if b == KISS.fend {
                    if inFrame, let type = buffer.first {
                        frames.append((type >> 4, type & 0x0F, Array(buffer.dropFirst())))
                    }
                    buffer.removeAll(keepingCapacity: true); inFrame = true; escaped = false
                    continue
                }
                guard inFrame else { continue }
                if escaped {
                    buffer.append(b == KISS.tfend ? KISS.fend : (b == KISS.tfesc ? KISS.fesc : b))
                    escaped = false
                } else if b == KISS.fesc {
                    escaped = true
                } else {
                    buffer.append(b)
                }
                if buffer.count > 1024 { buffer.removeAll(); inFrame = false }   // runaway guard
            }
            // An empty frame (FEND FEND) carries no type byte and is skipped above.
            return frames.filter { !$0.2.isEmpty || $0.1 != 0 }.map { (port: $0.0, command: $0.1, data: $0.2) }
        }
    }
}

// MARK: - APRS

/// A parsed APRS information field.
struct APRSPacket: Equatable, Sendable {
    enum Kind: String, Sendable { case position, message, ack, reject, status, micE, telemetry, other }
    var kind: Kind
    var latitude: Double?
    var longitude: Double?
    var symbolTable: Character?
    var symbolCode: Character?
    var comment = ""
    var addressee = ""
    var text = ""
    var messageID: String?
    /// `/A=nnnnnn` altitude in feet, when present in the comment.
    var altitudeFeet: Int?
    /// Maidenhead grid when the station sent one (`[FM18]` beacons).
    var grid: String?
}

enum APRS {
    /// Uncompressed position, no timestamp, messaging capable (`=`):
    /// `=DDMM.mmN/DDDMM.mmW`code comment.
    /// `ambiguity` (0–4) blanks that many trailing minute digits with spaces, per the
    /// APRS spec: 1 ≈ 185 m, 2 ≈ 1.85 km, 3 ≈ 18.5 km, 4 ≈ 111 km. Truncated, not rounded.
    nonisolated static func position(latitude: Double, longitude: Double, symbolTable: Character = "/",
                                     symbolCode: Character = "`", comment: String = "", ambiguity: Int = 0) -> String {
        let lat = abs(latitude), lon = abs(longitude)
        let latDeg = Int(lat), lonDeg = Int(lon)
        let latMin = (lat - Double(latDeg)) * 60, lonMin = (lon - Double(lonDeg)) * 60
        // Hundredths of a minute: rounded for an exact position; truncated when digits
        // are blanked (so ambiguity never rounds into the next square), with a small
        // tolerance for floating-point error (38.9° must give 54.00', not 53.99').
        func hundredths(_ m: Double) -> Int {
            min(5999, ambiguity > 0 ? Int(m * 100 + 1e-6) : Int((m * 100).rounded()))
        }
        let latH = hundredths(latMin), lonH = hundredths(lonMin)
        var latStr = String(format: "%02d%02d.%02d", latDeg, latH / 100, latH % 100)
        var lonStr = String(format: "%03d%02d.%02d", lonDeg, lonH / 100, lonH % 100)
        let blank = max(0, min(4, ambiguity))
        if blank > 0 {
            func mask(_ s: String) -> String {
                var chars = Array(s), remaining = blank, i = chars.count - 1
                while remaining > 0, i >= 0 {
                    if chars[i] != "." { chars[i] = " "; remaining -= 1 }
                    i -= 1
                }
                return String(chars)
            }
            latStr = mask(latStr); lonStr = mask(lonStr)
        }
        return "=\(latStr)\(latitude >= 0 ? "N" : "S")\(symbolTable)\(lonStr)\(longitude >= 0 ? "E" : "W")\(symbolCode)\(comment)"
    }

    /// Message: `:ADDRESSEE:text{id` (addressee padded to 9, text ≤ 67 characters).
    nonisolated static func message(to addressee: String, text: String, id: String? = nil) -> String {
        let addr = String(addressee.uppercased().prefix(9)).padding(toLength: 9, withPad: " ", startingAt: 0)
        // `{`, `|` and `~` are reserved in message text.
        let clean = String(text.filter { $0 != "{" && $0 != "|" && $0 != "~" }.prefix(67))
        return ":\(addr):\(clean)" + (id.map { "{\($0)" } ?? "")
    }

    nonisolated static func ack(to addressee: String, id: String) -> String {
        let addr = String(addressee.uppercased().prefix(9)).padding(toLength: 9, withPad: " ", startingAt: 0)
        return ":\(addr):ack\(id)"
    }

    nonisolated static func status(_ text: String) -> String { ">\(text.prefix(62))" }

    /// Parse an information field. `destination` is needed for Mic-E (the latitude
    /// rides in the destination callsign).
    nonisolated static func parse(_ info: String, destination: String = "") -> APRSPacket {
        guard let dti = info.first else { return APRSPacket(kind: .other) }
        let body = Array(info.dropFirst())
        switch dti {
        case "!", "=":
            return parsePosition(body) ?? APRSPacket(kind: .other, comment: info)
        case "/", "@":
            // 7-character timestamp, then a position.
            guard body.count > 7 else { return APRSPacket(kind: .other, comment: info) }
            return parsePosition(Array(body.dropFirst(7))) ?? APRSPacket(kind: .other, comment: info)
        case ":":
            return parseMessage(body) ?? APRSPacket(kind: .other, comment: info)
        case ">":
            return APRSPacket(kind: .status, comment: String(body))
        case "`", "'":
            return parseMicE(body, destination: destination) ?? APRSPacket(kind: .other, comment: info)
        case "[":
            // Maidenhead beacon: [FM18]comment
            if let close = info.firstIndex(of: "]") {
                let grid = String(info[info.index(after: info.startIndex)..<close]).uppercased()
                if PacketText.isGrid(grid), let ll = PacketText.gridCenter(grid) {
                    return APRSPacket(kind: .position, latitude: ll.latitude, longitude: ll.longitude,
                                      comment: String(info[info.index(after: close)...]), grid: grid)
                }
            }
            return APRSPacket(kind: .other, comment: info)
        case "T" where info.hasPrefix("T#"):
            return APRSPacket(kind: .telemetry, comment: info)
        default:
            // APRS allows a '!' position up to 40 characters into the field.
            if let bang = info.prefix(41).firstIndex(of: "!"), bang != info.startIndex,
               var p = parsePosition(Array(info[info.index(after: bang)...])) {
                p.comment = String(info[..<bang]) + " " + p.comment
                return p
            }
            return APRSPacket(kind: .other, comment: info)
        }
    }

    /// `/A=001234` (feet) anywhere in a comment.
    nonisolated static func altitudeFeet(in comment: String) -> Int? {
        guard let r = comment.range(of: "/A=") else { return nil }
        let digits = comment[r.upperBound...].prefix(7).prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    private nonisolated static func parsePosition(_ c: [Character]) -> APRSPacket? {
        // Uncompressed: DDMM.mmN T DDDMM.mmW C (19 characters).
        if c.count >= 19, c[0].isNumber {
            guard let lat = dm(String(c[0..<7]), degDigits: 2, hemi: c[7], pos: "N", neg: "S"),
                  let lon = dm(String(c[9..<17]), degDigits: 3, hemi: c[17], pos: "E", neg: "W") else { return nil }
            let comment = String(c.dropFirst(19))
            return APRSPacket(kind: .position, latitude: lat, longitude: lon, symbolTable: c[8],
                              symbolCode: c[18], comment: comment, altitudeFeet: altitudeFeet(in: comment))
        }
        // Compressed: T YYYY XXXX C cs T (13 characters, base-91).
        if c.count >= 13 {
            func b91(_ s: ArraySlice<Character>) -> Double? {
                var v = 0
                for ch in s {
                    guard let a = ch.asciiValue, (33...124).contains(a) else { return nil }
                    v = v * 91 + Int(a) - 33
                }
                return Double(v)
            }
            guard let y = b91(c[1..<5]), let x = b91(c[5..<9]) else { return nil }
            return APRSPacket(kind: .position, latitude: 90 - y / 380926, longitude: -180 + x / 190463,
                              symbolTable: c[0], symbolCode: c[9], comment: String(c.dropFirst(13)))
        }
        return nil
    }

    /// "DDMM.mm" + hemisphere → signed degrees (spaces = position ambiguity → 0).
    private nonisolated static func dm(_ s: String, degDigits: Int, hemi: Character, pos: Character, neg: Character) -> Double? {
        let t = s.replacingOccurrences(of: " ", with: "0")
        guard t.count == degDigits + 5, let deg = Double(t.prefix(degDigits)), let min = Double(t.dropFirst(degDigits)),
              hemi == pos || hemi == neg, min < 60 else { return nil }
        let v = deg + min / 60
        return hemi == neg ? -v : v
    }

    private nonisolated static func parseMessage(_ c: [Character]) -> APRSPacket? {
        guard c.count >= 10, c[9] == ":" else { return nil }
        let addressee = String(c[0..<9]).trimmingCharacters(in: .whitespaces)
        var text = String(c.dropFirst(10))
        if text.hasPrefix("ack") { return APRSPacket(kind: .ack, addressee: addressee, messageID: String(text.dropFirst(3))) }
        if text.hasPrefix("rej") { return APRSPacket(kind: .reject, addressee: addressee, messageID: String(text.dropFirst(3))) }
        var id: String?
        if let brace = text.lastIndex(of: "{") {
            // "{id" or the reply-ack form "{id}ackid".
            let raw = text[text.index(after: brace)...]
            id = String(raw.split(separator: "}").first ?? "")
            text = String(text[..<brace])
        }
        return APRSPacket(kind: .message, addressee: addressee, text: text, messageID: (id?.isEmpty ?? true) ? nil : id)
    }

    /// Mic-E (APRS 1.0.1 ch. 10): latitude digits + N/S, longitude offset and E/W in
    /// the destination callsign; longitude degrees/minutes in the info bytes.
    private nonisolated static func parseMicE(_ c: [Character], destination: String) -> APRSPacket? {
        let dest = Array(destination.uppercased().prefix(6))
        guard dest.count == 6, c.count >= 8 else { return nil }
        var digits: [Int] = []
        for ch in dest {
            switch ch {
            case "0"..."9": digits.append(Int(String(ch))!)
            case "A"..."J": digits.append(Int(ch.asciiValue! - 65))
            case "P"..."Y": digits.append(Int(ch.asciiValue! - 80))
            case "K", "L", "Z": digits.append(0)     // ambiguity / space
            default: return nil
            }
        }
        let north = ("P"..."Z").contains(dest[3])
        let lonOffset = ("P"..."Z").contains(dest[4]) ? 100 : 0
        let west = ("P"..."Z").contains(dest[5])
        let latDeg = Double(digits[0] * 10 + digits[1])
        let latMin = Double(digits[2] * 10 + digits[3]) + Double(digits[4] * 10 + digits[5]) / 100
        var lat = latDeg + latMin / 60
        if !north { lat = -lat }

        func v(_ i: Int) -> Int? { c[i].asciiValue.map { Int($0) - 28 } }
        guard var d = v(0), var m = v(1), let h = v(2) else { return nil }
        d += lonOffset
        if (180...189).contains(d) { d -= 80 } else if (190...199).contains(d) { d -= 190 }
        if m >= 60 { m -= 60 }
        var lon = Double(d) + (Double(m) + Double(h) / 100) / 60
        if west { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return APRSPacket(kind: .micE, latitude: lat, longitude: lon, symbolTable: c[7], symbolCode: c[6],
                          comment: String(c.dropFirst(8)))
    }
}

// ===========================================================================
//  AFSKModem.swift — Bell 202 1200-baud AFSK modem + HDLC (pure, testable)
//
//  The classic AX.25 packet physical layer: HDLC frames (0x7E flags, zero-bit
//  stuffing, FCS) sent LSB first, NRZI encoded (a 0 bit toggles the tone, a 1 bit
//  keeps it), as Bell 202 tones: mark 1200 Hz, space 2200 Hz, 1200 baud.
//
//  Receiver: one-bit-long quadrature correlators at mark and space give tone
//  energies; a bank of slicers compares them with different space-tone weights
//  (FM de-emphasis tilts the two tones by several dB depending on the radio, so a
//  single fixed comparison misses frames), each with its own digital PLL clock
//  recovery and HDLC decoder. Duplicate frames from the bank are dropped. Written
//  from the Bell 202 / AX.25 specifications.
// ===========================================================================

// MARK: - Text heuristics (UISS-style free text)

/// Pulls grids, signal reports and QSO tokens out of free text such as
/// "CQ FM18", "N8HM FM18 599" or "R73" — what plain-text (UISS) operators send.
enum PacketText {
    nonisolated static func isGrid(_ s: String) -> Bool {
        let c = Array(s.uppercased())
        guard c.count == 4 || c.count == 6 else { return false }
        guard ("A"..."R").contains(c[0]), ("A"..."R").contains(c[1]), c[2].isNumber, c[3].isNumber else { return false }
        if c.count == 6 { return ("A"..."X").contains(c[4]) && ("A"..."X").contains(c[5]) }
        return s.uppercased() != "RR73"
    }

    /// Center of a 4- or 6-character Maidenhead locator.
    nonisolated static func gridCenter(_ grid: String) -> (latitude: Double, longitude: Double)? {
        let c = Array(grid.uppercased()).compactMap(\.asciiValue).map(Int.init)
        guard isGrid(grid), c.count >= 4 else { return nil }
        var lon = Double(c[0] - 65) * 20 - 180 + Double(c[2] - 48) * 2
        var lat = Double(c[1] - 65) * 10 - 90 + Double(c[3] - 48)
        if c.count == 6 {
            lon += Double(c[4] - 65) * (2.0 / 24) + 1.0 / 24
            lat += Double(c[5] - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1; lat += 0.5
        }
        return (lat, lon)
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "-" }).map(String.init)
    }

    /// First grid in the text (4 or 6 characters, not "RR73").
    nonisolated static func grid(in text: String) -> String? { words(text).first { isGrid($0) } }

    /// A signal report (5x / 5xx), with a leading roger "R" stripped ("R599" → "599").
    nonisolated static func report(in text: String) -> String? {
        for w in words(text) {
            let t = w.hasPrefix("R") && w.count >= 3 ? String(w.dropFirst()) : w
            if t.count == 2 || t.count == 3, t.first == "5", t.dropFirst().allSatisfy({ ("1"..."9").contains($0) }) { return t }
        }
        return nil
    }

    nonisolated static func isRoger(_ text: String) -> Bool {
        words(text).contains { ["R", "RR", "RRR", "R73", "RR73", "ROGER", "QSL"].contains($0) || ($0.hasPrefix("R") && report(in: String($0.dropFirst())) != nil) }
    }

    nonisolated static func isSignOff(_ text: String) -> Bool {
        words(text).contains { ["73", "R73", "RR73", "TU", "TNX", "TKS", "LOGGED"].contains($0) }
    }

    nonisolated static func isCQ(_ text: String) -> Bool { words(text).first == "CQ" }

    /// "W1AW-6" → "W1AW".
    nonisolated static func baseCall(_ call: String) -> String {
        String(call.uppercased().split(separator: "-").first ?? "")
    }

    /// Whether the text names the station (with or without an SSID).
    nonisolated static func mentions(_ call: String, in text: String) -> Bool {
        let base = baseCall(call)
        return !base.isEmpty && words(text).contains { baseCall($0) == base }
    }
}

// MARK: - QSO detection

/// Detects a completed two-way packet exchange, for automatic logging. A QSO
/// is complete when we've sent a station something that names it (an APRS
/// message or ack to it, a UISS frame addressed to it, or its call in our
/// text), it has sent something that names us, and each side evidently copied
/// the other: its frame came after ours, or ours came back digipeated after its.
/// Both halves must fall within `window` (one pass).
struct PacketQSOTracker {
    struct Contact {
        var heardMeAt: Date?
        var sentToAt: Date?
        var digipeatedAt: Date?
        /// The report it sent us, and the one we sent it (plain-text QSOs).
        var reportReceived: String?
        var reportSent: String?
        var completed = false
    }

    var window: TimeInterval = 20 * 60
    private(set) var contacts: [String: Contact] = [:]   // keyed by base call

    /// A frame from `station`. Returns the contact when this completes the QSO.
    mutating func heard(from station: String, mentioningMe: Bool, text: String, at date: Date) -> Contact? {
        guard mentioningMe else { return nil }
        let key = PacketText.baseCall(station)
        var c = fresh(key, at: date)
        c.heardMeAt = date
        if let r = PacketText.report(in: text) { c.reportReceived = r }
        contacts[key] = c
        return complete(key)
    }

    /// We sent a frame naming `station`.
    mutating func sent(to station: String, text: String, at date: Date) {
        let key = PacketText.baseCall(station)
        guard !key.isEmpty else { return }
        var c = fresh(key, at: date)
        c.sentToAt = date
        if let r = PacketText.report(in: text) { c.reportSent = r }
        contacts[key] = c
    }

    /// Our frame naming `station` came back through the digipeater.
    mutating func digipeated(to station: String, at date: Date) -> Contact? {
        let key = PacketText.baseCall(station)
        guard var c = contacts[key], c.sentToAt != nil else { return nil }
        c.digipeatedAt = date
        contacts[key] = c
        return complete(key)
    }

    /// The contact, restarted if its last activity is older than the window (so the
    /// same station can be worked again on a later pass).
    private func fresh(_ key: String, at date: Date) -> Contact {
        guard let c = contacts[key] else { return Contact() }
        let last = [c.heardMeAt, c.sentToAt, c.digipeatedAt].compactMap { $0 }.max() ?? date
        return date.timeIntervalSince(last) > window ? Contact() : c
    }

    private mutating func complete(_ key: String) -> Contact? {
        guard var c = contacts[key], !c.completed,
              let heard = c.heardMeAt, let sent = c.sentToAt,
              abs(heard.timeIntervalSince(sent)) <= window else { return nil }
        // They named us after our send, or our send reached the satellite after
        // they had named us.
        let confirmed = heard > sent || (c.digipeatedAt.map { $0 >= sent && $0 >= heard } ?? false)
        guard confirmed else { return nil }
        c.completed = true
        contacts[key] = c
        return c
    }
}

// MARK: - HDLC

enum HDLC {
    /// Frame bytes (without FCS) → the NRZI tone sequence (true = mark) including
    /// `preambleFlags` leading flags and `postambleFlags` trailing ones.
    nonisolated static func encode(_ frame: [UInt8], preambleFlags: Int, postambleFlags: Int = 3) -> [Bool] {
        let fcs = AX25FCS.compute(frame)
        let body = frame + [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
        var bits: [Bool] = []
        bits.reserveCapacity((body.count + preambleFlags + postambleFlags) * 10)
        func flag() { for i in 0..<8 { bits.append((0x7E >> i) & 1 == 1) } }
        for _ in 0..<max(1, preambleFlags) { flag() }
        var ones = 0
        for byte in body {
            for i in 0..<8 {
                let bit = (byte >> i) & 1 == 1
                bits.append(bit)
                if bit {
                    ones += 1
                    if ones == 5 { bits.append(false); ones = 0 }   // zero-bit stuffing
                } else {
                    ones = 0
                }
            }
        }
        for _ in 0..<max(1, postambleFlags) { flag() }
        // NRZI: 0 → change tone, 1 → keep.
        var level = true
        return bits.map { bit in
            if !bit { level.toggle() }
            return level
        }
    }

    /// Streaming HDLC receiver: feed one demodulated tone decision per bit (true =
    /// mark); complete frames with a good FCS come out without the FCS.
    struct Decoder {
        private var lastLevel = false
        private var history: UInt32 = 0       // recent raw (NRZI-decoded) bits, newest in bit 0
        private var collecting = false
        private var byteAcc: UInt16 = 0x80
        private var bytes: [UInt8] = []
        /// True while inside a frame (after a flag, before abort/end) — used for DCD.
        private(set) var inFrame = false

        init() {}

        mutating func push(level: Bool) -> [UInt8]? {
            let bit: UInt32 = level == lastLevel ? 1 : 0
            lastLevel = level
            history = (history << 1) | bit
            var out: [UInt8]?
            if history & 0xFF == 0x7E {                    // flag 01111110
                if collecting, bytes.count >= 17, Self.fcsOK(bytes) {
                    out = Array(bytes.dropLast(2))
                }
                collecting = true; inFrame = true
                bytes.removeAll(keepingCapacity: true); byteAcc = 0x80
                return out
            }
            if history & 0x7F == 0x7F {                    // seven ones: abort / idle
                collecting = false; inFrame = false
                return nil
            }
            guard collecting else { return nil }
            if history & 0x3F == 0x3E { return nil }       // stuffed zero after five ones
            if bit == 1 { byteAcc |= 0x100 }
            let complete = byteAcc & 1 == 1
            byteAcc >>= 1
            if complete {
                bytes.append(UInt8(truncatingIfNeeded: byteAcc))
                byteAcc = 0x80
                if bytes.count > 400 { collecting = false; inFrame = false }   // runaway
            }
            return nil
        }

        private static func fcsOK(_ b: [UInt8]) -> Bool {
            let n = b.count
            let fcs = AX25FCS.compute(b[0..<(n - 2)])
            return b[n - 2] == UInt8(fcs & 0xFF) && b[n - 1] == UInt8(fcs >> 8)
        }
    }
}

// MARK: - Modulator

enum AFSKModulator {
    static let markHz = 1200.0, spaceHz = 2200.0, baud = 1200.0

    /// Phase-continuous Bell 202 audio for an NRZI tone sequence.
    nonisolated static func modulate(_ tones: [Bool], sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        let samplesPerBit = sampleRate / baud
        var out: [Float] = []
        out.reserveCapacity(Int(Double(tones.count) * samplesPerBit) + 2)
        var phase = 0.0
        var clock = 0.0
        for tone in tones {
            let step = 2 * Double.pi * (tone ? markHz : spaceHz) / sampleRate
            clock += samplesPerBit
            while clock >= 1 {
                out.append(Float(sin(phase)) * amplitude)
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                clock -= 1
            }
        }
        return out
    }

    /// A complete transmission: TX-delay flags, frame, tail flags, as audio.
    nonisolated static func transmission(_ frame: AX25Frame, sampleRate: Double, txDelayMs: Int, amplitude: Float = 0.5) -> [Float] {
        let flags = max(4, Int((Double(txDelayMs) / 1000 * baud / 8).rounded()))
        return modulate(HDLC.encode(frame.encoded(), preambleFlags: flags), sampleRate: sampleRate, amplitude: amplitude)
    }
}

// MARK: - Demodulator

/// Streaming Bell 202 demodulator. Not thread-safe: feed it from one queue.
///
/// Front end: band-pass (900 Hz high-pass, 2700 Hz low-pass), then decimation to
/// ~12–16 kHz so the decoder bank stays cheap. Bank: one-bit quadrature
/// correlators for mark/space at the nominal tones and, optionally, at tone
/// offsets of ±175/±350 Hz (a mistuned or Doppler-shifted FM receiver moves both
/// tones), each feeding slicers with different space-tone weights (FM de-emphasis
/// tilts the tones by several dB), each slicer with its own DPLL and HDLC decoder.
/// Duplicate frames from the bank are dropped.
final class AFSKDemodulator {
    let inputRate: Double
    private let rate: Double          // after decimation
    private let decimation: Int
    private var decimPhase = 0
    private var hp: Biquad, lp: Biquad, lp2: Biquad

    private final class Correlator {
        let window: Int
        var markPhasor = (re: 1.0, im: 0.0), spacePhasor = (re: 1.0, im: 0.0)
        let markStep: (re: Double, im: Double), spaceStep: (re: Double, im: Double)
        var ring: [(mi: Double, mq: Double, si: Double, sq: Double)]
        var index = 0
        var sum = (mi: 0.0, mq: 0.0, si: 0.0, sq: 0.0)
        var renorm = 0
        init(rate: Double, offset: Double) {
            window = max(4, Int((rate / 1200).rounded()))
            ring = Array(repeating: (0, 0, 0, 0), count: window)
            let wm = 2 * Double.pi * (1200 + offset) / rate, ws = 2 * Double.pi * (2200 + offset) / rate
            markStep = (cos(wm), sin(wm)); spaceStep = (cos(ws), sin(ws))
        }
        /// Feed one sample; returns (mark energy, space energy) over the last bit.
        func push(_ x: Double) -> (Double, Double) {
            let mi = x * markPhasor.re, mq = x * markPhasor.im
            let si = x * spacePhasor.re, sq = x * spacePhasor.im
            let old = ring[index]
            ring[index] = (mi, mq, si, sq)
            index = (index + 1) % window
            sum.mi += mi - old.mi; sum.mq += mq - old.mq; sum.si += si - old.si; sum.sq += sq - old.sq
            markPhasor = Self.rotate(markPhasor, markStep); spacePhasor = Self.rotate(spacePhasor, spaceStep)
            renorm += 1
            if renorm >= 512 {
                renorm = 0
                markPhasor = Self.normalize(markPhasor); spacePhasor = Self.normalize(spacePhasor)
                sum = ring.reduce(into: (0.0, 0.0, 0.0, 0.0)) { $0.0 += $1.mi; $0.1 += $1.mq; $0.2 += $1.si; $0.3 += $1.sq }
            }
            return (sum.mi * sum.mi + sum.mq * sum.mq, sum.si * sum.si + sum.sq * sum.sq)
        }
        static func rotate(_ a: (re: Double, im: Double), _ b: (re: Double, im: Double)) -> (re: Double, im: Double) {
            (a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
        }
        static func normalize(_ a: (re: Double, im: Double)) -> (re: Double, im: Double) {
            let m = (a.re * a.re + a.im * a.im).squareRoot()
            return m > 0 ? (a.re / m, a.im / m) : (1, 0)
        }
    }

    private struct Slicer {
        let correlator: Int
        let spaceGain2: Double
        var pll = 0.0
        var lastSign = false
        var hdlc = HDLC.Decoder()
    }

    private var correlators: [Correlator]
    private var slicers: [Slicer]
    private let pllStep: Double
    private var recent: [(fcs: UInt16, at: Int)] = []
    private var sampleCount = 0            // at the decimated rate
    private var lastInFrameSample = -1_000_000

    /// Space-tone weights for the slicer bank (covers roughly −6…+6 dB of tilt).
    static let defaultGains: [Double] = [0.5, 0.7, 1.0, 1.4, 2.0]
    /// Tone offsets (Hz) for the optional off-frequency banks.
    static let offsetBanks: [Double] = [-350, -175, 175, 350]

    init(sampleRate: Double, spaceGains: [Double] = AFSKDemodulator.defaultGains, offsetDecoders: Bool = true) {
        inputRate = sampleRate
        let decim = max(1, Int(sampleRate / 12_000))
        let r = sampleRate / Double(decim)
        decimation = decim
        rate = r
        hp = Biquad.highPass(fc: 900, fs: sampleRate)
        lp = Biquad.lowPass(fc: 2700, fs: sampleRate)
        lp2 = Biquad.lowPass(fc: 3000, fs: sampleRate)      // second stage: anti-alias before decimating
        pllStep = 1200 / r
        var offsets: [Double] = [0]
        if offsetDecoders { offsets += Self.offsetBanks }
        let bankCorrelators = offsets.map { Correlator(rate: r, offset: $0) }
        correlators = bankCorrelators
        var bank: [Slicer] = []
        for c in bankCorrelators.indices {
            // The nominal bank gets every gain; offset banks the three central ones.
            let gains = c == 0 ? spaceGains : [0.7, 1.0, 1.4]
            bank += gains.map { Slicer(correlator: c, spaceGain2: $0 * $0) }
        }
        slicers = bank
    }

    /// True if a frame has been in progress within the last ~250 ms (carrier detect,
    /// for half-duplex channel-busy checks).
    var channelBusy: Bool { sampleCount - lastInFrameSample < Int(rate * 0.25) }

    /// Feed audio; returns frames (address…info, FCS checked and removed).
    func process(_ samples: [Float]) -> [AX25Frame] {
        var frames: [AX25Frame] = []
        var energies = [(Double, Double)](repeating: (0, 0), count: correlators.count)
        for s in samples {
            let x = lp2.process(lp.process(hp.process(Double(s))))
            decimPhase += 1
            if decimPhase < decimation { continue }
            decimPhase = 0
            sampleCount += 1
            for c in correlators.indices { energies[c] = correlators[c].push(x) }

            var anyInFrame = false
            for k in slicers.indices {
                let (markE, spaceE) = energies[slicers[k].correlator]
                let mark = markE > spaceE * slicers[k].spaceGain2
                // Digital PLL: sample each bit when the phase wraps; nudge the phase so
                // tone transitions fall halfway between samples.
                if mark != slicers[k].lastSign {
                    slicers[k].lastSign = mark
                    let p = slicers[k].pll
                    slicers[k].pll += (0.5 - p) * (slicers[k].hdlc.inFrame ? 0.15 : 0.4)
                }
                slicers[k].pll += pllStep
                if slicers[k].pll >= 1 {
                    slicers[k].pll -= 1
                    if let bytes = slicers[k].hdlc.push(level: mark), let frame = AX25Frame.decode(bytes) {
                        let fcs = AX25FCS.compute(bytes)
                        recent.removeAll { sampleCount - $0.at > Int(rate) }
                        if !recent.contains(where: { $0.fcs == fcs }) {
                            recent.append((fcs, sampleCount))
                            frames.append(frame)
                        }
                    }
                }
                if slicers[k].hdlc.inFrame { anyInFrame = true }
            }
            if anyInFrame { lastInFrameSample = sampleCount }
        }
        return frames
    }
}

/// Direct-form-I biquad (RBJ cookbook coefficients).
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func highPass(fc: Double, fs: Double, q: Double = 0.707) -> Biquad {
        let w = 2 * Double.pi * fc / fs, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 + c) / 2 / a0; f.b1 = -(1 + c) / a0; f.b2 = (1 + c) / 2 / a0
        f.a1 = -2 * c / a0; f.a2 = (1 - alpha) / a0
        return f
    }
    static func lowPass(fc: Double, fs: Double, q: Double = 0.707) -> Biquad {
        let w = 2 * Double.pi * min(fc, fs * 0.45) / fs, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 - c) / 2 / a0; f.b1 = (1 - c) / a0; f.b2 = (1 - c) / 2 / a0
        f.a1 = -2 * c / a0; f.a2 = (1 - alpha) / a0
        return f
    }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// What the packet engine needs from a built-in demodulator (AFSK 1200 or G3RUH 9600).
protocol PacketDemodulator: AnyObject {
    /// True if a frame has been in progress within the last ~250 ms.
    var channelBusy: Bool { get }
    /// Feed audio; returns frames (address…info, FCS checked and removed).
    func process(_ samples: [Float]) -> [AX25Frame]
}

extension AFSKDemodulator: PacketDemodulator {}

// ===========================================================================
//  G3RUH 9600 — K9NG/G3RUH 9600 bps FSK modem (pure, testable)
//
//  Baseband FSK: the HDLC/NRZI bit stream is scrambled with the self-
//  synchronizing polynomial 1 + x^12 + x^17 and sent as a shaped ±1 level that
//  directly frequency-modulates the transmitter (no audio tones). It needs the
//  radio's 9600 data port (flat, DC-coupled-ish discriminator audio in and a
//  direct modulator input out); speaker/mic audio is too filtered to decode.
//
//  Receiver: low-pass, then a bank of slicers whose thresholds track the
//  discriminator's DC offset in different ways (a mistuned FM receiver, e.g.
//  between CAT Doppler steps, shifts the whole baseband up or down), each with
//  its own interpolating DPLL clock recovery, descrambler and HDLC decoder.
//  Duplicate frames from the bank are dropped. The receive path should reach
//  down to ~50 Hz: a steeper or higher high-pass (some sound-card inputs) makes
//  the baseline wander enough to close the eye. Written from the G3RUH/K9NG
//  modem description and the AX.25 specification.
// ===========================================================================

/// K9NG/G3RUH self-synchronizing scrambler, polynomial 1 + x^12 + x^17. Applied to
/// the NRZI line levels (after NRZI on transmit, before NRZI decoding on receive).
/// The descrambler resynchronizes by itself 17 bits into any stream, and an
/// inverted channel only inverts the output — which NRZI ignores — so the
/// receiver doesn't care about the radio's discriminator polarity.
struct G3RUHScrambler {
    private var state: UInt32 = 0          // recent line bits, newest in bit 0

    init() {}

    /// TX: out = in ⊕ out(n−12) ⊕ out(n−17).
    nonisolated mutating func scramble(_ bit: Bool) -> Bool {
        let out = (bit ? 1 : 0) ^ (state >> 11 & 1) ^ (state >> 16 & 1)
        state = state << 1 | out
        return out == 1
    }

    /// RX: out = in ⊕ in(n−12) ⊕ in(n−17).
    nonisolated mutating func descramble(_ bit: Bool) -> Bool {
        let b: UInt32 = bit ? 1 : 0
        let out = b ^ (state >> 11 & 1) ^ (state >> 16 & 1)
        state = state << 1 | b
        return out == 1
    }
}

// MARK: - G3RUH modulator

enum G3RUHModulator {
    static let baud = 9600.0
    /// Raised-cosine roll-off: 50% keeps the occupied audio bandwidth to 7.2 kHz,
    /// inside a 16 kHz (Icom network audio) path's Nyquist limit.
    static let rollOff = 0.5
    /// Pulse length each side of the bit center, in bits.
    static let span = 4

    /// Raised-cosine pulse at `x` bit periods from its center (1 at 0, 0 at other
    /// integer offsets: no intersymbol interference at the bit centers).
    nonisolated static func pulse(_ x: Double) -> Double {
        let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
        let d = 1 - (2 * rollOff * x) * (2 * rollOff * x)
        if abs(d) < 1e-9 { return Double.pi / 4 * sin(Double.pi / (2 * rollOff)) / (Double.pi / (2 * rollOff)) }
        return sinc * cos(Double.pi * rollOff * x) / d
    }

    /// Scrambled, pulse-shaped baseband for an NRZI line-level sequence (from
    /// `HDLC.encode`). Random data peaks up to ~1.5 × `amplitude`; clamped to ±1.
    nonisolated static func modulate(_ levels: [Bool], sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        var scrambler = G3RUHScrambler()
        let symbols = levels.map { scrambler.scramble($0) ? 1.0 : -1.0 }
        let n = Int(Double(symbols.count) * sampleRate / baud)
        var out = [Float](repeating: 0, count: n)
        let bitsPerSample = baud / sampleRate
        for i in 0..<n {
            let t = Double(i) * bitsPerSample            // time in bits; bit k is centered at k + 0.5
            let k0 = Int(t)
            var v = 0.0
            for k in max(0, k0 - span)...min(symbols.count - 1, k0 + span) {
                v += symbols[k] * pulse(t - (Double(k) + 0.5))
            }
            out[i] = max(-1, min(1, Float(v) * amplitude))
        }
        return out
    }

    /// A complete transmission: TX-delay flags, frame, tail flags, as baseband audio.
    nonisolated static func transmission(_ frame: AX25Frame, sampleRate: Double, txDelayMs: Int, amplitude: Float = 0.5) -> [Float] {
        let flags = max(16, Int((Double(txDelayMs) / 1000 * baud / 8).rounded()))
        // A longer tail than AFSK: the receive filters and DPLL need a few bits to
        // push the closing flag through.
        return modulate(HDLC.encode(frame.encoded(), preambleFlags: flags, postambleFlags: 8),
                        sampleRate: sampleRate, amplitude: amplitude)
    }

    /// Scrambled flags for `seconds` — the 9600 test signal for setting deviation.
    nonisolated static func idle(seconds: Double, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        let flags = max(1, Int(seconds * baud / 8))
        var bits: [Bool] = []
        bits.reserveCapacity(flags * 8)
        var level = true
        for _ in 0..<flags {
            for i in 0..<8 {
                if (0x7E >> i) & 1 == 0 { level.toggle() }      // NRZI
                bits.append(level)
            }
        }
        return modulate(bits, sampleRate: sampleRate, amplitude: amplitude)
    }
}

// MARK: - G3RUH demodulator

/// Streaming G3RUH 9600 demodulator. Not thread-safe: feed it from one queue.
///
/// Rates below 38.4 kHz (Icom network audio is 16 kHz, under 2 samples per bit)
/// are first interpolated by an integer factor with a windowed-sinc FIR, so the
/// clock recovery has ≥ 4 samples per bit. Then a 2-pole low-pass at 6.5 kHz
/// trims out-of-band noise, and the slicer bank:
///  • two exponential DC trackers (≈ 8 and ≈ 32 bits), for a slowly drifting offset;
///  • a peak/valley midpoint, which follows a DC step (a CAT Doppler retune) in a
///    few bits, plus the midpoint ± 15% of the eye height for asymmetric eyes.
/// Each slicer's DPLL locates zero crossings by linear interpolation between
/// samples and nudges its phase so crossings fall on bit boundaries; it samples
/// at mid-bit (interpolated), then descrambles and feeds its HDLC decoder.
final class G3RUHDemodulator: PacketDemodulator {
    let inputRate: Double
    private let rate: Double                  // after interpolation
    private let factor: Int
    private let interpTaps: [Double]          // polyphase: tap p + j·factor for phase p
    private var interpHistory: [Double]
    private var interpIndex = 0
    private var lp1: Biquad, lp2: Biquad

    private enum Threshold { case fastMean, slowMean, envelope(Double) }

    private struct Slicer {
        let threshold: Threshold
        var phase = 0.0
        var prev = 0.0
        var scrambler = G3RUHScrambler()
        var hdlc = HDLC.Decoder()
    }

    private var slicers: [Slicer]
    private let step: Double                  // bits per (interpolated) sample
    private let fastDC: Double, slowDC: Double, release: Double
    private var meanFast = 0.0, meanSlow = 0.0
    private var hi = 0.0, lo = 0.0
    private var recent: [(fcs: UInt16, at: Int)] = []
    private var sampleCount = 0
    private var lastInFrameSample = -1_000_000

    init(sampleRate: Double) {
        inputRate = sampleRate
        let f = sampleRate < 38_400 ? Int((38_400 / sampleRate).rounded(.up)) : 1
        factor = f
        rate = sampleRate * Double(f)
        // Windowed-sinc interpolator (Blackman, 16 input samples long), cutoff at
        // 0.45 × the input rate, gain `factor` to make up for the zero stuffing.
        let length = 16 * f
        let wc = 0.45 / Double(f)                 // cycles per output sample
        let center = Double(length - 1) / 2
        interpTaps = (0..<length).map { i in
            let x = Double(i) - center
            let sinc = x == 0 ? 2 * wc : sin(2 * Double.pi * wc * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(length - 1))
                + 0.08 * cos(4 * Double.pi * Double(i) / Double(length - 1))
            return sinc * w * Double(f)
        }
        interpHistory = Array(repeating: 0, count: 16)
        lp1 = Biquad.lowPass(fc: 6500, fs: rate)
        lp2 = Biquad.lowPass(fc: 6500, fs: rate, q: 0.54)
        step = G3RUHModulator.baud / rate
        let samplesPerBit = rate / G3RUHModulator.baud
        fastDC = 1 / (8 * samplesPerBit)
        slowDC = 1 / (32 * samplesPerBit)
        release = 1 / (24 * samplesPerBit)
        slicers = [Threshold.fastMean, .slowMean, .envelope(0), .envelope(0.15), .envelope(-0.15)]
            .map { Slicer(threshold: $0) }
    }

    var channelBusy: Bool { sampleCount - lastInFrameSample < Int(rate * 0.25) }

    func process(_ samples: [Float]) -> [AX25Frame] {
        var frames: [AX25Frame] = []
        let n = interpHistory.count
        for s in samples {
            if factor == 1 {
                demodulate(Double(s), into: &frames)
                continue
            }
            interpHistory[interpIndex] = Double(s)
            for p in 0..<factor {
                var y = 0.0
                for j in 0..<n {
                    y += interpTaps[p + j * factor] * interpHistory[(interpIndex - j + n) % n]
                }
                demodulate(y, into: &frames)
            }
            interpIndex = (interpIndex + 1) % n
        }
        return frames
    }

    private func demodulate(_ input: Double, into frames: inout [AX25Frame]) {
        let x = lp2.process(lp1.process(input))
        sampleCount += 1
        meanFast += (x - meanFast) * fastDC
        meanSlow += (x - meanSlow) * slowDC
        // Peak/valley: jump out to new extremes, relax toward the signal otherwise.
        hi += (x - hi) * (x > hi ? 0.5 : release)
        lo += (x - lo) * (x < lo ? 0.5 : release)
        let mid = (hi + lo) / 2, eye = hi - lo

        var anyInFrame = false
        for k in slicers.indices {
            let thr: Double
            switch slicers[k].threshold {
            case .fastMean: thr = meanFast
            case .slowMean: thr = meanSlow
            case .envelope(let bias): thr = mid + bias * eye
            }
            let d = x - thr, prev = slicers[k].prev
            let prevPhase = slicers[k].phase
            slicers[k].phase += step
            if (d >= 0) != (prev >= 0), prev != d {
                // Crossing between the previous and this sample, at fraction f.
                let f = prev / (prev - d)
                var cross = prevPhase + f * step
                cross -= cross.rounded(.down)
                let gain = slicers[k].hdlc.inFrame ? 0.12 : 0.3
                slicers[k].phase = max(0, slicers[k].phase - (cross - 0.5) * gain)
            }
            if slicers[k].phase >= 1 {
                slicers[k].phase -= 1
                // Mid-bit fell (phase / step) samples ago: interpolate the decision.
                let back = min(1, max(0, slicers[k].phase / step))
                let v = d + (prev - d) * back
                let level = slicers[k].scrambler.descramble(v >= 0)
                if let bytes = slicers[k].hdlc.push(level: level), let frame = AX25Frame.decode(bytes) {
                    let fcs = AX25FCS.compute(bytes)
                    recent.removeAll { sampleCount - $0.at > Int(rate) }
                    if !recent.contains(where: { $0.fcs == fcs }) {
                        recent.append((fcs, sampleCount))
                        frames.append(frame)
                    }
                }
            }
            slicers[k].prev = d
            if slicers[k].hdlc.inFrame { anyInFrame = true }
        }
        if anyInFrame { lastInFrameSample = sampleCount }
    }
}

// ===========================================================================
//  PacketEngine.swift — AX.25 / APRS packet terminal for satellite digipeaters
//
//  Two ways to reach the radio:
//   • Built-in modem: Bell 202 AFSK 1200 over the shared AudioHub capture (USB
//     interface, Icom network audio, or the phone mic as a last resort), keyed by
//     CAT PTT when the radio supports it (VOX otherwise). Half duplex by default:
//     it waits for a clear channel before keying.
//   • KISS TNC over BLE: the BLE KISS TNC API (hessu/aprs-specs), as exposed by the
//     B.B. Link adapter for the Kenwood TH-D74/D75's built-in TNC (the radio itself
//     only speaks Bluetooth Classic, which iOS apps can't open).
//
//  CAT Doppler keeps running underneath: in split-VFO / same-band-hold mode the
//  rig controller holds uplink writes while keyed, so frames go out on frequency.
// ===========================================================================

/// How the compose box's text goes out.
enum PacketMessageFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    /// APRS: CQ/blank "To" → `>status`; a callsign → `:ADDRESSEE:message`.
    case aprs
    /// UISS-style unproto text: AX.25 destination = "To" (CQ by default), info =
    /// the typed text (`N8HM-6>CQ,ARISS:CQ FM18`).
    case plainText
    var id: String { rawValue }
    var label: String { self == .aprs ? "APRS" : "Plain text (UISS)" }
}

/// Which built-in modem a satellite uses.
enum PacketModem: String, Codable, CaseIterable, Identifiable, Sendable {
    /// From the satellite's packet transponder (≥ 4800 baud or "G3RUH"/"9600" → 9600).
    case automatic
    case afsk1200
    case g3ruh9600
    var id: String { rawValue }
    var label: String {
        switch self { case .automatic: "Auto"; case .afsk1200: "1200 AFSK"; case .g3ruh9600: "9600 G3RUH" }
    }
}

/// Per-satellite packet setup (path, message format and modem).
struct PacketSatelliteProfile: Codable, Equatable, Sendable {
    var path: String
    var format: PacketMessageFormat
    var modem: PacketModem = .automatic
}

extension PacketSatelliteProfile {
    /// Tolerant: profiles saved before `modem` existed decode with Auto.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? "ARISS"
        format = (try? c.decodeIfPresent(PacketMessageFormat.self, forKey: .format)) ?? .aprs
        modem = (try? c.decodeIfPresent(PacketModem.self, forKey: .modem)) ?? .automatic
    }
}

/// How precisely our position is sent (APRS position ambiguity).
enum PacketPositionPrecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case exact, ambiguity1, ambiguity2, ambiguity3, gridCenter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .exact: "Exact"
        case .ambiguity1: "≈ 200 m"
        case .ambiguity2: "≈ 2 km"
        case .ambiguity3: "≈ 20 km"
        case .gridCenter: "Grid square center"
        }
    }
    var ambiguity: Int {
        switch self { case .ambiguity1: 1; case .ambiguity2: 2; case .ambiguity3: 3; default: 0 }
    }
}

enum PacketDuplex: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, half, full
    var id: String { rawValue }
    var label: String { switch self { case .automatic: "Automatic"; case .half: "Half duplex"; case .full: "Full duplex" } }
}

struct PacketSettings: Codable, Equatable, Sendable {
    enum Transport: String, Codable, CaseIterable, Identifiable, Sendable {
        case builtInModem, bleKISS
        var id: String { rawValue }
        var label: String { self == .builtInModem ? "Built-in modem" : "BLE KISS TNC" }
    }
    var transport: Transport = .builtInModem
    var ssid = 6                    // -6 is the common SSID for satellite operation
    var path = "ARISS"              // default path; per-satellite profiles override it
    var format: PacketMessageFormat = .aprs
    var profiles: [String: PacketSatelliteProfile] = [:]   // keyed by NORAD
    var txDelayMs = 300
    var symbolTable = "/"
    var symbolCode = "`"            // primary table "`" = dish antenna
    var beaconComment = ""
    var positionPrecision: PacketPositionPrecision = .ambiguity2
    /// Acknowledge numbered messages addressed to us. Off by default: on a busy pass
    /// every ack costs everyone digipeater time.
    var autoAck = false
    /// Number our messages so the other station can ack them.
    var requestAcks = false
    /// Log a QSO (mode PKT) automatically once a two-way exchange is complete.
    var autoLogQSOs = true
    /// Quick messages. Placeholders: {MYCALL} {MYGRID} {MYGRID4} {CALL} {HEARD};
    /// a macro of exactly {POSITION} sends a position report.
    var macros: [String] = PacketSettings.defaultMacros
    var blockBelowHorizon = true
    var pttWatchdogSeconds = 10
    var persistence = 63            // p-persistence 0–255 (send when random ≤ p)
    var slotTimeMs = 100
    var maxChannelWaitSeconds = 5
    var duplex: PacketDuplex = .automatic
    /// Timed position beacon while the satellite is up; 0 = off (minimum 1 minute).
    var beaconMinutes = 0
    var offsetDecoders = true
    var bleIdentifier = ""
    var bleName = ""
    /// B.B. Link only: let OrbitDeck put the radio on the satellite's packet frequency.
    var bbLinkTune = true
    var outputLevel: Float = 0.5
    var inputGain: Float = 1
    /// Built-in modem with CAT connected: put the radio in its data sub-mode (e.g.
    /// Icom FM-D / USB-D) so audio goes through the data port while packet runs.
    var useDataMode = true

    static let defaultMacros = ["CQ {MYGRID4}", "{CALL} {MYGRID4} 599", "R 599 {MYGRID4}", "73 TU", "{HEARD}", "{POSITION}"]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PacketSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        transport = v(.transport, d.transport); ssid = v(.ssid, d.ssid); path = v(.path, d.path)
        format = v(.format, d.format); profiles = v(.profiles, d.profiles)
        txDelayMs = v(.txDelayMs, d.txDelayMs); symbolTable = v(.symbolTable, d.symbolTable)
        symbolCode = v(.symbolCode, d.symbolCode); beaconComment = v(.beaconComment, d.beaconComment)
        positionPrecision = v(.positionPrecision, d.positionPrecision)
        autoAck = v(.autoAck, d.autoAck); requestAcks = v(.requestAcks, d.requestAcks)
        autoLogQSOs = v(.autoLogQSOs, d.autoLogQSOs)
        macros = v(.macros, d.macros); blockBelowHorizon = v(.blockBelowHorizon, d.blockBelowHorizon)
        pttWatchdogSeconds = v(.pttWatchdogSeconds, d.pttWatchdogSeconds); persistence = v(.persistence, d.persistence)
        slotTimeMs = v(.slotTimeMs, d.slotTimeMs); maxChannelWaitSeconds = v(.maxChannelWaitSeconds, d.maxChannelWaitSeconds)
        duplex = v(.duplex, d.duplex); beaconMinutes = v(.beaconMinutes, d.beaconMinutes)
        offsetDecoders = v(.offsetDecoders, d.offsetDecoders)
        bleIdentifier = v(.bleIdentifier, d.bleIdentifier); bleName = v(.bleName, d.bleName)
        bbLinkTune = v(.bbLinkTune, d.bbLinkTune)
        outputLevel = v(.outputLevel, d.outputLevel); inputGain = v(.inputGain, d.inputGain)
        useDataMode = v(.useDataMode, d.useDataMode)
    }
}

struct PacketLogEntry: Identifiable, Sendable {
    enum Direction: Sendable { case received, sent }
    let id = UUID()
    let date: Date
    let direction: Direction
    let frame: AX25Frame
    let aprs: APRSPacket
    /// Our own frame heard back after a digipeater repeated it.
    var ownDigipeated = false
    /// Sent frames: seconds until the digipeated copy came back.
    var digipeatDelay: TimeInterval?
    /// A message (APRS or plain text) addressed to us.
    var toMe = false
    var acked = false
    var isCQ = false
    var isTelemetry = false
    var isBeacon = false
    /// The text to show: the APRS message/status/comment, or the plain-text info.
    var text: String
}

/// A station heard this session.
struct PacketHeardStation: Identifiable, Sendable {
    var id: String { call }
    let call: String
    var firstHeard: Date
    var lastHeard: Date
    var frames = 1
    var cqs = 0
    var grid: String?
    var latitude: Double?
    var longitude: Double?
    /// Heard through a digipeater (i.e. via the satellite).
    var viaDigipeater = false
    var logged = false
    /// APRS symbol (table `/`, `\` or an overlay character, and code), when sent.
    var symbolTable: Character?
    var symbolCode: Character?
}

@MainActor
final class PacketEngine: ObservableObject {
    static let settingsKey = "orbitdeck.packet"
    /// APRS "tocall" for experimental software (APZ…).
    static let tocall = "APZODK"
    static let maxLog = 300

    @Published var settings: PacketSettings { didSet { if settings != oldValue { save(); settingsChanged(oldValue) } } }
    @Published private(set) var isRunning = false
    @Published private(set) var isTransmitting = false
    @Published private(set) var status = "Idle"
    @Published var errorText = ""
    @Published private(set) var log: [PacketLogEntry] = []
    @Published private(set) var heard: [PacketHeardStation] = []
    @Published private(set) var channelBusy = false
    @Published private(set) var rxLevel: Float = 0
    @Published private(set) var heardSelfViaSatellite = false
    @Published private(set) var stats = (sent: 0, digipeated: 0, medianDelay: 0.0)
    /// The last automatically logged QSO, for the card ("Logged W1AW at 14:05").
    @Published private(set) var lastAutoLogged: (call: String, date: Date)?

    private weak var rig: RigController?
    private weak var audio: AudioHub?
    private weak var store: OrbitStore?
    private weak var qso: QSOStore?

    // Built-in modem
    private var source: AudioSource?
    private let demodQueue = DispatchQueue(label: "org.orbitdeck.packet.demod")
    private nonisolated(unsafe) var demod: (any PacketDemodulator)?
    /// The modem the built-in path is running (resolved from the satellite profile).
    @Published private(set) var runningModem: PacketModem = .afsk1200
    /// We put the radio in its data sub-mode at start (undone at stop).
    private var engagedDataMode = false
    private nonisolated(unsafe) var peak: Float = 0
    private let txLock = NSLock()
    private nonisolated(unsafe) var txBuffer: [Float] = []
    private nonisolated(unsafe) var txIndex = 0
    private var meterTimer: DispatchSourceTimer?
    private var transmissionID = 0
    /// Half duplex: decodes are ignored until this time (our own transmission and the
    /// receiver turnaround guard).
    private var rxBlankedUntil = Date.distantPast

    // BLE KISS
    private var kissLink: BLESerialTransport?
    private var kissDecoder = KISS.Decoder()
    private var kissReader: Task<Void, Never>?
    private var tunedForSatellite: UInt?

    private var txQueue: [AX25Frame] = []
    private var txRunning = false
    private var messageNumber = Int.random(in: 1...99)
    private var pendingAcks: [String: UUID] = [:]   // message id → log entry
    /// Our recent transmissions, for matching the digipeated copy (info text → when).
    private var recentSends: [(info: [UInt8], date: Date, logID: UUID)] = []
    private var delays: [TimeInterval] = []
    private var beaconTask: Task<Void, Never>?
    private var qsoTracker = PacketQSOTracker()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(PacketSettings.self, from: data) {
            settings = s
        } else {
            settings = PacketSettings()
        }
    }

    func attach(rig: RigController, audio: AudioHub, store: OrbitStore, qso: QSOStore) {
        self.rig = rig; self.audio = audio; self.store = store; self.qso = qso
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    private func settingsChanged(_ old: PacketSettings) {
        if settings.beaconMinutes != old.beaconMinutes { restartBeacon() }
    }

    /// The operator's callsign (station setup in the log, else Settings).
    var myCall: String {
        let fromLog = qso?.config.myCall.trimmingCharacters(in: .whitespaces) ?? ""
        if !fromLog.isEmpty { return fromLog.uppercased() }
        return (store?.preferences.callsign ?? "").trimmingCharacters(in: .whitespaces).uppercased()
    }
    var myAddress: AX25Address? {
        guard let base = AX25Address(myCall.split(separator: "-").first.map(String.init) ?? "") else { return nil }
        return AX25Address(call: base.call, ssid: settings.ssid)
    }
    private var myGrid: String { store?.operatorGrid6 ?? "" }

    // MARK: Satellite profiles

    /// Built-in defaults (ISS: APRS via ARISS); per-satellite edits are stored.
    func profile(for norad: UInt?) -> PacketSatelliteProfile {
        if let norad, let p = settings.profiles[String(norad)] { return p }
        return PacketSatelliteProfile(path: settings.path, format: settings.format)
    }

    func setProfile(_ profile: PacketSatelliteProfile, for norad: UInt) {
        settings.profiles[String(norad)] = profile
    }

    /// A transponder suited to packet on this satellite (AFSK/APRS/packet digipeater),
    /// else whatever CAT is tracking. 1200-baud transponders come first unless the
    /// satellite's profile asks for 9600.
    func packetTransponder(for sat: SatelliteRecord, preferring: PacketModem? = nil) -> TransponderRecord? {
        let packetWords = ["APRS", "AFSK", "PACKET", "DIGI", "AX.25", "AX25", "G3RUH"]
        let packetish = sat.transponders.filter { tp in
            let h = "\(tp.mode) \(tp.description)".uppercased()
            return tp.isActive && packetWords.contains { h.contains($0) }
        }
        let fast = packetish.filter(Self.is9600)
        let slow = packetish.filter { !Self.is9600($0) && ($0.baud == 0 || $0.baud <= 1200) }
        let ordered = (preferring ?? profile(for: sat.id).modem) == .g3ruh9600 ? fast + slow : slow + fast
        return ordered.first { $0.isTwoWay } ?? ordered.first ?? rig?.transponder(for: sat)
    }

    /// A 9600-baud (G3RUH-family) packet transponder.
    private static func is9600(_ tp: TransponderRecord) -> Bool {
        let h = "\(tp.mode) \(tp.description)".uppercased()
        return tp.baud >= 4800 || h.contains("G3RUH") || h.contains("9600") || h.contains("9K6")
    }

    /// The built-in modem for this satellite: the profile's choice, or Auto from its
    /// packet transponder's baud rate (1200 AFSK when nothing says otherwise).
    func modem(for sat: SatelliteRecord?) -> PacketModem {
        guard let sat else { return .afsk1200 }
        let chosen = profile(for: sat.id).modem
        return chosen != .automatic ? chosen : autoModem(for: sat)
    }

    /// What Auto picks for this satellite (1200 unless its packet transponder is 9600).
    func autoModem(for sat: SatelliteRecord) -> PacketModem {
        packetTransponder(for: sat, preferring: .afsk1200).map(Self.is9600) == true ? .g3ruh9600 : .afsk1200
    }

    /// Full duplex only on a crossband transponder (we can hear our own downlink);
    /// same-band/simplex packet is half duplex.
    func isFullDuplex(for sat: SatelliteRecord?) -> Bool {
        switch settings.duplex {
        case .half: return false
        case .full: return true
        case .automatic:
            guard let sat, let tp = packetTransponder(for: sat), tp.uplinkCenter > 0 else { return false }
            return abs(tp.uplinkCenter - tp.downlinkCenter) >= 10_000_000 && !(rig?.isSplitVFO ?? false)
        }
    }

    /// The selected satellite's elevation now (nil without a satellite).
    private func satelliteElevation() -> Double? {
        guard let store, let sat = store.selectedSatellite else { return nil }
        return try? OrbitPredictor.look(sat, observer: store.preferences.observer).elevation
    }

    // MARK: Start / stop

    func start(satellite: SatelliteRecord?) {
        guard !isRunning else { return }
        errorText = ""
        guard myAddress != nil else { errorText = "Set your callsign in Settings first."; return }
        guard AudioActivity.claimMode("Packet") else {
            errorText = "Audio is in use by \(AudioActivity.modeHolder ?? "another feature"). Stop it first."
            return
        }
        heardSelfViaSatellite = false
        switch settings.transport {
        case .builtInModem: startModem(satellite: satellite)
        case .bleKISS: startKISS(satellite: satellite)
        }
        if isRunning { restartBeacon() } else { AudioActivity.releaseMode("Packet") }
    }

    func stop() {
        guard isRunning else { return }
        txQueue.removeAll()
        beaconTask?.cancel(); beaconTask = nil
        meterTimer?.cancel(); meterTimer = nil
        if let source {
            source.stopPlayback(); source.stop()
            if isTransmitting { Task { await rig?.setPTT(false) } }
        }
        source = nil
        demodQueue.sync { demod = nil }
        if engagedDataMode { rig?.setDigitalDataMode(false, client: "packet"); engagedDataMode = false }
        kissReader?.cancel(); kissReader = nil
        if let link = kissLink {
            let restore = settings.bbLinkTune && tunedForSatellite != nil
            Task {
                if restore { try? await link.send(KISS.encode([0xEB], command: 0x06)) }   // B.B. Link: restore frequency
                await link.disconnect()
            }
        }
        kissLink = nil; tunedForSatellite = nil
        isTransmitting = false; isRunning = false; channelBusy = false; rxLevel = 0
        status = "Idle"
        AudioActivity.end()
        AudioActivity.releaseMode("Packet")
    }

    private func startModem(satellite: SatelliteRecord?) {
        guard let audio, let src = audio.makeSource(allowMicFallback: true) else {
            errorText = "No audio input. Connect a USB audio interface or an Icom network radio."
            return
        }
        src.inputGain = settings.inputGain
        src.outputGain = 1
        src.onError = { [weak self] m in Task { @MainActor in self?.errorText = m } }
        do {
            try src.start(onFrames: { [weak self] frames in self?.ingest(frames) })
        } catch {
            errorText = error.localizedDescription
            return
        }
        source = src
        let rate = src.sampleRate
        let offsets = settings.offsetDecoders
        let chosen = modem(for: satellite)
        runningModem = chosen
        demodQueue.sync {
            demod = chosen == .g3ruh9600 ? G3RUHDemodulator(sampleRate: rate)
                : AFSKDemodulator(sampleRate: rate, offsetDecoders: offsets)
        }
        isRunning = true
        AudioActivity.begin()
        status = listeningStatus
        // Radio audio under CAT control: ask for the data sub-mode so the modem uses
        // the data port (9600 needs its flat path). Never for the phone-mic fallback,
        // and never on the KISS path (the radio's own TNC).
        if settings.useDataMode, let rig, rig.connected,
           audio.usbConnected || rig.icomAudioTransport != nil {
            rig.setDigitalDataMode(true, client: "packet")
            engagedDataMode = true
        }
        // Stuck-PTT recovery: make sure the radio isn't left keyed from a previous run.
        if rig?.pttCapable ?? false { Task { await rig?.setPTT(false) } }
        startMeter()
    }

    private nonisolated func ingest(_ frames: [Float]) {
        let p = frames.reduce(Float(0)) { max($0, abs($1)) }
        demodQueue.async { [weak self] in
            guard let self, let demod = self.demod else { return }
            if p > self.peak { self.peak = p }
            let decoded = demod.process(frames)
            let busy = demod.channelBusy
            // Hop to the main actor only when something changed: a Task per audio buffer
            // (~100/s) would flood it (the FT4 engine hit exactly that).
            guard !decoded.isEmpty || busy != self.lastBusy else { return }
            self.lastBusy = busy
            Task { @MainActor in
                if self.channelBusy != busy { self.channelBusy = busy }
                for f in decoded { self.received(f) }
            }
        }
    }
    private nonisolated(unsafe) var lastBusy = false   // demodQueue only

    private func startMeter() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let p = self.demodQueue.sync { () -> Float in let v = self.peak; self.peak = 0; return v }
            self.rxLevel = max(p, self.rxLevel * 0.75)
        }
        t.resume()
        meterTimer = t
    }

    private func startKISS(satellite: SatelliteRecord?) {
        guard let uuid = UUID(uuidString: settings.bleIdentifier) else {
            errorText = "Choose the BLE KISS adapter (e.g. B.B. Link) in Setup."
            return
        }
        let link = BLESerialTransport(identifier: uuid, binding: .bleKISS)
        link.onDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.errorText = "The KISS adapter disconnected."
                self.stop()
            }
        }
        kissLink = link
        isRunning = true
        AudioActivity.begin()
        status = "Connecting to \(settings.bleName.isEmpty ? "adapter" : settings.bleName)…"
        Task {
            do {
                try await link.connect()
            } catch {
                errorText = "Couldn't connect to the KISS adapter: \(error.localizedDescription)"
                stop()
                return
            }
            status = "Connected — radio TNC (KISS)"
            // KISS parameters: TXDELAY (10 ms units), persistence, slot time.
            try? await link.send(KISS.encode([UInt8(clamping: settings.txDelayMs / 10)], command: 0x01))
            try? await link.send(KISS.encode([UInt8(clamping: settings.persistence)], command: 0x02))
            try? await link.send(KISS.encode([UInt8(clamping: settings.slotTimeMs / 10)], command: 0x03))
            await tuneBBLink(for: satellite)
            // Runs until stop() cancels it (that also releases its hold on self).
            kissReader = Task {
                while !Task.isCancelled {
                    let bytes = await link.readAvailable(maxWait: 0.5)
                    guard !bytes.isEmpty else { continue }
                    for f in self.kissDecoder.feed(bytes) where f.command == 0 {
                        if let frame = AX25Frame.decode(f.data) { self.received(frame) }
                    }
                }
            }
        }
    }

    /// B.B. Link extended hardware command: set the radio's frequency (KISS command 6,
    /// `EA` + 32-bit big-endian Hz). The adapter leaves KISS, sets FM + frequency on the
    /// data VFO and re-enters KISS, so this is for occasional moves only.
    func tuneBBLink(for satellite: SatelliteRecord?) async {
        guard settings.transport == .bleKISS, settings.bbLinkTune, let link = kissLink, let satellite,
              tunedForSatellite != satellite.id, let tp = packetTransponder(for: satellite) else { return }
        let hz = UInt32(clamping: tp.downlinkCenter)
        guard hz > 0 else { return }
        let cmd: [UInt8] = [0xEA, UInt8(hz >> 24), UInt8((hz >> 16) & 0xFF), UInt8((hz >> 8) & 0xFF), UInt8(hz & 0xFF)]
        try? await link.send(KISS.encode(cmd, command: 0x06))
        tunedForSatellite = satellite.id
        status = "Connected — radio on \(ODFormat.frequency(tp.downlinkCenter))"
    }

    // MARK: Receive

    private func received(_ frame: AX25Frame) {
        // Half duplex: ignore what the receiver picks up while we transmit (a phone
        // mic or a monitoring radio hears our own audio) and during turnaround.
        if Date() < rxBlankedUntil, !isFullDuplex(for: store?.selectedSatellite) { return }
        let aprs = APRS.parse(frame.infoText, destination: frame.destination.call)
        var entry = PacketLogEntry(date: Date(), direction: .received, frame: frame, aprs: aprs,
                                   text: Self.displayText(frame: frame, aprs: aprs))
        classify(&entry)
        if let me = myAddress, frame.source == me {
            // Our own frame came back. Match it to the send it copies.
            recentSends.removeAll { Date().timeIntervalSince($0.date) > 120 }
            if let i = recentSends.lastIndex(where: { $0.info == frame.info }) {
                let delay = Date().timeIntervalSince(recentSends[i].date)
                if frame.wasDigipeated || delay >= 0.5 {
                    entry.ownDigipeated = true
                    heardSelfViaSatellite = true
                    if let j = log.firstIndex(where: { $0.id == recentSends[i].logID }), log[j].digipeatDelay == nil {
                        log[j].digipeatDelay = delay
                        delays.append(delay)
                        updateStats()
                        for station in stationsNamed(by: log[j]) {
                            if let done = qsoTracker.digipeated(to: station, at: Date()) { autoLog(station, done) }
                        }
                    }
                } else {
                    return      // our own audio echoing straight back, not the satellite
                }
            } else if frame.wasDigipeated {
                entry.ownDigipeated = true; heardSelfViaSatellite = true
            }
        } else {
            noteHeard(frame, aprs: aprs, isCQ: entry.isCQ)
            let namesMe = entry.toMe || myAddress.map { PacketText.mentions($0.call, in: entry.text) } ?? false
            if let done = qsoTracker.heard(from: frame.source.description, mentioningMe: namesMe,
                                           text: entry.text, at: Date()) {
                autoLog(frame.source.description, done)
            }
        }
        if entry.toMe {
            if aprs.kind == .ack, let id = aprs.messageID, let logID = pendingAcks.removeValue(forKey: id),
               let i = log.firstIndex(where: { $0.id == logID }) {
                log[i].acked = true
            }
            if aprs.kind == .message, settings.autoAck, let id = aprs.messageID {
                send(info: APRS.ack(to: frame.source.description, id: id))
            }
        }
        append(entry)
    }

    /// Tag a log entry: to me, CQ, telemetry, beacon.
    private func classify(_ entry: inout PacketLogEntry) {
        let frame = entry.frame, aprs = entry.aprs
        let text = entry.text
        if let me = myAddress {
            let to = aprs.addressee.uppercased()
            let addressedAPRS = (aprs.kind == .message || aprs.kind == .ack || aprs.kind == .reject)
                && (to == me.description || to == me.call)
            let addressedPlain = frame.destination.call == me.call      // UISS text to our call
            entry.toMe = addressedAPRS || addressedPlain
        }
        entry.isCQ = frame.destination.call == "CQ" || PacketText.isCQ(text)
        entry.isTelemetry = aprs.kind == .telemetry || frame.infoText.contains("[TLM")
        entry.isBeacon = !entry.toMe && !entry.isCQ && (aprs.kind == .position || aprs.kind == .micE || aprs.kind == .status)
    }

    /// What a frame says, for the log: APRS message/status/comment, else the text.
    static func displayText(frame: AX25Frame, aprs: APRSPacket) -> String {
        switch aprs.kind {
        case .message: return aprs.text
        case .ack: return "ack \(aprs.messageID ?? "")"
        case .reject: return "rej \(aprs.messageID ?? "")"
        case .status, .telemetry, .position, .micE: return aprs.comment.trimmingCharacters(in: .whitespaces)
        case .other: return frame.infoText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func noteHeard(_ frame: AX25Frame, aprs: APRSPacket, isCQ: Bool) {
        let call = frame.source.description
        let grid = aprs.grid ?? PacketText.grid(in: frame.infoText)
            ?? aprs.latitude.flatMap { lat in aprs.longitude.map { FeatureEngine.latLonToGrid6(latitude: lat, longitude: $0) } }
        if let i = heard.firstIndex(where: { $0.call == call }) {
            heard[i].lastHeard = Date(); heard[i].frames += 1
            if isCQ { heard[i].cqs += 1 }
            if let grid { heard[i].grid = grid }
            if let lat = aprs.latitude, let lon = aprs.longitude { heard[i].latitude = lat; heard[i].longitude = lon }
            if frame.wasDigipeated { heard[i].viaDigipeater = true }
            if let code = aprs.symbolCode { heard[i].symbolTable = aprs.symbolTable; heard[i].symbolCode = code }
        } else {
            var station = PacketHeardStation(call: call, firstHeard: Date(), lastHeard: Date(), grid: grid,
                                             latitude: aprs.latitude, longitude: aprs.longitude,
                                             viaDigipeater: frame.wasDigipeated,
                                             symbolTable: aprs.symbolTable, symbolCode: aprs.symbolCode)
            if isCQ { station.cqs = 1 }
            if station.latitude == nil, let g = grid, let c = PacketText.gridCenter(g) {
                station.latitude = c.latitude; station.longitude = c.longitude
            }
            heard.append(station)
        }
        heard.sort { $0.lastHeard > $1.lastHeard }
    }

    private func append(_ entry: PacketLogEntry) {
        log.append(entry)
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    func clearLog() { log.removeAll() }
    func clearHeard() { heard.removeAll() }

    private func updateStats() {
        let sorted = delays.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        stats = (sent: stats.sent, digipeated: delays.count, medianDelay: median)
    }

    /// Log a QSO with a heard station (mode PKT), using the grid it sent.
    func logQSO(with call: String, reportSent: String? = nil, reportReceived: String? = nil, notes: String = "") {
        guard let qso, let store, let i = heard.firstIndex(where: { $0.call == call }) else { return }
        let sat = store.selectedSatellite
        var q = QSORecord.prefilled(satellite: sat, transponder: sat.flatMap { packetTransponder(for: $0) },
                                    myGrid: store.operatorGrid6, myCall: qso.config.myCall, defaultRst: "59")
        q.mode = "PKT"
        q.call = PacketText.baseCall(call)
        q.grid = heard[i].grid.map { String($0.prefix(4)) } ?? ""
        if let reportSent { q.rstSent = reportSent }
        if let reportReceived { q.rstRcvd = reportReceived }
        q.notes = notes
        qso.add(q)
        heard[i].logged = true
    }

    /// Stations one of our frames is addressed to or names: the APRS addressee,
    /// a UISS destination call, or heard calls in the text.
    private func stationsNamed(by entry: PacketLogEntry) -> [String] {
        var out: [String] = []
        let aprs = entry.aprs
        if [.message, .ack, .reject].contains(aprs.kind), !aprs.addressee.isEmpty { out.append(aprs.addressee) }
        let dest = entry.frame.destination.call
        if aprs.kind == .other, dest != "CQ", dest != Self.tocall { out.append(dest) }
        for station in heard where PacketText.mentions(station.call, in: entry.text) { out.append(station.call) }
        var seen = Set<String>()
        return out.filter { seen.insert(PacketText.baseCall($0)).inserted }
    }

    /// Log a completed exchange, unless the operator already logged this station
    /// on this satellite within the last 30 minutes.
    private func autoLog(_ station: String, _ contact: PacketQSOTracker.Contact) {
        guard settings.autoLogQSOs, let qso else { return }
        let base = PacketText.baseCall(station)
        let satName = store?.selectedSatellite?.name ?? ""
        let recent = qso.qsos.contains {
            $0.call.uppercased() == base && $0.sat == satName && Date().timeIntervalSince($0.utc) < 30 * 60
        }
        guard !recent else { return }
        // The heard list is keyed by the full call; the frame may use another SSID.
        guard let call = heard.first(where: { PacketText.baseCall($0.call) == base })?.call else { return }
        logQSO(with: call, reportSent: contact.reportSent, reportReceived: contact.reportReceived,
               notes: "Logged automatically by the packet terminal")
        lastAutoLogged = (base, Date())
    }

    // MARK: Transmit

    /// Expand a quick message's placeholders. `{POSITION}` is handled by the caller.
    func expand(_ macro: String, to: String) -> String {
        let heardList = heard.prefix(12).map(\.call).joined(separator: " ")
        return macro
            .replacingOccurrences(of: "{MYCALL}", with: myAddress?.description ?? myCall)
            .replacingOccurrences(of: "{MYGRID4}", with: String(myGrid.prefix(4)))
            .replacingOccurrences(of: "{MYGRID}", with: myGrid)
            .replacingOccurrences(of: "{CALL}", with: to.uppercased())
            .replacingOccurrences(of: "{HEARD}", with: heardList.isEmpty ? "QRV" : "Heard: \(heardList)")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Send what's in the compose box using the satellite's message format.
    func sendText(_ text: String, to: String) {
        let body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        let addressee = to.trimmingCharacters(in: .whitespaces).uppercased()
        let broadcast = addressee.isEmpty || ["CQ", "ALL", "QST"].contains(addressee)
        let format = profile(for: store?.selectedSatellite?.id).format
        switch format {
        case .plainText:
            // UISS unproto: destination = To (CQ when blank or not a callsign).
            let dest = AX25Address(broadcast ? "CQ" : addressee) ?? AX25Address(call: "CQ")
            send(info: body, destination: dest)
        case .aprs:
            if broadcast {
                send(info: APRS.status(body))
            } else if settings.requestAcks {
                messageNumber = messageNumber % 99 + 1
                let id = String(messageNumber)
                if let logID = send(info: APRS.message(to: addressee, text: body, id: id)) { pendingAcks[id] = logID }
            } else {
                send(info: APRS.message(to: addressee, text: body))
            }
        }
    }

    func sendPosition() {
        guard let store else { return }
        let o = store.preferences.observer
        var comment = settings.beaconComment.trimmingCharacters(in: .whitespaces)
        if comment.isEmpty { comment = String(store.operatorGrid6.prefix(4)) + " via OrbitDeck" }
        comment = expand(comment, to: "")
        var lat = o.latitude, lon = o.longitude
        if settings.positionPrecision == .gridCenter, let c = PacketText.gridCenter(String(store.operatorGrid6.prefix(4))) {
            lat = c.latitude; lon = c.longitude
        }
        send(info: APRS.position(latitude: lat, longitude: lon,
                                 symbolTable: settings.symbolTable.first ?? "/",
                                 symbolCode: settings.symbolCode.first ?? "`",
                                 comment: String(comment.prefix(43)),
                                 ambiguity: settings.positionPrecision.ambiguity))
    }

    /// Queue a UI frame. Returns the log entry's id. `destination` defaults to our
    /// APRS tocall; plain-text (UISS) frames use CQ or the station's call.
    @discardableResult
    func send(info: String, destination: AX25Address? = nil) -> UUID? {
        guard isRunning, let me = myAddress else { return nil }
        if settings.blockBelowHorizon, let el = satelliteElevation(), el < 0 {
            errorText = "\(store?.selectedSatellite?.name ?? "The satellite") is below the horizon — not transmitting."
            return nil
        }
        errorText = ""
        let path = profile(for: store?.selectedSatellite?.id).path
        let digis = path.split(separator: ",").compactMap { AX25Address(String($0)) }.prefix(2)
        let frame = AX25Frame(destination: destination ?? AX25Address(call: Self.tocall), source: me,
                              digipeaters: Array(digis), info: Array(info.utf8))
        let aprs = APRS.parse(info, destination: frame.destination.call)
        var entry = PacketLogEntry(date: Date(), direction: .sent, frame: frame, aprs: aprs,
                                   text: Self.displayText(frame: frame, aprs: aprs))
        classify(&entry); entry.toMe = false
        append(entry)
        for station in stationsNamed(by: entry) { qsoTracker.sent(to: station, text: entry.text, at: Date()) }
        recentSends.append((frame.info, Date(), entry.id))
        stats = (sent: stats.sent + 1, digipeated: stats.digipeated, medianDelay: stats.medianDelay)
        txQueue.append(frame)
        runTXQueue()
        return entry.id
    }

    private func runTXQueue() {
        guard !txRunning else { return }
        txRunning = true
        Task {
            while let frame = txQueue.first, isRunning {
                txQueue.removeFirst()
                switch settings.transport {
                case .bleKISS: await sendKISS(frame)
                case .builtInModem: await sendModem(frame)
                }
            }
            txRunning = false
        }
    }

    private func sendKISS(_ frame: AX25Frame) async {
        guard let link = kissLink else { return }
        do { try await link.send(KISS.encode(frame.encoded())) }
        catch { errorText = "Send failed: \(error.localizedDescription)" }
    }

    /// Wait for a clear channel, then p-persistence: transmit in a slot with
    /// probability (p+1)/256. Full duplex (crossband) skips the wait. Returns false
    /// if the channel stayed busy past the limit.
    private func waitForChannel() async -> Bool {
        if isFullDuplex(for: store?.selectedSatellite) { return true }
        let deadline = Date().addingTimeInterval(Double(max(1, settings.maxChannelWaitSeconds)))
        while Date() < deadline {
            if !channelBusy {
                if Int.random(in: 0...255) <= settings.persistence { return true }
            }
            try? await Task.sleep(nanoseconds: UInt64(max(10, settings.slotTimeMs)) * 1_000_000)
        }
        return false
    }

    private func sendModem(_ frame: AX25Frame) async {
        guard let source else { return }
        guard await waitForChannel() else {
            errorText = "Channel busy for \(settings.maxChannelWaitSeconds) s — frame not sent."
            return
        }
        let audioOut = runningModem == .g3ruh9600
            ? G3RUHModulator.transmission(frame, sampleRate: source.sampleRate,
                                          txDelayMs: settings.txDelayMs, amplitude: settings.outputLevel)
            : AFSKModulator.transmission(frame, sampleRate: source.sampleRate,
                                         txDelayMs: settings.txDelayMs, amplitude: settings.outputLevel)
        await transmit(audioOut, label: "Transmitting…")
    }

    /// Key, play `samples`, unkey — with a hard PTT watchdog that unkeys even if
    /// the playback path stalls.
    private func transmit(_ samples: [Float], label: String) async {
        guard let source else { return }
        // Receive-only transponder: never key or play TX audio (VOX would transmit it).
        if let why = rig?.pttBlockedReason { errorText = why; return }
        txLock.withLock { txBuffer = samples; txIndex = 0 }
        transmissionID += 1
        let thisTX = transmissionID
        isTransmitting = true
        status = label
        let keyed = rig?.pttSupported ?? false
        if keyed { await rig?.setPTT(true) }
        let watchdog = Double(max(1, settings.pttWatchdogSeconds))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(watchdog * 1_000_000_000))
            guard let self, self.isTransmitting, self.transmissionID == thisTX else { return }
            self.source?.stopPlayback()
            if keyed { await self.rig?.setPTT(false) }
            self.isTransmitting = false
            self.errorText = "PTT watchdog: unkeyed after \(Int(watchdog)) s."
        }
        do {
            try source.startPlayback(pull: { [weak self] n in self?.pullTX(n) ?? [] })
        } catch {
            errorText = error.localizedDescription
        }
        let seconds = min(watchdog, Double(samples.count) / source.sampleRate + 0.15)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard transmissionID == thisTX, isTransmitting else { return }
        source.stopPlayback()
        if keyed { await rig?.setPTT(false) }
        isTransmitting = false
        // Half duplex: blank our own echo plus a 150 ms turnaround guard.
        rxBlankedUntil = Date().addingTimeInterval(0.15)
        status = listeningStatus
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private var listeningStatus: String {
        let speed = runningModem == .g3ruh9600 ? "9600" : "1200"
        return (rig?.pttSupported ?? false) ? "Listening \(speed) — CAT PTT" : "Listening \(speed) — key by VOX"
    }

    /// 3 s test signal with PTT, for setting deviation into a dummy load: a mark tone
    /// for 1200 AFSK, scrambled flags (the real 9600 spectrum) for G3RUH.
    func sendTestTone() {
        guard isRunning, settings.transport == .builtInModem, let source, !isTransmitting else { return }
        let fs = source.sampleRate
        let tone: [Float]
        if runningModem == .g3ruh9600 {
            tone = G3RUHModulator.idle(seconds: 3, sampleRate: fs, amplitude: settings.outputLevel)
        } else {
            let step = 2 * Double.pi * 1200 / fs
            tone = (0..<Int(fs * 3)).map { Float(sin(Double($0) * step)) * settings.outputLevel }
        }
        Task { await transmit(tone, label: "Test signal…") }
    }

    private nonisolated func pullTX(_ n: Int) -> [Float] {
        txLock.lock(); defer { txLock.unlock() }
        let remaining = txBuffer.count - txIndex
        guard remaining > 0 else { return [] }
        let k = min(n, remaining)
        let out = Array(txBuffer[txIndex..<(txIndex + k)])
        txIndex += k
        return out
    }

    // MARK: Timed beacon

    /// Position beacon every N minutes while running and the satellite is up.
    private func restartBeacon() {
        beaconTask?.cancel(); beaconTask = nil
        let minutes = settings.beaconMinutes
        guard isRunning, minutes > 0 else { return }
        beaconTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(1, minutes)) * 60_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning else { return }
                if (self.satelliteElevation() ?? -1) >= 0 { self.sendPosition() }
            }
        }
    }
}
