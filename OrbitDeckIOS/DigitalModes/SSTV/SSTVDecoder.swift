import Foundation
import AVFoundation
import UIKit
import Combine

// ===========================================================================
//  SSTVDecoder.swift — streaming SSTV receive decoder
//
//  Consumes an AudioSource and FM-demodulates the 1500–2300 Hz video subcarrier
//  incrementally (stateful quadrature demod at a 1900 Hz center). A state machine
//  searches for the VIS header (or, in manual mode, a leader tone) and then decodes
//  the image line-by-line as audio arrives, publishing the picture as it builds and
//  trimming consumed samples so memory stays bounded. Saves the finished image.
//
//  Robustness for weak satellite signals:
//   - The mode from the VIS header is verified against the measured line-sync period
//     over the first several lines (a weak Robot 36 header often reads as Robot 72).
//   - A damaged VIS header, or a picture joined mid-transmission with no header at
//     all, falls back to the satellite's expected modes (SSTVModes.expected), chosen
//     by line-sync period. A picture locked that way is placed at the bottom of the
//     frame when its end is heard, since that's where the received lines belong.
//   - Noisy lines (garbled sync, FM-discriminator clicks) are repaired by
//     interpolating from good neighbors; chroma is lightly smoothed (Robot/PD).
//   - Repeated copies of the same picture in one session are combined (median).
//
//  Experimental: timing uses the standard nominal model; on-air slant/tuning may
//  still be needed.
// ===========================================================================

/// Cross-feature hand-off of the live CAT Doppler residual (Hz) to the SSTV decoder,
/// for feed-forward tuning. RigController publishes the current commanded-vs-parked
/// downlink offset here each Doppler tick and clears it (0) when it stops or disconnects;
/// the SSTV decoder subtracts it per audio buffer. Defaults to 0 so an operator WITHOUT
/// CAT control (or with it idle) is completely unaffected. Thread-safe.
enum SSTVDopplerFeed {
    private nonisolated(unsafe) static var _hz = 0.0
    private static let lock = NSLock()
    static var currentHz: Double { lock.withLock { _hz } }
    static func set(_ hz: Double) { lock.withLock { _hz = hz } }
}

/// A leader + start-bit pattern found in the audio, with its decoded VIS code.
/// `parityOK` is false for a header whose parity bit disagrees (a bit was misread).
struct SSTVVISHit {
    let code: Int
    let startIndex: Int        // first sample after the stop bit (image start)
    let parityOK: Bool
    /// The mode named by a clean header (known code with good parity).
    var validMode: SSTVMode? { parityOK ? SSTVModes.mode(forVIS: code) : nil }
}

/// UserDefaults keys for the SSTV settings (own keys; defaults apply when missing).
private enum SSTVSettingsKey {
    static let chromaSmoothing = "orbitdeck.sstv.chromaSmoothing"
    static let autoArm = "orbitdeck.sstv.autoArm"
    static let autoMinElevation = "orbitdeck.sstv.autoMinElevation"
}

