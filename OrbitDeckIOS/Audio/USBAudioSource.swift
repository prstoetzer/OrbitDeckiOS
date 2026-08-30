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
    private var restarting = false
    private var observers: [NSObjectProtocol] = []

    /// Optional error sink (set by the caller); invoked on the main queue.
    var onError: ((String) -> Void)?

    /// Linear RX/TX gains (read on the audio thread; plain Float is atomic enough).
    var inputGain: Float = 1
    var outputGain: Float = 1

    init(targetRate: Double = 48_000) {
        self.targetRate = targetRate
        self.sampleRate = targetRate
        // Recover the capture graph after the system tears it down — a phone call / Siri
        // interruption (the common "left the app and came back" case) or a media-services
        // reset. Route changes are deliberately NOT handled here: our own setCategory/
        // setActive posts route-change notifications, so restarting on them would loop.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: nil) { [weak self] n in
            guard let self,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.q.async { self.restartCapture(reason: "interruption ended") }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            self?.q.async { self?.restartCapture(reason: "media services reset") }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Rebuild the capture/playback graph in place, keeping the same frame/pull handlers,
    /// so decoders and the recorder resume transparently. Runs on `q`; the `restarting`
    /// guard blocks re-entrancy from overlapping notifications.
    private func restartCapture(reason: String) {
        guard frameHandler != nil, !restarting else { return }
        restarting = true
        ODLog.shared.log("usb-audio: restarting capture (\(reason))", category: "audio")
        if capturing { engine.inputNode.removeTap(onBus: 0); capturing = false }
        if let node = sourceNode { engine.detach(node); sourceNode = nil }
        engine.stop()
        converter = nil
        beginCapture()
        restarting = false
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
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                           channels: 1, interleaved: false) else { report("Unsupported audio format."); return }
            monoFormat = mono
            // Capture: tap with the bus's OWN format (nil); converter built lazily.
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                self?.handleInput(buffer)
            }
            // Output/TX: attach a source node up front so the OUTPUT graph is live
            // and its render callback fires continuously (it outputs silence until a
            // pull handler is set for transmit). Building it after the engine is
            // running left the output chain inactive → no TX audio.
            let node = AVAudioSourceNode(format: mono) { [weak self] _, _, frameCount, ablPtr -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
                let n = Int(frameCount)
                let samples = self?.pullHandler?(n) ?? []
                let g = self?.outputGain ?? 1
                for buffer in abl {
                    guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<n { base[i] = i < samples.count ? samples[i] * g : 0 }
                }
                return noErr
            }
            sourceNode = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
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
            self.pullHandler = nil
            if self.capturing { self.engine.inputNode.removeTap(onBus: 0); self.capturing = false }
            if let node = self.sourceNode { self.engine.detach(node); self.sourceNode = nil }
            self.engine.stop()
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
        let g = inputGain
        var samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        if g != 1 { for i in 0..<n { samples[i] *= g } }
        handler(samples)
    }

    // MARK: Playback (TX, full duplex)

    func startPlayback(pull: @escaping (Int) -> [Float]) throws {
        // The output source node is already attached and rendering (silence). TX is
        // simply feeding it samples — no graph change, so nothing to crash or stall.
        pullHandler = pull
    }

    func stopPlayback() {
        pullHandler = nil
    }

    // MARK: Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .default (not .measurement) so output isn't attenuated; keep both capture
        // and playback on the USB interface. TX audio goes OUT the interface to the
        // radio, so monitor the interface, not the phone.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? session.setPreferredInput(usb)
        }
        try session.setActive(true)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
