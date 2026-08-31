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
// ===========================================================================

@MainActor
final class PassRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0        // 0…1 peak meter
    /// Recording input gain (linear); scales the captured audio into the file. Persisted.
    @Published var inputGain: Float = AudioGainStore.load("orbitdeck.recorder.inputGain") {
        didSet { source?.inputGain = inputGain; AudioGainStore.save("orbitdeck.recorder.inputGain", inputGain) }
    }
    @Published var errorText = ""

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

    private let peakLock = NSLock()
    private var peak: Float = 0

    func attach(_ qso: QSOStore) { self.qso = qso }

    func start(source: AudioSource, satellite: String) {
        guard !isRecording else { return }
        // One input capture at a time until a shared hub lands (each feature opens its own
        // audio engine). Recording can't yet coexist with FT4/SSTV — surface why.
        guard AudioActivity.claimCapture("Recording") else {
            errorText = "Audio is in use by \(AudioActivity.captureHolder ?? "another feature"). Stop it first."
            return
        }
        errorText = ""
        self.source = source
        self.sat = satellite
        self.startDate = Date()
        filename = "\(safe(satellite))_\(stamp(Date())).m4a"
        recordURL = QSOStore.recordingsDir.appendingPathComponent(filename)
        recordRate = source.sampleRate
        fileCreateTried = false
        file = nil; processingFormat = nil
        source.inputGain = inputGain

        source.onError = { [weak self] m in self?.errorText = m; self?.stop() }
        do {
            try source.start(onFrames: { [weak self] frames in self?.write(frames) })
        } catch {
            errorText = error.localizedDescription
            file = nil; self.source = nil
            AudioActivity.releaseCapture("Recording")
            return
        }

        isRecording = true
        AudioActivity.begin()
        startMeter()
    }

    func stop() {
        guard isRecording else { return }
        source?.stop()
        source = nil
        AudioActivity.end()
        AudioActivity.releaseCapture("Recording")
        meterTimer?.cancel(); meterTimer = nil
        let duration = elapsed
        let sat = self.sat, filename = self.filename, start = startDate ?? Date()
        writeQueue.async { [weak self] in
            self?.file = nil     // finalize (AVAudioFile flushes on dealloc)
            // Only register a clip that was actually created (the lazy AAC create may have
            // failed, or no frames ever arrived).
            let exists = FileManager.default.fileExists(
                atPath: QSOStore.recordingsDir.appendingPathComponent(filename).path)
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.level = 0
                if duration >= 0.5, exists {
                    self?.qso?.addRecording(RecordingEntry(sat: sat, start: start, duration: duration, filename: filename))
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
            self.elapsed = Date().timeIntervalSince(start)
            self.peakLock.lock(); let p = self.peak; self.peak = 0; self.peakLock.unlock()
            self.level = max(p, self.level * 0.75)   // fast attack, slow release
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
