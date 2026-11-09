import Foundation
import AVFoundation
import Combine

// ===========================================================================
//  PassRecorder.swift — record received pass audio to a compressed file
//
//  Consumes an `AudioSource` (USB or, later, Icom network audio) and streams the
//  mono Float blocks to a compressed AAC .m4a via AVAudioFile on a background queue
//  — no whole-clip RAM buffer. AAC is ~1/15 the size of 16-bit PCM WAV (a 10-min
//  pass is a few MB instead of ~60 MB) and plays everywhere. Each clip is tagged
//  with the satellite + UTC start and registered with the QSOStore for the Log.
//
//  A second instance (`PassRecorder.memo`) records short voice memos the same way:
//  the shared AudioHub capture with built-in-mic fallback, capped at `memoCap`, and on
//  stop it saves the clip and logs a QSO stub (prefilled by the caller) linked to it.
// ===========================================================================

@MainActor
final class PassRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Whole seconds recorded (published once a second — the card shows seconds).
    @Published private(set) var elapsed: TimeInterval = 0
    /// The 0…1 peak meter, on its own object so its 10 Hz updates only redraw the meter.
    let meters = LiveMeters()
    /// Recording input gain (linear); scales the captured audio into the file. Persisted.
    @Published var inputGain: Float {
        didSet { source?.inputGain = inputGain; AudioGainStore.save(gainKey, inputGain) }
    }
    @Published var errorText = ""

    /// The voice-memo recorder (separate from pass recording, so both can run at once).
    static let memo = PassRecorder(memo: true)
    /// Longest voice memo; recording stops on its own at this length.
    static let memoCap: TimeInterval = 120

    let isMemo: Bool
    private let gainKey: String
    private var memoStub: QSORecord?

    init(memo: Bool = false) {
        isMemo = memo
        gainKey = memo ? "orbitdeck.memo.inputGain" : "orbitdeck.recorder.inputGain"
        inputGain = AudioGainStore.load(gainKey)
    }

    private weak var qso: QSOStore?
    private var source: AudioSource?
    private var file: AVAudioFile?
    private var processingFormat: AVAudioFormat?
    // The AAC file is created lazily on the first captured frame (see write): creating it
    // in start() runs before the AudioSource has activated a recording-capable audio
    // session, so on a cold launch the encoder fails with '!dat' (OSStatus 560226676).
    private var recordURL: URL?
    private var recordRate: Double = 48_000
    private var fileCreateTried = false
    private let writeQueue = DispatchQueue(label: "org.orbitdeck.recorder.write")
    private var startDate: Date?
    private var sat = ""
    private var filename = ""
    private var meterTimer: DispatchSourceTimer?

    /// Set synchronously by stop() and cleared once the clip is finalized. `isRecording`
    /// is cleared asynchronously (after the write queue drains), so without this a second
    /// tap, an error or the memo cap racing a tap would run stop() twice.
    private var stopping = false
    /// Whether this session holds an `AudioActivity` reference; begin/end are balanced
    /// exactly once per session so other audio users' counts are never disturbed.
    private var activityHeld = false

    private let peakLock = NSLock()
    private var peak: Float = 0

    func attach(_ qso: QSOStore) { self.qso = qso }

    /// Start a voice memo (memo instance only). `stub` is the QSO logged with it when
    /// the memo is saved; the memo is tagged with the stub's satellite.
    func startMemo(source: AudioSource, qso: QSOStore, stub: QSORecord) {
        guard isMemo, !isRecording else { return }
        self.qso = qso
        memoStub = stub
        start(source: source, satellite: stub.sat)
        if !isRecording { memoStub = nil }
    }

    func start(source: AudioSource, satellite: String) {
        guard !isRecording, !stopping else { return }
        // Recording shares the AudioHub capture, so it can run alongside a decoder or the
        // monitor — no exclusive claim.
        errorText = ""
        self.source = source
        self.sat = satellite
        self.startDate = Date()
        filename = isMemo
            ? "memo_\(stamp(Date()))\(satellite.isEmpty ? "" : "_" + safe(satellite)).m4a"
            : "\(safe(satellite))_\(stamp(Date())).m4a"
        recordURL = QSOStore.recordingsDir.appendingPathComponent(filename)
        fileCreateTried = false
        file = nil; processingFormat = nil
        source.inputGain = inputGain

        source.onError = { [weak self] m in self?.errorText = m; self?.stop() }
        do {
            try source.start(onFrames: { [weak self] frames in self?.write(frames) })
        } catch {
            errorText = error.localizedDescription
            file = nil; self.source = nil
            return
        }
        // Capture rate AFTER start(): the shared-hub facade only reports its true rate once
        // attached (network audio is 16 kHz, not the 48 kHz default); reading it earlier
        // recorded network passes at the wrong rate/speed. The AAC file is created lazily on
        // the first frame, so setting it here (before frames flow) is race-free.
        recordRate = source.sampleRate

        isRecording = true
        if !activityHeld { AudioActivity.begin(); activityHeld = true }
        startMeter()
    }

    func stop() {
        guard isRecording, !stopping else { return }
        stopping = true
        source?.stop()
        source = nil
        if activityHeld { AudioActivity.end(); activityHeld = false }
        meterTimer?.cancel(); meterTimer = nil
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? elapsed
        let sat = self.sat, filename = self.filename, start = startDate ?? Date()
        let isMemo = self.isMemo, stub = memoStub
        memoStub = nil
        writeQueue.async { [weak self] in
            self?.file = nil     // finalize (AVAudioFile flushes on dealloc)
            // Only register a clip that was actually created (the lazy AAC create may have
            // failed, or no frames ever arrived).
            let exists = FileManager.default.fileExists(
                atPath: QSOStore.recordingsDir.appendingPathComponent(filename).path)
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.stopping = false
                self?.meters.setLevel(0)
                if duration >= 0.5, exists {
                    let entry = RecordingEntry(sat: sat, start: start, duration: duration, filename: filename,
                                               isMemo: isMemo ? true : nil)
                    if isMemo, var stub {
                        stub.utc = start          // the contact time is when the memo began
                        self?.qso?.addVoiceMemo(entry, stub: stub)
                    } else {
                        self?.qso?.addRecording(entry)
                    }
                }
            }
        }
    }

    // MARK: Writing

    private func write(_ frames: [Float]) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            // Lazily create the AAC file now that the AudioSource has an active,
            // recording-capable session (frames only flow once its engine is running), so
            // the encoder doesn't fail with '!dat' on a cold start. Try once.
            if self.file == nil {
                guard !self.fileCreateTried, let url = self.recordURL else { return }
                self.fileCreateTried = true
                // Belt-and-suspenders for the network-audio path, which brings up no
                // hardware session: ensure one is active before the encoder initializes.
                // Re-activating an already-active session (USB path) is a no-op.
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
                try? session.setActive(true)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: self.recordRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                do {
                    let f = try AVAudioFile(forWriting: url, settings: settings)
                    self.file = f
                    self.processingFormat = f.processingFormat
                } catch {
                    let msg = "Could not create the recording file: \(error.localizedDescription)"
                    ODLog.shared.log("recording: AAC file create failed: \(error)", category: "audio")
                    DispatchQueue.main.async { [weak self] in self?.errorText = msg; self?.stop() }
                    return
                }
            }
            guard let file = self.file, let fmt = self.processingFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames.count)
            if let ch = buffer.floatChannelData {
                frames.withUnsafeBufferPointer { src in ch[0].update(from: src.baseAddress!, count: frames.count) }
            }
            try? file.write(from: buffer)
            var p: Float = 0
            for s in frames { let a = abs(s); if a > p { p = a } }
            self.peakLock.lock(); if p > self.peak { self.peak = p }; self.peakLock.unlock()
        }
    }

    // MARK: Meter / elapsed

    private func startMeter() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, let start = self.startDate else { return }
            let now = Date().timeIntervalSince(start)
            if now.rounded(.down) != self.elapsed { self.elapsed = now.rounded(.down) }
            self.peakLock.lock(); let p = self.peak; self.peak = 0; self.peakLock.unlock()
            self.meters.decayLevel(peak: p)
            if self.isMemo, now >= Self.memoCap { self.stop() }
        }
        t.resume()
        meterTimer = t
    }

    private func safe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }).ifEmpty("SAT")
    }
    private func stamp(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "%04d%02d%02d-%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