@MainActor
final class SSTVDecoder: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var image: UIImage?
    @Published private(set) var modeName = ""
    @Published private(set) var status = "Idle"
    @Published var errorText = ""
    /// nil = auto-detect from the VIS header; otherwise force this mode.
    @Published var manualMode: SSTVMode?

    /// Slant correction: fractional clock error (±). A small nonzero value stretches
    /// or compresses each line to straighten a slanted picture (like the "slant" knob
    /// in MMSSTV / Robot36). Applied to the current image and re-decoded live.
    @Published var slant: Double = 0 {
        didSet { lock.lock(); slantMirror = slant; needsRedecode = true; lock.unlock(); work.async { [weak self] in self?.pump() } }
    }
    /// Tuning (frequency) offset in Hz (±). Shifts the demodulated video frequency
    /// mapping to compensate for an off-frequency receiver (brightness/contrast shift).
    @Published var tuningHz: Double = 0 {
        didSet { lock.lock(); tuningMirror = tuningHz; needsRedecode = true; lock.unlock(); work.async { [weak self] in self?.pump() } }
    }
    /// Contrast (luminance gain around mid-gray) and color saturation — cosmetic
    /// post-processing applied during decode; changing either re-decodes live.
    @Published var contrast: Double = 1 {
        didSet { lock.lock(); contrastMirror = contrast; needsRedecode = true; lock.unlock(); work.async { [weak self] in self?.pump() } }
    }
    @Published var saturation: Double = 1 {
        didSet { lock.lock(); saturationMirror = saturation; needsRedecode = true; lock.unlock(); work.async { [weak self] in self?.pump() } }
    }
    /// Horizontal image shift (ms): nudges where each line's pixels are sampled to
    /// correct a left/right offset. Positive shifts the picture left.
    @Published var hShiftMs: Double = 0 {
        didSet { lock.lock(); hShiftMirror = hShiftMs; needsRedecode = true; lock.unlock(); work.async { [weak self] in self?.pump() } }
    }
    /// Automatic Doppler frequency tracking. Each scan line's 1200 Hz horizontal-sync
    /// pulse is a known reference; its measured frequency minus 1200 is the live audio
    /// offset, which is folded into the color mapping per line. This tracks the Doppler
    /// drift of a fast LEO through the pass (and each CAT dial step) so colors stay
    /// correct without a manual tuning knob. The `tuningHz` knob remains an added trim.
    @Published var autoTune: Bool = true {
        didSet { lock.lock(); autoTuneMirror = autoTune; needsRedecode = true; lock.unlock(); work.async { [weak self] in self?.pump() } }
    }
    /// Light spatial smoothing of the chroma channels (Robot / PD modes) to reduce the
    /// color speckle a noisy downlink leaves in the low-rate color scans. Persisted.
    @Published var chromaSmoothing: Bool = UserDefaults.standard.object(forKey: SSTVSettingsKey.chromaSmoothing) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(chromaSmoothing, forKey: SSTVSettingsKey.chromaSmoothing)
            lock.lock(); chromaMirror = chromaSmoothing; needsRedecode = true; lock.unlock()
            work.async { [weak self] in self?.pump() }
        }
    }
    private nonisolated(unsafe) var slantMirror: Double = 0
    private nonisolated(unsafe) var tuningMirror: Double = 0
    private nonisolated(unsafe) var contrastMirror: Double = 1
    private nonisolated(unsafe) var saturationMirror: Double = 1
    private nonisolated(unsafe) var hShiftMirror: Double = 0
    private nonisolated(unsafe) var autoTuneMirror = true
    private nonisolated(unsafe) var chromaMirror = true
    private nonisolated(unsafe) var needsRedecode = false

    /// Input gain (linear) applied to captured audio. SSTV is FM, so this doesn't
    /// change the recovered colors directly, but it keeps a weak signal above the
    /// ADC/quantization noise floor (which *does* wash colors out). Receive-only —
    /// there is no transmit path, hence no output level.
    @Published var inputGain: Float = AudioGainStore.load("orbitdeck.sstv.inputGain") {
        didSet { source?.inputGain = inputGain; AudioGainStore.save("orbitdeck.sstv.inputGain", inputGain) }
    }
    /// Live input level (0…1) for the level meter.
    private(set) lazy var meters = LiveMeters()   // lazy: the init is nonisolated
    private nonisolated(unsafe) var inPeak: Float = 0
    private nonisolated(unsafe) var levelSmoothed: Float = 0
    private nonisolated(unsafe) var levelTimer: DispatchSourceTimer?
    private let levelQueue = DispatchQueue(label: "org.orbitdeck.sstv.level")

    // MARK: Auto start/stop by elevation (settings + state; main actor)

    /// Arm decoding automatically: start when the selected satellite rises above
    /// `autoMinElevation`, stop once it sets. Persisted.
    @Published var autoArm: Bool = UserDefaults.standard.bool(forKey: SSTVSettingsKey.autoArm) {
        didSet {
            UserDefaults.standard.set(autoArm, forKey: SSTVSettingsKey.autoArm)
            autoAttempted = false
            updateAutoTimer()
        }
    }
    @Published var autoMinElevation: Double = UserDefaults.standard.object(forKey: SSTVSettingsKey.autoMinElevation) as? Double ?? 10 {
        didSet { UserDefaults.standard.set(autoMinElevation, forKey: SSTVSettingsKey.autoMinElevation) }
    }
    /// True while the current session was started by the elevation trigger (so it's
    /// the one stopped automatically at set).
    @Published private(set) var autoStarted = false
    /// The satellite an auto-started session is following (its set ends the session).
    private var autoRunningSatellite: SatelliteRecord?
    @Published private(set) var autoSatelliteName = ""
    /// Armed = auto start/stop is on, a satellite is targeted, and we're waiting for it.
    var isArmed: Bool { autoArm && !autoSatelliteName.isEmpty && !isListening }
    private var autoSatellite: SatelliteRecord?
    private weak var autoStore: OrbitStore?
    private var autoSourceFactory: (() -> AudioSource?)?
    /// One auto-start attempt per pass (a manual stop mid-pass isn't overridden).
    private var autoAttempted = false
    private nonisolated(unsafe) var autoTimer: DispatchSourceTimer?
    private let autoQueue = DispatchQueue(label: "org.orbitdeck.sstv.auto")

    private weak var qso: QSOStore?
    private var source: AudioSource?
    private var satName = ""
    /// Gallery entries for combined images this session, by copy group, so a newer
    /// combination (more copies) replaces the one it supersedes.
    private var combinedEntries: [Int: SSTVImageEntry] = [:]

    // Session audio recording, so a decoded image can be re-decoded later with
    // different slant/tuning (a full demod-domain fix). Written on `recQueue`; created
    // lazily on the first frame (like PassRecorder) so the encoder has an active
    // session. The whole listening session goes to one file; each image decoded in it
    // references the same recording.
    private let recQueue = DispatchQueue(label: "org.orbitdeck.sstv.rec")
    private nonisolated(unsafe) var recFile: AVAudioFile?
    private nonisolated(unsafe) var recFormat: AVAudioFormat?
    private nonisolated(unsafe) var recURL: URL?
    private nonisolated(unsafe) var recFilename = ""
    private nonisolated(unsafe) var recRate: Double = 48_000
    private nonisolated(unsafe) var recTried = false

    // Streaming state (touched on `work` and the audio thread; guarded by `lock`).
    private nonisolated(unsafe) var rate: Double = 48_000
    private nonisolated(unsafe) var freq: [Float] = []       // instantaneous frequency stream (Float: half the RAM of the retained image buffer, ample precision for 1200–2300 Hz)
    private nonisolated(unsafe) var sampleBase = 0           // abs index of freq[0]
    private nonisolated(unsafe) var demod = StreamingDemod(rate: 48_000)
    private nonisolated(unsafe) var forcedMode: SSTVMode?
    /// Modes the selected satellite is known to send (fallback for a damaged/missed VIS).
    private nonisolated(unsafe) var expectedModes: [SSTVMode] = []
    private nonisolated(unsafe) let lock = NSLock()
    private nonisolated(unsafe) let work = DispatchQueue(label: "org.orbitdeck.sstv.decode")

    // Decode progress (only touched on `work`, under `lock`).
    private nonisolated(unsafe) var phase: Phase = .searching
    private nonisolated(unsafe) var mode: SSTVMode?
    private nonisolated(unsafe) var imageStart = 0           // abs index of first image line
    private nonisolated(unsafe) var currentLine = 0
    private nonisolated(unsafe) var lastLineStart = 0.0      // abs sample index of the last line's sync (tracks clock drift)
    private nonisolated(unsafe) var rgba: [UInt8] = []
    private nonisolated(unsafe) var lastPublishedLine = -1
    // Per-pixel Y/Cb/Cr as decoded (after contrast/saturation), for YCbCr modes, so
    // chroma can be smoothed at render time.
    private nonisolated(unsafe) var yP: [Float] = []
    private nonisolated(unsafe) var cbP: [Float] = []
    private nonisolated(unsafe) var crP: [Float] = []
    /// Per transmitted line: true if the line was judged noisy/garbled (for repair).
    private nonisolated(unsafe) var lineBad: [Bool] = []
    // Robot 36 carries only one chroma component per line (R-Y even / B-Y odd);
    // hold the most recent of each to reconstruct color for every row.
    private nonisolated(unsafe) var r36Cr: [Double] = []
    private nonisolated(unsafe) var r36Cb: [Double] = []
    // Auto-tune (Doppler AFC) running estimate of the audio-frequency offset (Hz),
    // tracked from each line's sync pulse. `valid` snaps it on the first good line.
    private nonisolated(unsafe) var autoOffsetHz = 0.0
    private nonisolated(unsafe) var autoOffsetValid = false
    /// Mode still to be confirmed from the line-sync period (nil once settled).
    private nonisolated(unsafe) var pending: PendingMode?
    /// False when the picture was locked from line syncs alone (no VIS) — i.e. joined
    /// mid-transmission — so its lines are placed at the bottom when the end is heard.
    private nonisolated(unsafe) var lockedByVIS = true
    private nonisolated(unsafe) var missedSyncRun = 0
    private nonisolated(unsafe) var lastGoodLine = -1
    private nonisolated(unsafe) var lastGoodSyncAbs = 0.0
    private nonisolated(unsafe) var partialEnded = false
    /// Absolute sample index of the last line-sync lock scan while searching (throttle).
    private nonisolated(unsafe) var lastSyncScanAbs = 0
    // Finished pictures this session (only touched on `work`), for combining repeats.
    private nonisolated(unsafe) var sessionCopies: [SessionCopy] = []
    private nonisolated(unsafe) var nextCopyGroup = 0

    private enum Phase { case searching, decoding, done }

    /// A decoded mode awaiting verification against the measured line-sync period.
    /// `vis` is the mode a clean header named (nil for a damaged header); `candidates`
    /// are the modes it may be corrected to.
    private struct PendingMode {
        let vis: SSTVMode?
        let candidates: [SSTVMode]
        /// Damaged header whose code still names a known mode (accepted unverified if
        /// the sync period can't be measured, matching the pre-parity-check behavior).
        let knownCodeOnly: Bool
    }

    private struct SessionCopy {
        let mode: String
        let width: Int, height: Int
        let rgba: [UInt8]
        let group: Int
        /// Offset of this copy relative to its group's first copy: copy(x+dx, y+dy) ≈ ref(x, y).
        let dx: Int, dy: Int
    }

    private enum LineStep { case needMore, decoded, ended }
    private enum ResolveResult { case settled, needMore, changed, aborted }

    /// A nonisolated init lets a throwaway instance be created off the main actor for
    /// offline re-decoding (see `decodeOffline`). All stored properties have defaults.
    nonisolated init() {}

    func attach(_ qso: QSOStore) { self.qso = qso }

    // MARK: Lifecycle

    func start(source: AudioSource, satellite: String, noradID: UInt? = nil) {
        guard !isListening else { return }
        // Only one input capture at a time (FT4/SSTV/recording each open their own engine).
        guard AudioActivity.claimCapture("SSTV") else {
            errorText = "Audio is in use by \(AudioActivity.captureHolder ?? "another feature"). Stop it first."
            return
        }
        errorText = ""; image = nil; modeName = ""; status = "Listening…"
        self.source = source; self.satName = satellite
        combinedEntries = [:]
        let forced = manualMode
        let expected = SSTVModes.expected(norad: noradID, name: satellite)
        lock.lock()
        freq.removeAll(keepingCapacity: true); sampleBase = 0
        phase = .searching; mode = nil; imageStart = 0; currentLine = 0; rgba = []; lastPublishedLine = -1
        yP = []; cbP = []; crP = []; lineBad = []
        r36Cr = []; r36Cb = []
        pending = nil; lockedByVIS = true; missedSyncRun = 0; lastGoodLine = -1; partialEnded = false
        lastSyncScanAbs = 0
        slantMirror = slant; tuningMirror = tuningHz
        contrastMirror = contrast; saturationMirror = saturation; hShiftMirror = hShiftMs; needsRedecode = false
        autoTuneMirror = autoTune; autoOffsetHz = 0; autoOffsetValid = false
        chromaMirror = chromaSmoothing
        forcedMode = forced
        expectedModes = expected
        lock.unlock()
        work.async { [weak self] in self?.sessionCopies = []; self?.nextCopyGroup = 0 }
        source.inputGain = inputGain
        source.onError = { [weak self] m in self?.errorText = m }
        do {
            try source.start(onFrames: { [weak self] frames in self?.ingest(frames) })
        } catch {
            errorText = error.localizedDescription; self.source = nil
            AudioActivity.releaseCapture("SSTV")
            return
        }
        // Read the capture rate AFTER start(): the shared-hub facade only reports its true
        // rate once attached (network audio is 16 kHz, not the 48 kHz default), so reading it
        // earlier decoded network SSTV at the wrong rate. Frame delivery is asynchronous, so
        // re-creating the demod here — before any frame flows — is race-free (and the default
        // 48 kHz demod harmlessly covers any gap).
        self.rate = source.sampleRate
        lock.lock(); demod = StreamingDemod(rate: rate); lock.unlock()
        // Set up the session recording (lazy file create on the first frame).
        recFilename = "SSTVREC_\(Int(Date().timeIntervalSince1970)).m4a"
        recURL = QSOStore.sstvDir.appendingPathComponent(recFilename)
        recRate = rate; recFile = nil; recFormat = nil; recTried = false
        isListening = true
        AudioActivity.begin()
        scheduleLevelTimer()
    }

    /// Steady input-level meter on a GCD timer (like FT4). A MainActor Task.sleep
    /// loop gets starved by the frequent image-publish Tasks during decode, which
    /// made the meter jitter/flash; a dedicated timer stays smooth.
    private nonisolated func scheduleLevelTimer() {
        let t = DispatchSource.makeTimerSource(queue: levelQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let p = self.lock.withLock { () -> Float in let v = self.inPeak; self.inPeak = 0; return v }
            self.levelSmoothed = max(p, self.levelSmoothed * 0.75)   // fast attack, slow release
            let v = self.levelSmoothed
            Task { @MainActor in self.meters.setLevel(v) }
        }
        t.resume()
        levelTimer = t
    }

    func stop() {
        guard isListening else { return }
        source?.stop(); source = nil
        levelTimer?.cancel(); levelTimer = nil
        levelSmoothed = 0; meters.setLevel(0)
        isListening = false
        autoStarted = false
        autoRunningSatellite = nil
        AudioActivity.end()
        AudioActivity.releaseCapture("SSTV")
        lock.lock()
        let decoded = !rgba.isEmpty && currentLine > 0
        // A picture cut off by the stop (e.g. LOS) is still worth keeping if a useful
        // part of it was received; finish and save it as a partial.
        var savePartial = false
        if phase == .decoding, pending == nil, let m = mode {
            savePartial = currentLine >= Self.minimumLines(m)
        }
        lock.unlock()
        if savePartial { work.async { [weak self] in self?.finishImage(stopping: true) } }
        // Finalize the AAC recording; discard it if no image was decoded (nothing
        // references it, so it would just be an orphan file).
        let recorded = recURL
        recQueue.async { [weak self] in
            self?.recFile = nil
            if !decoded, let recorded { try? FileManager.default.removeItem(at: recorded) }
        }
        status = decoded ? "Stopped — decoded \(modeName)" : "Stopped"
    }

    // MARK: Auto start/stop by elevation

    /// Point the elevation trigger at the selected satellite (called by the Home card
    /// when it appears or the selection changes). Pass nil to disarm.
    func configureAuto(satellite: SatelliteRecord?, store: OrbitStore, makeSource: @escaping () -> AudioSource?) {
        if satellite?.id != autoSatellite?.id { autoAttempted = false }
        autoSatellite = satellite
        autoSatelliteName = satellite?.name ?? ""
        autoStore = store
        autoSourceFactory = makeSource
        updateAutoTimer()
    }

    private func updateAutoTimer() {
        let want = autoArm && autoSatellite != nil
        if want {
            if autoTimer == nil { scheduleAutoTimer() }
            autoTick()
        } else {
            autoTimer?.cancel(); autoTimer = nil
        }
    }

    /// GCD timer (created nonisolated, hops to the main actor to act) — like the level
    /// meter, never a MainActor sleep loop. The check is cheap (one SGP4 look).
    private nonisolated func scheduleAutoTimer() {
        let t = DispatchSource.makeTimerSource(queue: autoQueue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            Task { @MainActor in self?.autoTick() }
        }
        t.resume()
        autoTimer = t
    }

    private func autoTick() {
        guard autoArm, let sat = autoSatellite, let store = autoStore else { return }
        // Respect the card being hidden: no capture for a feature the operator turned off.
        if UserDefaults.standard.string(forKey: FeatureVisibility.sstvKey) == FeatureVisibility.off.rawValue { return }
        let observer = store.preferences.observer
        // Stop on the satellite that started the session, not whatever is selected now (a
        // new selection below the horizon must not cut a decode in progress).
        if isListening, autoStarted, let running = autoRunningSatellite {
            if let rel = try? OrbitPredictor.look(running, observer: observer).elevation, rel < 0 {
                stop()
                status = "Auto-stopped — \(running.name) set"
            }
            return
        }
        guard let el = try? OrbitPredictor.look(sat, observer: observer).elevation else { return }
        if el < 0 {
            autoAttempted = false          // re-arm for the next pass
            return
        }
        guard !isListening, !autoAttempted, el >= autoMinElevation else { return }
        autoAttempted = true
        guard let src = autoSourceFactory?() else {
            errorText = "Auto start: no audio interface available."
            return
        }
        start(source: src, satellite: sat.name, noradID: sat.id)
        if isListening {
            autoStarted = true
            autoRunningSatellite = sat
            status = "Auto-started — \(sat.name) above \(Int(autoMinElevation))°"
        }
    }

    // MARK: Ingest + pump

    private nonisolated func ingest(_ frames: [Float]) {
        var peak: Float = 0
        for s in frames { let a = abs(s); if a > peak { peak = a } }
        lock.lock()
        if peak > inPeak { inPeak = peak }
        var out = demod.process(frames)
        // Feed-forward Doppler: when CAT is actively tuning this downlink, subtract its
        // current commanded-vs-parked residual so a mid-image dial step is corrected
        // continuously (no color tear) instead of only at the next line's sync. The feed
        // is 0 whenever CAT isn't tuning, so a no-CAT decode is byte-for-byte unchanged.
        // Gated by auto-tune so a fully-manual decode stays raw.
        if autoTuneMirror {
            let ff = SSTVDopplerFeed.currentHz
            if ff != 0 { let f = Float(ff); for i in out.indices { out[i] -= f } }
        }
        freq.append(contentsOf: out)
        lock.unlock()
        recordAudio(frames)
        work.async { [weak self] in self?.pump() }
    }

    /// Append captured audio to the session recording (for later re-decode). Lazily
    /// creates the AAC file on the first frame, when the input session is active.
    private nonisolated func recordAudio(_ frames: [Float]) {
        recQueue.async { [weak self] in
            guard let self else { return }
            if self.recFile == nil {
                guard !self.recTried, let url = self.recURL,
                      let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.recRate, channels: 1, interleaved: false) else { return }
                self.recTried = true
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: self.recRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000
                ]
                self.recFile = try? AVAudioFile(forWriting: url, settings: settings)
                self.recFormat = fmt
            }
            guard let file = self.recFile, let fmt = self.recFormat,
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames.count)) else { return }
            buf.frameLength = AVAudioFrameCount(frames.count)
            if let ch = buf.floatChannelData {
                frames.withUnsafeBufferPointer { src in ch[0].update(from: src.baseAddress!, count: frames.count) }
            }
            try? file.write(from: buf)
        }
    }

    /// How a VIS hit becomes a decode: the mode to start with plus what (if anything)
    /// must still be verified from the line-sync period. nil = ignore the hit.
    private nonisolated static func startPlan(_ hit: SSTVVISHit, forced: SSTVMode?, expected: [SSTVMode]) -> (mode: SSTVMode, pending: PendingMode?)? {
        if let forced { return (forced, nil) }
        if let v = hit.validMode {
            // Clean header: verify against modes a single misread bit could have
            // turned it into (Robot 36 ↔ Robot 72) plus the satellite's usual modes.
            var alts = SSTVModes.oneBitNeighbors(ofVIS: v.vis)
            for e in expected where !alts.contains(e) { alts.append(e) }
            alts.removeAll { $0 == v }
            return (v, PendingMode(vis: v, candidates: alts, knownCodeOnly: false))
        }
        // Damaged header: try the satellite's expected modes, plus the mode the code
        // still names (bad parity) if any.
        var cands = expected
        let known = SSTVModes.mode(forVIS: hit.code)
        if let known, !cands.contains(known) { cands.append(known) }
        guard let first = cands.first else { return nil }
        return (first, PendingMode(vis: nil, candidates: cands, knownCodeOnly: expected.isEmpty && known != nil))
    }

    /// Seconds of audio kept while searching: enough for a VIS header, or — when there
    /// are candidate modes for a line-sync lock — several lines of the longest one.
    private nonisolated static func searchKeepSeconds(_ candidates: [SSTVMode]) -> Double {
        guard let longest = candidates.map(\.lineMs).max() else { return 2.0 }
        return min(9.0, max(2.0, 7.5 * longest / 1000.0 + 0.5))
    }

    private nonisolated func pump() {
        lock.lock()
        let r = rate
        // Snapshot what we need; keep the lock only for buffer access below.
        let localPhase = phase
        lock.unlock()

        if localPhase == .searching {
            lock.lock()
            let forced = forcedMode
            let expected = expectedModes
            let candidates = forced.map { [$0] } ?? expected
            // The VIS search only needs the recent tail (a header is ~0.6 s).
            let tailN = min(freq.count, Int(r * 2.5))
            let tail = Array(freq.suffix(tailN))
            let tailBase = sampleBase + freq.count - tailN
            let available = sampleBase + freq.count
            lock.unlock()

            var begun = false
            if let hit = Self.findStart(tail, rate: r, forced: forced),
               let plan = Self.startPlan(hit, forced: forced, expected: expected) {
                lock.lock()
                beginDecode(mode: plan.mode, start: tailBase + hit.startIndex, pending: plan.pending, byVIS: true)
                lock.unlock()
                begun = true
            } else if !candidates.isEmpty, Double(available - lastSyncScanAbs) >= r * 0.75 {
                // No (usable) VIS: look for a run of line syncs at a candidate mode's
                // period — a picture joined mid-transmission, or one whose header was lost.
                lastSyncScanAbs = available
                lock.lock()
                let f = freq; let base = sampleBase
                lock.unlock()
                if let sl = Self.findSyncLock(f, rate: r, candidates: candidates) {
                    lock.lock()
                    beginDecode(mode: sl.mode, start: base + sl.start, pending: nil, byVIS: false)
                    lock.unlock()
                    begun = true
                }
            }
            if !begun {
                // Bound memory while searching.
                lock.lock()
                let keep = Int(r * Self.searchKeepSeconds(candidates))
                if freq.count > keep { let drop = freq.count - keep; freq.removeFirst(drop); sampleBase += drop }
                lock.unlock()
                return
            }
        }

        lock.lock()
        let decoding = phase == .decoding
        // A slant/tuning change requests a live re-decode of the current image
        // from the retained sample buffer.
        if decoding, needsRedecode, let m = mode {
            needsRedecode = false
            resetImage(for: m)
        }
        lock.unlock()
        if decoding { decodeAvailableLines(rate: r) }
    }

    /// Start decoding `m` at absolute sample `start`. Caller holds `lock`.
    private nonisolated func beginDecode(mode m: SSTVMode, start: Int, pending p: PendingMode?, byVIS: Bool) {
        mode = m
        imageStart = start
        pending = p
        lockedByVIS = byVIS
        resetImage(for: m)
        needsRedecode = false
        phase = .decoding
        let label = (p != nil) ? "Checking mode…" : "Decoding \(m.name)\(byVIS ? "" : " (no VIS)")…"
        Task { @MainActor in self.modeName = m.name; self.status = label }
    }

    /// Clear the image + per-line state to (re)decode from `imageStart`. Caller holds `lock`.
    private nonisolated func resetImage(for m: SSTVMode) {
        currentLine = 0
        lastLineStart = Double(imageStart)
        rgba = [UInt8](repeating: 0, count: m.width * m.height * 4)
        if m.colorSpace == .ycbcr {
            yP = [Float](repeating: 0, count: m.width * m.height)
            cbP = [Float](repeating: 0.5, count: m.width * m.height)
            crP = [Float](repeating: 0.5, count: m.width * m.height)
        } else {
            yP = []; cbP = []; crP = []
        }
        lineBad = [Bool](repeating: false, count: m.height / m.linesPerScan)
        r36Cr = [Double](repeating: 0.5, count: m.width)
        r36Cb = [Double](repeating: 0.5, count: m.width)
        autoOffsetHz = 0; autoOffsetValid = false
        missedSyncRun = 0; lastGoodLine = -1; lastGoodSyncAbs = Double(imageStart); partialEnded = false
        lastPublishedLine = -1
    }

    private nonisolated func decodeAvailableLines(rate r: Double) {
        while true {
            lock.lock()
            guard phase == .decoding, let m0 = mode else { lock.unlock(); return }
            switch resolvePending(rate: r) {
            case .needMore:
                lock.unlock(); return
            case .aborted:
                lock.unlock()
                Task { @MainActor in self.modeName = ""; self.status = "Listening…" }
                return
            case .changed:
                if let m = mode {
                    let note = m == m0 ? "" : " (corrected from sync timing)"
                    Task { @MainActor in self.modeName = m.name; self.status = "Decoding \(m.name)\(note)…" }
                }
            case .settled:
                break
            }
            guard let m = mode else { lock.unlock(); return }
            let step = advanceLine(rate: r)
            switch step {
            case .needMore:
                lock.unlock(); return
            case .ended:
                lock.unlock(); finishImage(stopping: false); return
            case .decoded:
                break
            }
            // Safety cap: keep memory bounded on very long modes by trimming samples
            // that are safely behind the current decode point.
            let cap = Int(r * 300.0)
            if freq.count > cap {
                let safeAbs = Int(lastLineStart)
                let drop = min(freq.count - cap, max(0, safeAbs - sampleBase))
                if drop > 0 { freq.removeFirst(drop); sampleBase += drop }
            }
            let line = currentLine
            let transmitted = m.height / m.linesPerScan
            // Publish a live preview every few lines (rendered with repair/smoothing).
            var snapshot: [UInt8]?
            if line - lastPublishedLine >= 8 || line == transmitted {
                lastPublishedLine = line
                snapshot = Self.render(rgba, mode: m, y: yP, cb: cbP, cr: crP, lines: line, bad: lineBad,
                                       smooth: chromaMirror, rowShift: 0)
            }
            let w = m.width, h = m.height
            lock.unlock()
            if let snapshot {
                Task { @MainActor in self.image = Self.image(from: snapshot, width: w, height: h) }
            }
        }
    }

    /// Settle a pending mode from the line-sync period measured over the first several
    /// lines. Caller holds `lock`.
    private nonisolated func resolvePending(rate r: Double, final: Bool = false) -> ResolveResult {
        guard let p = pending, let current = mode else { return .settled }
        let all = [current] + p.candidates
        let longest = all.map(\.lineMs).max() ?? current.lineMs
        let span = Int(6.5 * longest / 1000.0 * r)
        let available = sampleBase + freq.count
        if available < imageStart + span, !final { return .needMore }
        let syncMs = all.map(Self.syncMs).min() ?? 9
        let a = imageStart - sampleBase - Int(0.02 * r)
        let dips = Self.syncDips(freq, from: a, to: a + span, rate: r, syncMs: syncMs)
        let measuredMs = Self.medianSpacing(dips).map { $0 / r * 1000.0 }
        var chosen: SSTVMode?
        if let v = p.vis {
            chosen = v
            if let ms = measuredMs {
                // A sync period that is a whole multiple of the header's mode is just
                // missed syncs; only a clear mismatch that fits a candidate corrects it.
                let ratio = ms / v.lineMs
                let multiple = (1...3).contains { abs(ratio - Double($0)) < 0.03 * Double($0) }
                if !multiple, let alt = Self.closestMode(ms, p.candidates, tolerance: 0.02) { chosen = alt }
            }
        } else if let ms = measuredMs {
            chosen = Self.closestMode(ms, p.candidates, tolerance: 0.03)
                ?? Self.closestMode(ms / 2, p.candidates, tolerance: 0.03)   // every other sync missed
        } else if p.knownCodeOnly {
            chosen = p.candidates.first
        }
        pending = nil
        guard let chosen else {
            // Not an SSTV picture we can place: drop its header and keep searching.
            phase = .searching
            mode = nil
            let drop = min(freq.count, max(0, imageStart - sampleBase))
            if drop > 0 { freq.removeFirst(drop); sampleBase += drop }
            lastSyncScanAbs = 0
            return .aborted
        }
        if chosen != current {
            mode = chosen
            resetImage(for: chosen)
        }
        return .changed
    }

    /// Decode the next transmitted line if its audio is available. Caller holds `lock`.
    private nonisolated func advanceLine(rate r: Double) -> LineStep {
        guard let m = mode else { return .ended }
        // Slant correction: a positive/negative `slantMirror` stretches/compresses the
        // effective sample rate so each line lands on the true pixel boundaries.
        let effRate = r * (1.0 + slantMirror)
        let lineSamples = m.lineMs / 1000.0 * effRate
        let transmitted = m.height / m.linesPerScan
        if currentLine >= transmitted { return .ended }

        // Nominal start from the previous line + one line period (tracks drift);
        // the first line starts at the detected image start.
        let nominal = (currentLine == 0) ? Double(imageStart) : lastLineStart + lineSamples
        // Search window: wide on the first line (VIS timing is coarse), narrower
        // afterward. Scale with line length — a long mode (PD) drifts more per
        // line than a short one (Robot), so a fixed window loses lock on PD.
        let searchW = (currentLine == 0) ? max(0.030 * effRate, lineSamples * 0.04)
                                         : max(0.006 * effRate, lineSamples * 0.02)
        let available = sampleBase + freq.count
        // Need enough samples to both search for the sync and decode the line.
        guard Double(available) >= nominal + searchW + lineSamples else { return .needMore }

        // Lock onto the horizontal sync pulse (the lowest-frequency part of the
        // line) so timing errors don't accumulate — the key to a clean image.
        let refined = refineSyncStart(nominal: nominal, mode: m, effRate: effRate, window: searchW)
        let start = refined.start
        lastLineStart = start

        // Auto-tune (Doppler AFC): the sync pulse is nominally 1200 Hz; its measured
        // frequency minus 1200 is the current audio offset. Track it smoothed and add
        // it to the tuning so colors follow Doppler through the pass. Held when this
        // line's sync wasn't confidently located.
        if autoTuneMirror, let syncHz = refined.syncHz {
            let est = syncHz - 1200.0
            if autoOffsetValid { autoOffsetHz += 0.25 * (est - autoOffsetHz) }
            else { autoOffsetHz = est; autoOffsetValid = true }
        }
        let effTuning = tuningMirror + (autoTuneMirror ? autoOffsetHz : 0)
        let syncOK = refined.syncHz != nil

        let offset = Int(start) - sampleBase
        let bad = decodeLine(into: &rgba, mode: m, freqOffset: offset, effRate: effRate, tuning: effTuning,
                             contrast: contrastMirror, saturation: saturationMirror, hShift: hShiftMirror,
                             transmittedLine: currentLine, syncOK: syncOK)
        if currentLine < lineBad.count { lineBad[currentLine] = bad }
        if syncOK { missedSyncRun = 0; lastGoodLine = currentLine; lastGoodSyncAbs = start }
        else { missedSyncRun += 1 }
        currentLine += 1

        // A picture locked from line syncs (no VIS) has no known start, so its end is
        // what places it: the signal stopping (syncs gone for a while) or the next
        // picture's VIS header means the transmission's last line has been heard.
        if !lockedByVIS {
            // ≥ 2 s of missing syncs: shorter dropouts (spin fades) happen mid-picture.
            let endRun = max(3, Int((2.0 / (m.lineMs / 1000.0)).rounded(.up)))
            if missedSyncRun >= endRun { partialEnded = true; return .ended }
            if !syncOK {
                let from = max(0, offset - Int(1.2 * r))
                let to = min(freq.count, offset + Int(lineSamples))
                if to - from > Int(0.5 * r), let hit = Self.findStart(Array(freq[from..<to]), rate: r, forced: nil),
                   hit.validMode != nil {
                    partialEnded = true
                    return .ended
                }
            }
        }
        return .decoded
    }

    /// Refine a line's start by locating the horizontal sync pulse (the lowest-
    /// frequency ~1200 Hz interval) within ±`window` samples of `nominal`, and report
    /// the pulse's measured frequency for the Doppler AFC. Returns `nominal` (and a nil
    /// syncHz) if no convincing dip is found (noise guard). Caller holds `lock`.
    private nonisolated func refineSyncStart(nominal: Double, mode m: SSTVMode, effRate: Double, window: Double) -> (start: Double, syncHz: Double?) {
        let syncMs = m.line.first(where: { $0.channel == .sync })?.ms ?? 5.0
        let syncSamples = max(2, Int(syncMs / 1000.0 * effRate))
        let W = Int(window)
        guard W > 0 else { return (nominal, nil) }
        let step = max(1, syncSamples / 40)
        var bestMean = Double.greatestFiniteMagnitude
        var bestOff = 0
        var off = -W
        while off <= W {
            let s = Int(nominal) + off - sampleBase
            if s >= 0, s + syncSamples <= freq.count {
                var sum = 0.0
                var k = s
                let end = s + syncSamples
                while k < end { sum += Double(freq[k]); k += 1 }
                let mean = sum / Double(syncSamples)
                if mean < bestMean { bestMean = mean; bestOff = off }
            }
            off += step
        }
        guard bestMean.isFinite else { return (nominal, nil) }
        // Accept the sync as a *relative* dip below the line's own average frequency,
        // NOT an absolute "< 1400 Hz". Doppler shifts the whole audio band, so on a
        // fast pass the sync can read ~1500 Hz+ — an absolute test rejected it, the
        // decoder lost per-line lock, and the picture slanted/tore. The sync is always
        // the lowest-frequency interval in a line, so a dip below the line mean is a
        // reliable, tuning-independent detector.
        let lineN = max(1, Int(m.lineMs / 1000.0 * effRate))
        let rs = Int(nominal) - sampleBase
        var refSum = 0.0, refCnt = 0, k = max(0, rs)
        let re = min(freq.count, rs + lineN)
        while k < re { refSum += Double(freq[k]); k += 1; refCnt += 1 }
        let lineMean = refCnt > 0 ? refSum / Double(refCnt) : 1900.0
        let isDip = bestMean < lineMean - 200.0 || bestMean < 1500.0
        guard isDip else { return (nominal, nil) }
        return (nominal + Double(bestOff), bestMean)
    }

    /// Fewest lines worth saving as a picture (shorter is most likely a false lock).
    private nonisolated static func minimumLines(_ m: SSTVMode) -> Int {
        max(8, (m.height / m.linesPerScan) / 20)
    }

    /// Finish the current picture: render (repair + smoothing + partial placement),
    /// save it, and combine it with earlier copies of the same picture. Runs on `work`.
    private nonisolated func finishImage(stopping: Bool) {
        lock.lock()
        guard phase == .decoding, let m = mode else { lock.unlock(); return }
        let transmitted = m.height / m.linesPerScan
        let lines = partialEnded ? max(0, lastGoodLine + 1) : min(currentLine, transmitted)
        // Joined mid-transmission and heard the end: the received lines are the
        // picture's last ones, so they belong at the bottom of the frame.
        let shiftLines = (!lockedByVIS && partialEnded) ? max(0, transmitted - lines) : 0
        let final: [UInt8]? = lines >= Self.minimumLines(m)
            ? Self.render(rgba, mode: m, y: yP, cb: cbP, cr: crP, lines: lines, bad: lineBad,
                          smooth: chromaMirror, rowShift: shiftLines * m.linesPerScan)
            : nil
        let partial = lines < transmitted
        let startSec = rate > 0 ? Double(imageStart) / rate : 0
        // Keep only the audio after the last decoded line, so the search neither
        // re-locks onto this picture's tail nor loses a header that followed it.
        let lineSamples = m.lineMs / 1000.0 * rate * (1.0 + slantMirror)
        let keepFrom = Int((partialEnded ? lastGoodSyncAbs : lastLineStart) + lineSamples)
        let drop = min(freq.count, max(0, keepFrom - sampleBase))
        if drop > 0 { freq.removeFirst(drop); sampleBase += drop }
        phase = stopping ? .done : .searching
        currentLine = 0; lastPublishedLine = -1; pending = nil; partialEnded = false
        lastSyncScanAbs = 0
        let w = m.width, h = m.height
        lock.unlock()
        guard let final else {
            if !stopping { Task { @MainActor in self.modeName = ""; self.status = "Listening…" } }
            return
        }
        let label = m.name + (partial ? " (partial)" : "")
        let combined = addSessionCopy(final, mode: m.name, width: w, height: h)
        Task { @MainActor in
            guard let img = Self.image(from: final, width: w, height: h) else { return }
            self.image = img
            self.status = self.isListening ? "Decoded \(label)" : "Stopped — saved \(label)"
            self.save(img, mode: label, startSec: startSec)
            if let combined, let cimg = Self.image(from: combined.rgba, width: w, height: h) {
                self.saveCombined(cimg, mode: m.name, copies: combined.count, group: combined.group)
            }
        }
    }

    @MainActor private func save(_ img: UIImage, mode: String, startSec: Double = 0) {
        guard let data = img.pngData() else { return }
        let name = "SSTV_\(Int(Date().timeIntervalSince1970)).png"
        let url = QSOStore.sstvDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            // Reference the session recording so this image can be re-decoded later.
            qso?.addSSTVImage(SSTVImageEntry(sat: satName, date: Date(), mode: mode, filename: name,
                                             audioFile: recFilename.isEmpty ? nil : recFilename,
                                             audioRate: recRate, audioStartSec: startSec))
        } catch { errorText = "Could not save image: \(error.localizedDescription)" }
    }

    /// Save a combination of repeated copies alongside the originals. A newer
    /// combination of the same picture (more copies) replaces this session's previous
    /// one; the individual copies are always kept.
    @MainActor private func saveCombined(_ img: UIImage, mode: String, copies: Int, group: Int) {
        guard let data = img.pngData() else { return }
        let name = "SSTV_\(Int(Date().timeIntervalSince1970))_combined\(copies).png"
        do {
            try data.write(to: QSOStore.sstvDir.appendingPathComponent(name))
            if let old = combinedEntries[group] { qso?.deleteSSTVImage(old) }
            let entry = SSTVImageEntry(sat: satName, date: Date(), mode: "\(mode) (combined ×\(copies))", filename: name)
            qso?.addSSTVImage(entry)
            combinedEntries[group] = entry
        } catch { errorText = "Could not save image: \(error.localizedDescription)" }
    }

    // MARK: Line decode

    /// Decode one transmitted line into `rgb` (and the Y/Cb/Cr planes for YCbCr modes).
    /// Returns true if the line looks noisy/garbled and should be repaired.
    private nonisolated func decodeLine(into rgb: inout [UInt8], mode m: SSTVMode, freqOffset: Int,
                                       effRate: Double, tuning: Double, contrast: Double, saturation: Double,
                                       hShift: Double, transmittedLine tl: Int, syncOK: Bool) -> Bool {
        let w = m.width, h = m.height
        // Line quality: the fraction of video samples far outside the 1500–2300 Hz band.
        // A clean FM signal stays inside it; when the signal sinks into the noise the
        // discriminator throws wild excursions ("clicks"). A missed sync plus a few
        // clicks, or many clicks alone, marks the line for repair.
        var videoMs = 0.0
        for seg in m.line { if seg.channel == .sync || seg.channel == .gap { videoMs += seg.ms } else { break } }
        var outN = 0, totN = 0
        do {
            let lo = Float(1100.0 + tuning), hi = Float(2700.0 + tuning)
            var k = max(0, freqOffset + Int(videoMs / 1000.0 * effRate))
            let kEnd = min(freq.count, freqOffset + Int(m.lineMs / 1000.0 * effRate))
            while k < kEnd { let v = freq[k]; if v < lo || v > hi { outN += 1 }; totN += 1; k += 2 }
        }
        let noise = totN > 0 ? Double(outN) / Double(totN) : 1
        let bad = noise > 0.10 || (!syncOK && noise > 0.04)

        // Cosmetic post-processing: contrast stretches luminance around mid-gray;
        // saturation scales chroma deviation from neutral.
        func cst(_ v: Double) -> Double { (v - 0.5) * contrast + 0.5 }
        func sat(_ v: Double) -> Double { (v - 0.5) * saturation + 0.5 }
        func csRGB(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            let rr = cst(r), gg = cst(g), bb = cst(b)
            let luma = 0.299 * rr + 0.587 * gg + 0.114 * bb
            return (luma + (rr - luma) * saturation, luma + (gg - luma) * saturation, luma + (bb - luma) * saturation)
        }
        // Average the instantaneous frequency across each pixel's whole sample window
        // (not a single point) — this is the main noise reduction. Black = 1500 Hz,
        // white = 2300 Hz; `tuning` shifts the mapping for an off-frequency receiver.
        func sampleValue(segOffsetMs: Double, segMs: Double, px: Int) -> Double {
            let t0 = segOffsetMs + Double(px) / Double(w) * segMs + hShift
            let t1 = segOffsetMs + Double(px + 1) / Double(w) * segMs + hShift
            var i0 = freqOffset + Int(t0 / 1000.0 * effRate)
            var i1 = freqOffset + Int(t1 / 1000.0 * effRate)
            if i1 <= i0 { i1 = i0 + 1 }
            i0 = max(0, i0); i1 = min(freq.count, i1)
            guard i1 > i0 else { return 0 }
            var s = 0.0; for k in i0..<i1 { s += Double(freq[k]) }
            let f = s / Double(i1 - i0)
            return max(0, min(1, (f - 1500.0 - tuning) / 800.0))
        }
        var chan: [SSTVChannel: [Double]] = [:]
        var offMs = 0.0
        for seg in m.line {
            if seg.channel == .sync || seg.channel == .gap { offMs += seg.ms; continue }
            var row = [Double](repeating: 0, count: w)
            for px in 0..<w { row[px] = sampleValue(segOffsetMs: offMs, segMs: seg.ms, px: px) }
            chan[seg.channel] = row
            offMs += seg.ms
        }
        func put(_ y: Int, _ x: Int, _ rr: Double, _ g: Double, _ b: Double) {
            guard y >= 0, y < h, x >= 0, x < w else { return }
            let o = (y * w + x) * 4
            rgb[o] = UInt8(max(0, min(255, rr * 255)))
            rgb[o+1] = UInt8(max(0, min(255, g * 255)))
            rgb[o+2] = UInt8(max(0, min(255, b * 255)))
            rgb[o+3] = 255
        }
        // YCbCr pixel: also kept in the planes so chroma can be smoothed at render.
        func putYC(_ y: Int, _ x: Int, _ Y: Double, _ cb: Double, _ cr: Double) {
            guard y >= 0, y < h, x >= 0, x < w else { return }
            let i = y * w + x
            if i < yP.count { yP[i] = Float(Y); cbP[i] = Float(cb); crP[i] = Float(cr) }
            let (rr, g, b) = Self.ycbcr(Y, cb, cr); put(y, x, rr, g, b)
        }
        switch m.packing {
        case .perLine:
            if m.colorSpace == .rgb {
                let rC = chan[.r], gC = chan[.g], bC = chan[.b]
                for x in 0..<w { let (rr, g, b) = csRGB(rC?[x] ?? 0, gC?[x] ?? 0, bC?[x] ?? 0); put(tl, x, rr, g, b) }
            } else {
                let y0 = chan[.y0], cb = chan[.cb], cr = chan[.cr]
                for x in 0..<w { putYC(tl, x, cst(y0?[x] ?? 0), sat(cb?[x] ?? 0.5), sat(cr?[x] ?? 0.5)) }
            }
        case .pdDouble:
            let y0 = chan[.y0], y1 = chan[.y1], cb = chan[.cb], cr = chan[.cr]
            for x in 0..<w {
                let cbx = sat(cb?[x] ?? 0.5), crx = sat(cr?[x] ?? 0.5)
                putYC(tl*2, x, cst(y0?[x] ?? 0), cbx, crx)
                putYC(tl*2+1, x, cst(y1?[x] ?? 0), cbx, crx)
            }
        case .robot36:
            // One Y line + one chroma component this line (R-Y on even, B-Y on odd);
            // reuse the freshest of the other component from the neighbor line. A noisy
            // line's chroma isn't kept, so it can't smear into the next line's color.
            let y0 = chan[.y0] ?? [Double](repeating: 0, count: w)
            let c = chan[.cb] ?? [Double](repeating: 0.5, count: w)
            if !bad { if tl % 2 == 0 { r36Cr = c } else { r36Cb = c } }
            for x in 0..<w {
                let cr = x < r36Cr.count ? r36Cr[x] : 0.5
                let cb = x < r36Cb.count ? r36Cb[x] : 0.5
                putYC(tl, x, cst(y0[x]), sat(cb), sat(cr))
            }
        }
        return bad
    }

    // MARK: Render (smoothing, repair, placement)

    /// Build the displayed/saved picture from the decoded buffers:
    ///  1. chroma smoothing — a light 3×3 binomial blur of Cb/Cr (YCbCr modes only),
    ///     using only good rows so a noisy line can't bleed color into its neighbors;
    ///  2. noisy-line repair — runs of up to three bad transmitted lines between good
    ///     ones are replaced by a linear blend of the good lines above and below;
    ///  3. placement — shift everything down `rowShift` rows (partial capture).
    nonisolated static func render(_ rgba: [UInt8], mode m: SSTVMode, y yP: [Float], cb cbP: [Float], cr crP: [Float],
                                   lines: Int, bad: [Bool], smooth: Bool, rowShift: Int) -> [UInt8] {
        let w = m.width, h = m.height, lps = m.linesPerScan
        guard rgba.count == w * h * 4 else { return rgba }
        var out = rgba
        let lines = min(lines, h / lps)
        let rowsDone = min(h, lines * lps)
        @inline(__always) func lineBad(_ t: Int) -> Bool { t < bad.count && bad[t] }
        @inline(__always) func rowOK(_ r: Int) -> Bool { r >= 0 && r < rowsDone && !lineBad(r / lps) }
        @inline(__always) func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v * 255))) }

        if smooth, m.colorSpace == .ycbcr, yP.count == w * h, cbP.count == w * h, crP.count == w * h {
            let kw: [Float] = [1, 2, 1]
            for r in 0..<rowsDone where rowOK(r) {
                for x in 0..<w {
                    var sCb: Float = 0, sCr: Float = 0, sW: Float = 0
                    for dy in -1...1 {
                        let rr = r + dy
                        guard rowOK(rr) else { continue }
                        let wy = kw[dy + 1]
                        for dx in -1...1 {
                            let xx = x + dx
                            guard xx >= 0, xx < w else { continue }
                            let wt = wy * kw[dx + 1], i = rr * w + xx
                            sCb += wt * cbP[i]; sCr += wt * crP[i]; sW += wt
                        }
                    }
                    guard sW > 0 else { continue }
                    let i = r * w + x
                    let (cr, cg, cb) = ycbcr(Double(yP[i]), Double(sCb / sW), Double(sCr / sW))
                    let o = i * 4
                    out[o] = u8(cr); out[o+1] = u8(cg); out[o+2] = u8(cb); out[o+3] = 255
                }
            }
        }

        var t = 0
        while t < lines {
            guard lineBad(t) else { t += 1; continue }
            var e = t
            while e + 1 < lines, lineBad(e + 1) { e += 1 }
            if e - t + 1 <= 3, t > 0, e + 1 < lines {
                let top = t * lps - 1, bottom = (e + 1) * lps
                let span = Double(bottom - top)
                for r in (top + 1)..<bottom {
                    let f = Double(r - top) / span
                    for x in 0..<w {
                        let a = (top * w + x) * 4, b = (bottom * w + x) * 4, o = (r * w + x) * 4
                        for c in 0..<3 {
                            out[o + c] = UInt8(max(0, min(255, (Double(out[a + c]) * (1 - f) + Double(out[b + c]) * f).rounded())))
                        }
                        out[o + 3] = 255
                    }
                }
            }
            t = e + 1
        }

        if rowShift > 0 {
            var shifted = [UInt8](repeating: 0, count: out.count)
            let rows = h - rowShift
            if rows > 0 { shifted.replaceSubrange(rowShift * w * 4 ..< h * w * 4, with: out[0 ..< rows * w * 4]) }
            out = shifted
        }
        return out
    }

    // MARK: Combining repeated copies

    /// Remember a finished picture and, if it matches an earlier copy (same mode, high
    /// correlation after a small alignment search), return the per-pixel combination of
    /// every copy in its group. Runs on `work`.
    private nonisolated func addSessionCopy(_ px: [UInt8], mode: String, width w: Int, height h: Int) -> (rgba: [UInt8], count: Int, group: Int)? {
        var best: (group: Int, dx: Int, dy: Int, corr: Double)?
        var seen = Set<Int>()
        for c in sessionCopies where c.mode == mode && c.width == w && c.height == h && !seen.contains(c.group) {
            seen.insert(c.group)      // compare against each group's first (reference) copy
            if let s = Self.similarity(c.rgba, px, width: w, height: h), s.corr >= 0.85, s.corr > (best?.corr ?? 0) {
                best = (c.group, s.dx, s.dy, s.corr)
            }
        }
        let group: Int
        if let best { group = best.group } else { group = nextCopyGroup; nextCopyGroup += 1 }
        sessionCopies.append(SessionCopy(mode: mode, width: w, height: h, rgba: px, group: group,
                                         dx: best?.dx ?? 0, dy: best?.dy ?? 0))
        // Bound memory: drop the oldest group once many pictures have accumulated.
        if sessionCopies.count > 16, let oldest = sessionCopies.first?.group, oldest != group {
            sessionCopies.removeAll { $0.group == oldest }
        }
        let members = sessionCopies.filter { $0.group == group }
        guard best != nil, members.count >= 2 else { return nil }
        return (Self.combine(members.map { ($0.rgba, $0.dx, $0.dy) }, width: w, height: h), members.count, group)
    }

    /// Luma correlation of `b` against reference `a` on a coarse grid, searching small
    /// offsets (b(x+dx, y+dy) ≈ a(x, y)). Only pixels decoded in both are compared, so
    /// a partial copy still matches. nil if too little overlaps.
    nonisolated static func similarity(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int) -> (corr: Double, dx: Int, dy: Int)? {
        guard a.count == w * h * 4, b.count == a.count, w > 0, h > 0 else { return nil }
        let gx = max(1, w / 48), gy = max(1, h / 36)
        let gridN = (w / gx) * (h / gy)
        func luma(_ p: [UInt8], _ x: Int, _ y: Int) -> Double? {
            let o = (y * w + x) * 4
            guard p[o + 3] == 255 else { return nil }
            return 0.299 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.114 * Double(p[o + 2])
        }
        func corr(_ dx: Int, _ dy: Int) -> Double? {
            var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let xb = x + dx, yb = y + dy
                    if xb >= 0, xb < w, yb >= 0, yb < h, let la = luma(a, x, y), let lb = luma(b, xb, yb) {
                        n += 1; sa += la; sb += lb; saa += la * la; sbb += lb * lb; sab += la * lb
                    }
                    x += gx
                }
                y += gy
            }
            guard n >= Double(gridN) / 4 else { return nil }
            let va = saa - sa * sa / n, vb = sbb - sb * sb / n
            guard va > 1e-6, vb > 1e-6 else { return nil }
            return (sab - sa * sb / n) / (va * vb).squareRoot()
        }
        var best: (corr: Double, dx: Int, dy: Int)?
        for dy in stride(from: -8, through: 8, by: 2) {
            for dx in stride(from: -8, through: 8, by: 2) {
                if let c = corr(dx, dy), c > (best?.corr ?? -2) { best = (c, dx, dy) }
            }
        }
        guard let coarse = best else { return nil }
        for dy in (coarse.dy - 1)...(coarse.dy + 1) {
            for dx in (coarse.dx - 1)...(coarse.dx + 1) where !(dx == coarse.dx && dy == coarse.dy) {
                if let c = corr(dx, dy), c > (best?.corr ?? -2) { best = (c, dx, dy) }
            }
        }
        return best
    }

    /// Per-pixel combination of aligned copies in the first copy's frame: the mean of
    /// two, the median of three or more (rejects a copy's local noise burst outright).
    /// Pixels missing from a copy (partial) are simply left out of that pixel's vote.
    nonisolated static func combine(_ copies: [(rgba: [UInt8], dx: Int, dy: Int)], width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let n = copies.count
        var vals = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: 3)
        for y in 0..<h {
            for x in 0..<w {
                var c = 0
                for cp in copies {
                    let xs = x + cp.dx, ys = y + cp.dy
                    guard xs >= 0, xs < w, ys >= 0, ys < h else { continue }
                    let o = (ys * w + xs) * 4
                    guard cp.rgba[o + 3] == 255 else { continue }
                    vals[0][c] = cp.rgba[o]; vals[1][c] = cp.rgba[o + 1]; vals[2][c] = cp.rgba[o + 2]
                    c += 1
                }
                guard c > 0 else { continue }
                let o = (y * w + x) * 4
                for ch in 0..<3 {
                    if c <= 2 {
                        out[o + ch] = UInt8((Int(vals[ch][0]) + Int(vals[ch][c - 1]) + 1) / 2)
                    } else {
                        vals[ch][0..<c].sort()
                        out[o + ch] = c % 2 == 1 ? vals[ch][c / 2]
                                                 : UInt8((Int(vals[ch][c / 2 - 1]) + Int(vals[ch][c / 2]) + 1) / 2)
                    }
                }
                out[o + 3] = 255
            }
        }
        return out
    }

    // MARK: Start detection

    /// Find a VIS header: a 1900 Hz leader followed by the 1200 Hz start bit, then 7
    /// data bits (LSB first; 1100 Hz = 1, 1300 Hz = 0), an even-parity bit and the stop
    /// bit. Returns the first clean header, else the first damaged one (unknown code or
    /// bad parity) so the caller can fall back to the satellite's expected modes. With a
    /// forced mode any header is accepted. Indices are relative to `f`.
    nonisolated static func findStart(_ f: [Float], rate: Double, forced: SSTVMode?) -> SSTVVISHit? {
        let bit = Int(rate * 0.030)
        let leader = Int(rate * 0.100)
        guard bit > 0, f.count > leader + 12 * bit else { return nil }
        // Prefix sums make every window average O(1), so the scan can step finely.
        var pre = [Double](repeating: 0, count: f.count + 1)
        for i in 0..<f.count { pre[i + 1] = pre[i] + Double(f[i]) }
        func avg(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(f.count, b); guard hi > lo else { return 0 }
            return (pre[hi] - pre[lo]) / Double(hi - lo)
        }
        let step = max(1, Int(rate * 0.001))
        let half = bit / 2, trim = bit / 6
        var firstDamaged: SSTVVISHit?
        var n = leader
        while n + 12 * bit < f.count {
            if abs(avg(n - leader, n) - 1900) < 90, abs(avg(n, n + bit) - 1200) < 100 {
                // Align on the leader → start-bit edge (largest step down in frequency).
                var s0 = n, bestEdge = -Double.greatestFiniteMagnitude
                var m = n - half
                while m <= n + half {
                    let e = avg(m - half, m) - avg(m, m + half)
                    if e > bestEdge { bestEdge = e; s0 = m }
                    m += max(1, step / 4)
                }
                // The start bit's own frequency is the 1200 Hz reference, so a small audio
                // offset (SSB mistuning) doesn't flip the 1100/1300 Hz bit decisions.
                let ref = avg(s0 + trim, s0 + bit - trim)
                let start = s0 + bit
                var code = 0, ones = 0
                for b in 0..<7 where avg(start + b * bit + trim, start + (b + 1) * bit - trim) < ref {
                    code |= (1 << b); ones += 1
                }
                let parityBit = avg(start + 7 * bit + trim, start + 8 * bit - trim) < ref
                let hit = SSTVVISHit(code: code, startIndex: start + 8 * bit + bit,   // 7 data + parity + stop
                                     parityOK: (ones + (parityBit ? 1 : 0)) % 2 == 0)
                if forced != nil || hit.validMode != nil { return hit }
                if firstDamaged == nil { firstDamaged = hit }
                n = s0 + 10 * bit                 // skip past this header
                continue
            }
            n += step
        }
        return firstDamaged
    }

    // MARK: Line-sync analysis (mode verification and VIS-less lock)

    nonisolated static func syncMs(_ m: SSTVMode) -> Double {
        m.line.first(where: { $0.channel == .sync })?.ms ?? 5.0
    }

    /// Positions (indices into `f`) of horizontal-sync pulses in `f[a..<b]`: runs where
    /// a sync-length moving average dips well below the span's typical frequency. The
    /// threshold is relative (Doppler-tolerant) and samples are clamped first so a
    /// discriminator click can't drag the reference down.
    nonisolated static func syncDips(_ f: [Float], from a: Int, to b: Int, rate: Double, syncMs: Double) -> [Int] {
        let lo = max(0, a), hi = min(f.count, b)
        let S = max(4, Int(syncMs / 1000.0 * rate))
        guard hi - lo > 4 * S else { return [] }
        let stride = max(1, Int(rate * 0.0005))
        var pre = [Double](repeating: 0, count: hi - lo + 1)
        for i in lo..<hi { pre[i - lo + 1] = pre[i - lo] + Double(min(2600, max(1000, f[i]))) }
        var ma: [Double] = [], pos: [Int] = []
        ma.reserveCapacity((hi - lo) / stride + 1); pos.reserveCapacity((hi - lo) / stride + 1)
        var i = lo
        while i + S <= hi { ma.append((pre[i + S - lo] - pre[i - lo]) / Double(S)); pos.append(i); i += stride }
        guard ma.count > 8 else { return [] }
        let sorted = ma.sorted()
        let floor = sorted[sorted.count / 100]
        let mean = ma.reduce(0, +) / Double(ma.count)
        guard mean - floor > 250 else { return [] }
        let thr = floor + 0.35 * (mean - floor)
        let minRun = max(1, Int(0.0015 * rate) / stride)
        var dips: [Int] = []
        var k = 0
        while k < ma.count {
            guard ma[k] < thr else { k += 1; continue }
            var e = k
            while e + 1 < ma.count, ma[e + 1] < thr { e += 1 }
            if e - k + 1 >= minRun {
                let c = (pos[k] + pos[e]) / 2
                if let last = dips.last, c - last < S {} else { dips.append(c) }
            }
            k = e + 1
        }
        return dips
    }

    /// Median spacing (samples) between consecutive sync dips — the line period, robust
    /// to an occasional missed or spurious sync.
    nonisolated static func medianSpacing(_ dips: [Int]) -> Double? {
        guard dips.count >= 4 else { return nil }
        let d = zip(dips.dropFirst(), dips).map { Double($0 - $1) }.sorted()
        return d[d.count / 2]
    }

    nonisolated static func closestMode(_ periodMs: Double, _ modes: [SSTVMode], tolerance: Double) -> SSTVMode? {
        modes.map { ($0, abs(periodMs / $0.lineMs - 1)) }
            .filter { $0.1 < tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// Lock onto a picture without a VIS header: find a run of line syncs whose spacing
    /// fits one of `candidates`. Requires ≥ 5 syncs on a consistent grid (one missed
    /// sync between neighbors allowed) so noise can't trigger it. Returns the mode and
    /// the index (in `f`) of the run's first sync.
    nonisolated static func findSyncLock(_ f: [Float], rate: Double, candidates: [SSTVMode]) -> (mode: SSTVMode, start: Int)? {
        guard let syncMs = candidates.map(syncMs).min() else { return nil }
        let dips = syncDips(f, from: 0, to: f.count, rate: rate, syncMs: syncMs)
        guard let med = medianSpacing(dips) else { return nil }
        let medMs = med / rate * 1000.0
        guard let m = closestMode(medMs, candidates, tolerance: 0.02) else { return nil }
        let P = m.lineMs / 1000.0 * rate
        let tol = 0.012 * P + 0.002 * rate
        var best: (first: Int, count: Int)?
        for i in dips.indices {
            var cur = dips[i], count = 1, spanLines = 0
            for j in (i + 1)..<dips.count {
                let d = Double(dips[j] - cur)
                if d > 2 * P + tol { break }
                for k in 1...2 where abs(d - Double(k) * P) < tol {
                    cur = dips[j]; count += 1; spanLines += k
                    break
                }
            }
            if count >= 5, count * 10 >= 6 * (spanLines + 1), count > (best?.count ?? 0) {
                best = (dips[i], count)
            }
        }
        guard let best else { return nil }
        return (m, best.first)
    }

    nonisolated static func ycbcr(_ y: Double, _ cb: Double, _ cr: Double) -> (Double, Double, Double) {
        let Y = y * 255.0, Cb = cb * 255.0 - 128.0, Cr = cr * 255.0 - 128.0
        return ((Y + 1.402 * Cr) / 255.0, (Y - 0.344136 * Cb - 0.714136 * Cr) / 255.0, (Y + 1.772 * Cb) / 255.0)
    }

    nonisolated static func image(from bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        var data = bytes
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs, bitmapInfo: info),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Offline re-decode (from a recording)

    /// Decode a whole buffer of captured audio in one pass, for re-decoding a saved
    /// image with different slant / auto-tune. Reuses the same demod, VIS/sync-lock,
    /// mode verification, line decode and render as the live path but runs to completion
    /// and returns the image instead of publishing/saving. Runs on a throwaway decoder
    /// instance, so it never touches the live decode state. Not tied to an AudioSource —
    /// no capture claim. `satellite` supplies the expected-mode fallback.
    nonisolated func decodeOffline(frames: [Float], rate r: Double, forced: SSTVMode?,
                                   slant: Double, autoTune: Bool, tuning: Double,
                                   satellite: String = "") -> (image: UIImage, mode: String)? {
        var d = StreamingDemod(rate: r)
        let f = d.process(frames)
        let expected = SSTVModes.expected(norad: nil, name: satellite)
        let candidates = forced.map { [$0] } ?? expected
        var plan: (mode: SSTVMode, start: Int, pending: PendingMode?, byVIS: Bool)?
        // The recording runs from just before the chosen picture to the end of the session,
        // so only look for its header near the start: a later picture's clean header must
        // not win (and a whole-session prefix sum would cost hundreds of MB).
        let head = Array(f.prefix(Int(r * 4)))
        if let hit = Self.findStart(head, rate: r, forced: forced), let p = Self.startPlan(hit, forced: forced, expected: expected) {
            plan = (p.mode, hit.startIndex, p.pending, true)
        } else if !candidates.isEmpty {
            // No header: scan the recording in overlapping windows for a line-sync lock.
            let win = Int(r * Self.searchKeepSeconds(candidates))
            var a = 0
            while a < f.count, plan == nil {
                let b = min(f.count, a + win)
                if let sl = Self.findSyncLock(Array(f[a..<b]), rate: r, candidates: candidates) {
                    plan = (sl.mode, a + sl.start, nil, false)
                }
                a += max(1, win / 2)
            }
        }
        guard let plan else { return nil }
        lock.lock()
        rate = r; freq = f; sampleBase = 0
        slantMirror = slant; tuningMirror = tuning; autoTuneMirror = autoTune
        contrastMirror = 1; saturationMirror = 1; hShiftMirror = 0
        chromaMirror = UserDefaults.standard.object(forKey: SSTVSettingsKey.chromaSmoothing) as? Bool ?? true
        beginDecodeOffline(mode: plan.mode, start: plan.start, pending: plan.pending, byVIS: plan.byVIS)
        if resolvePending(rate: r, final: true) == .aborted { lock.unlock(); return nil }
        while advanceLine(rate: r) == .decoded {}
        guard let m = mode else { lock.unlock(); return nil }
        let transmitted = m.height / m.linesPerScan
        let lines = partialEnded ? max(0, lastGoodLine + 1) : min(currentLine, transmitted)
        let shiftLines = (!lockedByVIS && partialEnded) ? max(0, transmitted - lines) : 0
        let snap = Self.render(rgba, mode: m, y: yP, cb: cbP, cr: crP, lines: lines, bad: lineBad,
                               smooth: chromaMirror, rowShift: shiftLines * m.linesPerScan)
        let w = m.width, h = m.height
        lock.unlock()
        guard let img = Self.image(from: snap, width: w, height: h) else { return nil }
        return (img, m.name + (lines < transmitted ? " (partial)" : ""))
    }

    /// `beginDecode` without the main-actor status publish (offline instance). Caller holds `lock`.
    private nonisolated func beginDecodeOffline(mode m: SSTVMode, start: Int, pending p: PendingMode?, byVIS: Bool) {
        mode = m; imageStart = start; pending = p; lockedByVIS = byVIS
        resetImage(for: m)
        phase = .decoding
    }
}

/// Stateful quadrature FM discriminator for streaming demodulation (1900 Hz center).
///
/// Mixes the video subcarrier to baseband, then runs I/Q through a CASCADED
/// one-pole lowpass. A single weak pole (the previous design) left the mixer sum
/// image (~1900+f, i.e. 3.4–4.2 kHz) and a wide noise band in the signal, which
/// biased the arctan frequency estimate toward the 1900 Hz center — the cause of
/// the noisy, washed-out picture. Three poles at ~900 Hz roll the image/noise off
/// ~34 dB while still passing the ±400 Hz video deviation.
struct StreamingDemod {
    let rate: Double
    private let w: Double
    private var phase = 0.0
    private var prevI = 0.0, prevQ = 0.0
    private let a: Double
    private let stages = 3
    private var fi: [Double]
    private var fq: [Double]

    init(rate: Double) {
        self.rate = rate
        self.w = 2.0 * Double.pi * 1900.0 / rate
        // Per-pole cutoff ≈ 900 Hz (one-pole: a = 1 − e^(−2π·fc/fs)).
        self.a = 1.0 - exp(-2.0 * Double.pi * 900.0 / rate)
        self.fi = [Double](repeating: 0, count: stages)
        self.fq = [Double](repeating: 0, count: stages)
    }

    mutating func process(_ x: [Float]) -> [Float] {
        var out = [Float](); out.reserveCapacity(x.count)
        let twoPi = 2.0 * Double.pi
        for s in x {
            let c = cos(phase), sn = sin(phase)
            phase += w; if phase > twoPi { phase -= twoPi }
            var i = Double(s) * c
            var q = -Double(s) * sn
            for k in 0..<stages { fi[k] += a * (i - fi[k]); i = fi[k] }
            for k in 0..<stages { fq[k] += a * (q - fq[k]); q = fq[k] }
            let dphi = atan2(q * prevI - i * prevQ, i * prevI + q * prevQ)
            prevI = i; prevQ = q
            out.append(Float(1900.0 + dphi * rate / twoPi))
        }
        return out
    }
}
