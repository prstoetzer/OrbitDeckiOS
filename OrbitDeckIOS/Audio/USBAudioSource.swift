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
//  Hardware note: full duplex requires a class-compliant interface that exposes
//  matched input and output. Verified behaviour depends on the specific device;
//  flagged for on-hardware testing.
// ===========================================================================

final class USBAudioSource: AudioSource {
    private let engine = AVAudioEngine()
    private let targetRate: Double
    private(set) var sampleRate: Double

    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var frameHandler: (([Float]) -> Void)?
    private var pullHandler: ((Int) -> [Float])?
    private var sourceNode: AVAudioSourceNode?
    private var capturing = false

    init(targetRate: Double = 48_000) {
        self.targetRate = targetRate
        self.sampleRate = targetRate
    }

    var isAvailable: Bool {
        let s = AVAudioSession.sharedInstance()
        if s.currentRoute.inputs.contains(where: { $0.portType == .usbAudio }) { return true }
        return (s.availableInputs ?? []).contains { $0.portType == .usbAudio }
    }

    // MARK: Capture

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        frameHandler = onFrames
        try configureSession()
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw AudioError.noDevice }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                       channels: 1, interleaved: false) else { throw AudioError.notSupported }
        monoFormat = mono
        converter = AVAudioConverter(from: inFormat, to: mono)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        do { try engine.start() } catch { throw AudioError.engineFailed(error.localizedDescription) }
        capturing = true
    }

    func stop() {
        if capturing { engine.inputNode.removeTap(onBus: 0); capturing = false }
        if sourceNode == nil { engine.stop() }
        frameHandler = nil
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let mono = monoFormat, let handler = frameHandler else { return }
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
        try configureSession()
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                      channels: 1, interleaved: false) else { throw AudioError.notSupported }
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
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        if !engine.isRunning {
            do { try engine.start() } catch { throw AudioError.engineFailed(error.localizedDescription) }
        }
    }

    func stopPlayback() {
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        pullHandler = nil
        if !capturing { engine.stop() }
    }

    // MARK: Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.allowBluetoothA2DP, .defaultToSpeaker])
            if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
                try? session.setPreferredInput(usb)
            }
            try session.setActive(true)
        } catch {
            throw AudioError.sessionFailed(error.localizedDescription)
        }
    }
}
