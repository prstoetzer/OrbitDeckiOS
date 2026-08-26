import Foundation
import AVFoundation

// ===========================================================================
//  USBAudioSource.swift — capture/playback over a USB audio interface
//
//  Uses AVAudioEngine on a `.playAndRecord` session, preferring a class-compliant
//  USB audio input (`AVAudioSession.Port.usbAudio`). Input is converted to mono
//  Float at a target rate via AVAudioConverter; an optional AVAudioSourceNode
//  provides the transmit path so RX decode and TX encode can run at once
//  (full-duplex FT4 on a linear transponder).
//
//  ALL AVAudioSession/AVAudioEngine work runs on a private serial queue, never the
//  main thread — activating the session and starting the engine can block, which
//  would otherwise freeze the UI. Microphone permission is requested first (iOS
//  treats a USB audio input as a microphone). Tap/render callbacks arrive on the
//  audio thread and hand off via the frame/pull handlers.
// ===========================================================================

final class USBAudioSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let targetRate: Double
    private(set) var sampleRate: Double

    private let q = DispatchQueue(label: "org.orbitdeck.usbaudio")
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var frameHandler: (([Float]) -> Void)?
    private var pullHandler: ((Int) -> [Float])?
    private var sourceNode: AVAudioSourceNode?
    private var capturing = false

    /// Optional error sink (set by the caller); invoked on the main queue.
    var onError: ((String) -> Void)?

    init(targetRate: Double = 48_000) {
        self.targetRate = targetRate
        self.sampleRate = targetRate
    }

    var isAvailable: Bool {
        let s = AVAudioSession.sharedInstance()
        let r = s.currentRoute
        if r.inputs.contains(where: { $0.portType == .usbAudio }) { return true }
        if r.outputs.contains(where: { $0.portType == .usbAudio }) { return true }
        return (s.availableInputs ?? []).contains { $0.portType == .usbAudio }
    }

    // MARK: Capture

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        frameHandler = onFrames
        // Request mic permission (async), then configure + start off the main thread.
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.report("Microphone permission is required to capture audio."); return }
            self.q.async { self.beginCapture() }
        }
    }

    private func beginCapture() {
        do {
            try configureSession()
            let input = engine.inputNode
            let inFormat = input.inputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { report("No audio input available."); return }
            monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                       channels: 1, interleaved: false)
            // Remove any prior tap, then tap with the bus's OWN format (nil) — passing
            // a mismatched format is a common AVAudioEngine crash. The converter is
            // built lazily from the actual buffer format in handleInput.
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                self?.handleInput(buffer)
            }
            engine.prepare()
            try engine.start()
            capturing = true
        } catch {
            report("Could not start audio: \(error.localizedDescription)")
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self else { return }
            if self.capturing { self.engine.inputNode.removeTap(onBus: 0); self.capturing = false }
            if self.sourceNode == nil { self.engine.stop() }
            self.frameHandler = nil
            self.converter = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let mono = monoFormat, let handler = frameHandler else { return }
        // Build the converter lazily from the real input buffer format.
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: mono)
        }
        guard let converter else { return }
        let ratio = mono.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        handler(Array(UnsafeBufferPointer(start: ch[0], count: n)))
    }

    // MARK: Playback (TX, full duplex)

    func startPlayback(pull: @escaping (Int) -> [Float]) throws {
        pullHandler = pull
        q.async { [weak self] in
            guard let self else { return }
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.targetRate,
                                          channels: 1, interleaved: false) else { self.report("Unsupported audio format."); return }
            guard self.sourceNode == nil else { return }   // already set up
            do {
                try self.configureSession()
                let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, ablPtr -> OSStatus in
                    let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
                    let n = Int(frameCount)
                    let samples = self?.pullHandler?(n) ?? []
                    for buffer in abl {
                        guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<n { base[i] = i < samples.count ? samples[i] : 0 }
                    }
                    return noErr
                }
                self.sourceNode = node
                // Mutating a running engine's graph can crash; pause around the change.
                let wasRunning = self.engine.isRunning
                if wasRunning { self.engine.pause() }
                self.engine.attach(node)
                self.engine.connect(node, to: self.engine.mainMixerNode, format: fmt)
                self.engine.prepare()
                try self.engine.start()
            } catch {
                self.report("Could not start transmit audio: \(error.localizedDescription)")
            }
        }
    }

    func stopPlayback() {
        q.async { [weak self] in
            guard let self else { return }
            self.pullHandler = nil
            if let node = self.sourceNode {
                let wasRunning = self.engine.isRunning
                if wasRunning, self.capturing { self.engine.pause() }
                self.engine.detach(node)
                self.sourceNode = nil
                if self.capturing, wasRunning { self.engine.prepare(); try? self.engine.start() }
            }
            if !self.capturing { self.engine.stop() }
        }
    }

    // MARK: Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Minimal options: keep both capture and playback on the USB interface
        // (no .defaultToSpeaker, which would force TX out the built-in speaker).
        try session.setCategory(.playAndRecord, mode: .measurement)
        if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? session.setPreferredInput(usb)
        }
        try session.setActive(true)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
