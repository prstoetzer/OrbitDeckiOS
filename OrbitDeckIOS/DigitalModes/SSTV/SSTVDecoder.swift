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
    private nonisolated(unsafe) var slantMirror: Double = 0
    private nonisolated(unsafe) var tuningMirror: Double = 0
    private nonisolated(unsafe) var contrastMirror: Double = 1
    private nonisolated(unsafe) var saturationMirror: Double = 1
    private nonisolated(unsafe) var hShiftMirror: Double = 0
    private nonisolated(unsafe) var autoTuneMirror = true
    private nonisolated(unsafe) var needsRedecode = false

    /// Input gain (linear) applied to captured audio. SSTV is FM, so this doesn't
    /// change the recovered colors directly, but it keeps a weak signal above the
    /// ADC/quantization noise floor (which *does* wash colors out). Receive-only —
    /// there is no transmit path, hence no output level.
    @Published var inputGain: Float = AudioGainStore.load("orbitdeck.sstv.inputGain") {
        didSet { source?.inputGain = inputGain; AudioGainStore.save("orbitdeck.sstv.inputGain", inputGain) }
    }
    /// Live input level (0…1) for the level meter.
    @Published private(set) var inputLevel: Float = 0
    private nonisolated(unsafe) var inPeak: Float = 0
    private nonisolated(unsafe) var levelSmoothed: Float = 0
    private nonisolated(unsafe) var levelTimer: DispatchSourceTimer?
    private let levelQueue = DispatchQueue(label: "org.orbitdeck.sstv.level")

    private weak var qso: QSOStore?
    private var source: AudioSource?
    private var satName = ""

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
    private nonisolated(unsafe) let lock = NSLock()
    private nonisolated(unsafe) let work = DispatchQueue(label: "org.orbitdeck.sstv.decode")

    // Decode progress (only touched on `work`).
    private nonisolated(unsafe) var phase: Phase = .searching
    private nonisolated(unsafe) var mode: SSTVMode?
    private nonisolated(unsafe) var imageStart = 0           // abs index of first image line
    private nonisolated(unsafe) var currentLine = 0
    private nonisolated(unsafe) var lastLineStart = 0.0      // abs sample index of the last line's sync (tracks clock drift)
    private nonisolated(unsafe) var rgba: [UInt8] = []
    private nonisolated(unsafe) var lastPublishedLine = -1
    // Robot 36 carries only one chroma component per line (R-Y even / B-Y odd);
    // hold the most recent of each to reconstruct color for every row.
    private nonisolated(unsafe) var r36Cr: [Double] = []
    private nonisolated(unsafe) var r36Cb: [Double] = []
    // Auto-tune (Doppler AFC) running estimate of the audio-frequency offset (Hz),
    // tracked from each line's sync pulse. `valid` snaps it on the first good line.
    private nonisolated(unsafe) var autoOffsetHz = 0.0
    private nonisolated(unsafe) var autoOffsetValid = false

    private enum Phase { case searching, decoding, done }

    /// A nonisolated init lets a throwaway instance be created off the main actor for
    /// offline re-decoding (see `decodeOffline`). All stored properties have defaults.
    nonisolated init() {}

    func attach(_ qso: QSOStore) { self.qso = qso }

    // MARK: Lifecycle

    func start(source: AudioSource, satellite: String) {
        guard !isListening else { return }
        // Only one input capture at a time (FT4/SSTV/recording each open their own engine).
        guard AudioActivity.claimCapture("SSTV") else {
            errorText = "Audio is in use by \(AudioActivity.captureHolder ?? "another feature"). Stop it first."
            return
        }
        errorText = ""; image = nil; modeName = ""; status = "Listening…"
        self.source = source; self.satName = satellite
        let forced = manualMode
        lock.lock()
        freq.removeAll(keepingCapacity: true); sampleBase = 0
        phase = .searching; mode = nil; imageStart = 0; currentLine = 0; rgba = []; lastPublishedLine = -1
        r36Cr = []; r36Cb = []
        slantMirror = slant; tuningMirror = tuningHz
        contrastMirror = contrast; saturationMirror = saturation; hShiftMirror = hShiftMs; needsRedecode = false
        autoTuneMirror = autoTune; autoOffsetHz = 0; autoOffsetValid = false
        forcedMode = forced
        lock.unlock()
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
            Task { @MainActor in self.inputLevel = v }
        }
        t.resume()
        levelTimer = t
    }

    func stop() {
        guard isListening else { return }
        source?.stop(); source = nil
        levelTimer?.cancel(); levelTimer = nil
        levelSmoothed = 0; inputLevel = 0
        isListening = false
        AudioActivity.end()
        AudioActivity.releaseCapture("SSTV")
        lock.lock(); let decoded = !rgba.isEmpty && currentLine > 0; lock.unlock()
        // Finalize the AAC recording; discard it if no image was decoded (nothing
        // references it, so it would just be an orphan file).
        let recorded = recURL
        recQueue.async { [weak self] in
            self?.recFile = nil
            if !decoded, let recorded { try? FileManager.default.removeItem(at: recorded) }
        }
        status = decoded ? "Stopped — decoded \(modeName)" : "Stopped"
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

    private nonisolated func pump() {
        lock.lock()
        let r = rate
        // Snapshot what we need; keep the lock only for buffer access below.
        var localPhase = phase
        lock.unlock()

        if localPhase == .searching {
            lock.lock()
            let base = sampleBase
            let f = freq
            let forced = forcedMode
            lock.unlock()
            if let hit = Self.findStart(f, rate: r, forced: forced) {
                let m = forced ?? SSTVModes.mode(forVIS: hit.vis) ?? SSTVModes.all[0]
                lock.lock()
                mode = m
                imageStart = base + hit.startIndex
                currentLine = 0
                lastLineStart = Double(base + hit.startIndex)
                rgba = [UInt8](repeating: 0, count: m.width * m.height * 4)
                r36Cr = [Double](repeating: 0.5, count: m.width)
                r36Cb = [Double](repeating: 0.5, count: m.width)
                autoOffsetHz = 0; autoOffsetValid = false
                needsRedecode = false
                phase = .decoding
                lock.unlock()
                Task { @MainActor in self.modeName = m.name; self.status = "Decoding \(m.name)…" }
                localPhase = .decoding
            } else {
                // Bound memory while searching: keep only the last ~2 s.
                lock.lock()
                let keep = Int(r * 2.0)
                if freq.count > keep { let drop = freq.count - keep; freq.removeFirst(drop); sampleBase += drop }
                lock.unlock()
                return
            }
        }

        if localPhase == .decoding {
            // A slant/tuning change requests a live re-decode of the current image
            // from the retained sample buffer.
            lock.lock()
            if needsRedecode, let m = mode {
                needsRedecode = false
                currentLine = 0
                lastLineStart = Double(imageStart)
                rgba = [UInt8](repeating: 0, count: m.width * m.height * 4)
                r36Cr = [Double](repeating: 0.5, count: m.width)
                r36Cb = [Double](repeating: 0.5, count: m.width)
                autoOffsetHz = 0; autoOffsetValid = false
                lastPublishedLine = -1
            }
            lock.unlock()
            decodeAvailableLines(rate: r)
        }
    }

    private nonisolated func decodeAvailableLines(rate r: Double) {
        while true {
            lock.lock()
            guard let m = mode else { lock.unlock(); return }
            // Slant correction: a positive/negative `slantMirror` stretches/compresses the
            // effective sample rate so each line lands on the true pixel boundaries.
            let effRate = r * (1.0 + slantMirror)
            let tuning = tuningMirror
            let lineSamples = m.lineMs / 1000.0 * effRate
            let transmitted = m.height / m.linesPerScan
            if currentLine >= transmitted { lock.unlock(); finishImage(); return }

            // Nominal start from the previous line + one line period (tracks drift);
            // the first line starts at the detected image start.
            let nominal = (currentLine == 0) ? Double(imageStart) : lastLineStart + lineSamples
            // Search window: wide on the first line (VIS timing is coarse), narrower
            // afterwards. Scale with line length — a long mode (PD) drifts more per
            // line than a short one (Robot), so a fixed window loses lock on PD.
            let searchW = (currentLine == 0) ? max(0.030 * effRate, lineSamples * 0.04)
                                             : max(0.006 * effRate, lineSamples * 0.02)
            let available = sampleBase + freq.count
            // Need enough samples to both search for the sync and decode the line.
            guard Double(available) >= nominal + searchW + lineSamples else { lock.unlock(); return }

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
            let effTuning = tuning + (autoTuneMirror ? autoOffsetHz : 0)

            let offset = Int(start) - sampleBase
            decodeLine(into: &rgba, mode: m, freqOffset: offset, effRate: effRate, tuning: effTuning,
                       contrast: contrastMirror, saturation: saturationMirror, hShift: hShiftMirror,
                       transmittedLine: currentLine)
            currentLine += 1
            // Safety cap: keep memory bounded on very long modes by trimming samples
            // that are safely behind the current decode point.
            let cap = Int(r * 300.0)
            if freq.count > cap {
                let safeAbs = Int(start)
                let drop = min(freq.count - cap, max(0, safeAbs - sampleBase))
                if drop > 0 { freq.removeFirst(drop); sampleBase += drop }
            }
            let line = currentLine
            let snapshot = rgba
            let w = m.width, h = m.height
            lock.unlock()

            // Publish a live preview every few lines.
            if line - lastPublishedLine >= 8 || line == transmitted {
                lastPublishedLine = line
                Task { @MainActor in self.image = Self.image(from: snapshot, width: w, height: h) }
            }
        }
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

    private nonisolated func finishImage() {
        lock.lock()
        let m = mode; let snapshot = rgba; let w = m?.width ?? 0; let h = m?.height ?? 0
        let startSec = rate > 0 ? Double(imageStart) / rate : 0
        phase = .searching; currentLine = 0; lastPublishedLine = -1
        // Keep searching for a subsequent image; drop old samples.
        let keep = Int(rate * 2.0)
        if freq.count > keep { let drop = freq.count - keep; freq.removeFirst(drop); sampleBase += drop }
        lock.unlock()
        guard let m, !snapshot.isEmpty else { return }
        Task { @MainActor in
            guard let img = Self.image(from: snapshot, width: w, height: h) else { return }
            self.image = img
            self.status = "Decoded \(m.name)"
            self.save(img, mode: m.name, startSec: startSec)
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

    // MARK: Line decode

    private nonisolated func decodeLine(into rgb: inout [UInt8], mode m: SSTVMode, freqOffset: Int,
                                       effRate: Double, tuning: Double, contrast: Double, saturation: Double,
                                       hShift: Double, transmittedLine tl: Int) {
        let w = m.width, h = m.height
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
        switch m.packing {
        case .perLine:
            if m.colorSpace == .rgb {
                let rC = chan[.r], gC = chan[.g], bC = chan[.b]
                for x in 0..<w { let (rr, g, b) = csRGB(rC?[x] ?? 0, gC?[x] ?? 0, bC?[x] ?? 0); put(tl, x, rr, g, b) }
            } else {
                let y0 = chan[.y0], cb = chan[.cb], cr = chan[.cr]
                for x in 0..<w { let (rr, g, b) = Self.ycbcr(cst(y0?[x] ?? 0), sat(cb?[x] ?? 0.5), sat(cr?[x] ?? 0.5)); put(tl, x, rr, g, b) }
            }
        case .pdDouble:
            let y0 = chan[.y0], y1 = chan[.y1], cb = chan[.cb], cr = chan[.cr]
            for x in 0..<w {
                let cbx = sat(cb?[x] ?? 0.5), crx = sat(cr?[x] ?? 0.5)
                let (r0, g0, b0) = Self.ycbcr(cst(y0?[x] ?? 0), cbx, crx); put(tl*2, x, r0, g0, b0)
                let (r1, g1, b1) = Self.ycbcr(cst(y1?[x] ?? 0), cbx, crx); put(tl*2+1, x, r1, g1, b1)
            }
        case .robot36:
            // One Y line + one chroma component this line (R-Y on even, B-Y on odd);
            // reuse the freshest of the other component from the neighbor line.
            let y0 = chan[.y0] ?? [Double](repeating: 0, count: w)
            let c = chan[.cb] ?? [Double](repeating: 0.5, count: w)
            if tl % 2 == 0 { r36Cr = c } else { r36Cb = c }
            for x in 0..<w {
                let cr = x < r36Cr.count ? r36Cr[x] : 0.5
                let cb = x < r36Cb.count ? r36Cb[x] : 0.5
                let (rr, g, b) = Self.ycbcr(cst(y0[x]), sat(cb), sat(cr)); put(tl, x, rr, g, b)
            }
        }
    }

    // MARK: Start detection

    /// Find the image start. Auto mode reads the VIS header; manual mode looks for a
    /// 1900 Hz leader + 1200 Hz start and uses the forced mode. Indices are relative
    /// to `f`.
    nonisolated static func findStart(_ f: [Float], rate: Double, forced: SSTVMode?) -> (vis: Int, startIndex: Int)? {
        let bit = Int(rate * 0.030)
        let leader = Int(rate * 0.100)
        guard f.count > leader + 12 * bit else { return nil }
        func avg(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(f.count, b); guard hi > lo else { return 0 }
            var s = 0.0; for k in lo..<hi { s += Double(f[k]) }; return s / Double(hi - lo)
        }
        var n = leader
        while n + 12 * bit < f.count {
            if abs(avg(n - leader, n) - 1900) < 90, abs(avg(n, n + bit) - 1200) < 100 {
                if forced != nil {
                    return (0, n + bit + bit)        // after start bit
                }
                var start = n + bit
                var code = 0
                for b in 0..<7 { if avg(start + b * bit, start + (b + 1) * bit) < 1200 { code |= (1 << b) } }
                start += 8 * bit + bit               // 7 data + parity + stop
                if SSTVModes.mode(forVIS: code) != nil { return (code, start) }
            }
            n += bit
        }
        return nil
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
    /// image with different slant / auto-tune. Reuses the same demod, sync-lock and
    /// line-decode as the live path but runs to completion and returns the image
    /// instead of publishing/saving. Runs on a throwaway decoder instance, so it never
    /// touches the live decode state. Not tied to an AudioSource — no capture claim.
    nonisolated func decodeOffline(frames: [Float], rate r: Double, forced: SSTVMode?,
                                   slant: Double, autoTune: Bool, tuning: Double) -> (image: UIImage, mode: String)? {
        var d = StreamingDemod(rate: r)
        let f = d.process(frames)
        guard let hit = Self.findStart(f, rate: r, forced: forced) else { return nil }
        let m = forced ?? SSTVModes.mode(forVIS: hit.vis) ?? SSTVModes.all[0]
        lock.lock()
        rate = r; freq = f; sampleBase = 0
        mode = m; imageStart = hit.startIndex; currentLine = 0
        lastLineStart = Double(hit.startIndex)
        rgba = [UInt8](repeating: 0, count: m.width * m.height * 4)
        r36Cr = [Double](repeating: 0.5, count: m.width)
        r36Cb = [Double](repeating: 0.5, count: m.width)
        slantMirror = slant; tuningMirror = tuning; autoTuneMirror = autoTune
        contrastMirror = 1; saturationMirror = 1; hShiftMirror = 0
        autoOffsetHz = 0; autoOffsetValid = false

        let effRate = r * (1.0 + slant)
        let lineSamples = m.lineMs / 1000.0 * effRate
        let transmitted = m.height / m.linesPerScan
        while currentLine < transmitted {
            let nominal = (currentLine == 0) ? Double(imageStart) : lastLineStart + lineSamples
            let searchW = (currentLine == 0) ? max(0.030 * effRate, lineSamples * 0.04)
                                             : max(0.006 * effRate, lineSamples * 0.02)
            let available = sampleBase + freq.count
            if Double(available) < nominal + searchW + lineSamples { break }
            let refined = refineSyncStart(nominal: nominal, mode: m, effRate: effRate, window: searchW)
            lastLineStart = refined.start
            if autoTune, let syncHz = refined.syncHz {
                let est = syncHz - 1200.0
                if autoOffsetValid { autoOffsetHz += 0.25 * (est - autoOffsetHz) }
                else { autoOffsetHz = est; autoOffsetValid = true }
            }
            let effTuning = tuning + (autoTune ? autoOffsetHz : 0)
            decodeLine(into: &rgba, mode: m, freqOffset: Int(refined.start) - sampleBase, effRate: effRate,
                       tuning: effTuning, contrast: 1, saturation: 1, hShift: 0, transmittedLine: currentLine)
            currentLine += 1
        }
        let snap = rgba; let w = m.width, h = m.height
        lock.unlock()
        guard let img = Self.image(from: snap, width: w, height: h) else { return nil }
        return (img, m.name)
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
