import Foundation
import AVFoundation
import Combine

// ===========================================================================
//  PassRecorder.swift — record received pass audio to a WAV file
//
//  Consumes an `AudioSource` (USB or, later, Icom network audio) and streams the
//  mono Float blocks to a 16-bit PCM WAV via AVAudioFile on a background queue —
//  no whole-clip RAM buffer. Each clip is tagged with the satellite + UTC start
//  and registered with the QSOStore so it appears on the Log screen.
// ===========================================================================

@MainActor
final class PassRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0        // 0…1 peak meter
    @Published var errorText = ""

    private weak var qso: QSOStore?
    private var source: AudioSource?
    private var file: AVAudioFile?
    private var processingFormat: AVAudioFormat?
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
        errorText = ""
        self.source = source
        self.sat = satellite
        self.startDate = Date()
        filename = "\(safe(satellite))_\(stamp(Date())).wav"
        let url = QSOStore.recordingsDir.appendingPathComponent(filename)
        let rate = source.sampleRate

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings)
            file = f
            processingFormat = f.processingFormat
        } catch {
            errorText = "Could not create the recording file: \(error.localizedDescription)"
            self.source = nil
            return
        }

        source.onError = { [weak self] m in self?.errorText = m; self?.stop() }
        do {
            try source.start(onFrames: { [weak self] frames in self?.write(frames) })
        } catch {
            errorText = error.localizedDescription
            file = nil; self.source = nil
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
        meterTimer?.cancel(); meterTimer = nil
        let duration = elapsed
        let sat = self.sat, filename = self.filename, start = startDate ?? Date()
        writeQueue.async { [weak self] in
            self?.file = nil     // finalize (AVAudioFile flushes on dealloc)
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.level = 0
                if duration >= 0.5 {
                    self?.qso?.addRecording(RecordingEntry(sat: sat, start: start, duration: duration, filename: filename))
                }
            }
        }
    }

    // MARK: Writing

    private func write(_ frames: [Float]) {
        writeQueue.async { [weak self] in
            guard let self, let file = self.file, let fmt = self.processingFormat,
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
            self.level = p
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
