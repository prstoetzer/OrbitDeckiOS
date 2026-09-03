import Foundation
import AVFoundation
import Combine

// ===========================================================================
//  AudioHub.swift — shared audio capture hub + availability
//
//  Owns ONE capture (a USB interface or the Icom RS-BA1 network stream) and fans
//  its mono Float frames to any number of subscribers, so pass recording, a decoder
//  (FT4/SSTV), and the live monitor / remote-voice mode can share a single engine
//  instead of each opening their own (which conflict on one AVAudioSession).
//
//  `makeSource()` returns an `AudioSubscription` that conforms to `AudioSource`, so
//  the existing consumers keep calling start/stop/startPlayback/inputGain unchanged —
//  the hub multiplexes behind that facade. The capture starts on the first subscriber
//  and stops on the last. Exactly one subscriber may drive the transmit path at a time.
//
//  Also tracks whether an audio interface is present (`audioAvailable`, the gate for
//  the audio Home cards) and observes route changes.
// ===========================================================================

/// Tracks whether any digital-audio operation (FT4 RX/TX, SSTV decode, pass
/// recording, remote voice) is active. When active, notification *alert sounds* are
/// suppressed (see `NotificationRouter`): an alert beep would be transmitted over the
/// air, or would corrupt a decode / recording. All callers are `@MainActor`.
enum AudioActivity {
    private nonisolated(unsafe) static var count = 0
    static var isActive: Bool { count > 0 }
    static func begin() { count += 1 }
    static func end() { count = max(0, count - 1) }

    // Exclusive "operating mode": FT4, SSTV and remote voice each either decode the
    // input or transmit, so only one runs at a time. Pass recording and the live
    // monitor are NOT exclusive — they share the hub's capture. The holder's display
    // name is surfaced so a blocked mode can explain why it won't start.
    private nonisolated(unsafe) static var modeOwner: String?
    static var modeHolder: String? { modeOwner }
    static func claimMode(_ who: String) -> Bool {
        if let o = modeOwner, o != who { return false }
        modeOwner = who; return true
    }
    static func releaseMode(_ who: String) {
        if modeOwner == who { modeOwner = nil }
    }
    // Back-compat aliases (older call sites used "capture").
    static func claimCapture(_ who: String) -> Bool { claimMode(who) }
    static func releaseCapture(_ who: String) { releaseMode(who) }
    static var captureHolder: String? { modeOwner }
}

/// Per-feature visibility for the audio-driven Home cards. `auto` shows the card only
/// when an audio interface is present (default); `always` shows it even without one
/// (built-in mic); `off` hides it even with an interface.
enum FeatureVisibility: String, CaseIterable, Identifiable {
    case auto, always, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .always: "Always"
        case .off: "Hidden"
        }
    }
    static let recorderKey = "feature.recorder"
    static let sstvKey = "feature.sstv"
    static let ft4Key = "feature.ft4"
    static let remoteAudioKey = "feature.remoteaudio"
}

@MainActor
final class AudioHub: ObservableObject {
    /// A USB audio interface is connected (input port present).
    @Published private(set) var usbConnected = false
    /// An Icom network-audio radio is configured and connected.
    @Published private(set) var icomAudioReady = false

    /// The gate for the audio-feature Home cards.
    var audioAvailable: Bool { usbConnected || icomAudioReady }

    private weak var rig: RigController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Shared capture
    private var captureSource: AudioSource?
    private var micFallbackWanted = false
    private nonisolated(unsafe) var subscribers: [String: AudioSubscription] = [:]
    private nonisolated(unsafe) let subLock = NSLock()
    private nonisolated(unsafe) weak var txSub: AudioSubscription?
    private var txOwner: String?

    /// Shared TX (output) gain — only one subscriber transmits at a time, so this can be a
    /// single hardware value. RX/input gain is applied PER SUBSCRIBER in `fanOut` (each of
    /// FT4/SSTV/recording keeps its own level), so the hardware capture runs at unity and
    /// starting one feature never changes another's audio.
    var outputGain: Float = 1 { didSet { captureSource?.outputGain = outputGain } }

    /// Sample rate of the active capture (48 kHz USB, 16 kHz network).
    var captureSampleRate: Double { captureSource?.sampleRate ?? 48_000 }
    /// True while a capture is running (one or more subscribers).
    var isCapturing: Bool { captureSource != nil }

    func attach(_ rig: RigController) {
        self.rig = rig
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        rig.$connected.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        refresh()
    }

    func refresh() {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        let inRoute = route.inputs.contains { $0.portType == .usbAudio }
        let outRoute = route.outputs.contains { $0.portType == .usbAudio }
        let inAvail = (s.availableInputs ?? []).contains { $0.portType == .usbAudio }
        usbConnected = inRoute || outRoute || inAvail
        icomAudioReady = rig?.icomAudioTransport != nil
        // If a network-audio capture is live and the RS-BA1 link just reconnected (new
        // transport), re-point the source at it so RX audio resumes — otherwise it stays
        // silent for the rest of the pass. rebind() is a no-op when the transport is unchanged.
        if let icom = captureSource as? IcomAudioSource, let t = rig?.icomAudioTransport {
            icom.rebind(to: t)
        }
    }

    /// A handle onto the shared capture, usable exactly like a standalone `AudioSource`.
    /// The real capture is created on the first subscriber and torn down on the last.
    func makeSource(allowMicFallback: Bool = false) -> AudioSource? {
        // Must have a real interface unless mic fallback is allowed.
        guard usbConnected || (rig?.icomAudioTransport != nil) || allowMicFallback else { return nil }
        if allowMicFallback { micFallbackWanted = true }
        return AudioSubscription(hub: self, id: UUID().uuidString, allowMicFallback: allowMicFallback)
    }

    /// Build the actual capture device (USB preferred, else network, else built-in mic).
    private func makeRawSource(allowMicFallback: Bool) -> AudioSource? {
        if usbConnected { return USBAudioSource() }
        if let t = rig?.icomAudioTransport { return IcomAudioSource(transport: t) }
        if allowMicFallback { return USBAudioSource() }   // default input = built-in mic
        return nil
    }

    // MARK: Subscriber plumbing (called by AudioSubscription — a Sendable reference, so no
    // closures cross the actor boundary; the hub calls back into it on the audio thread).

    func attachSubscriber(_ sub: AudioSubscription) throws {
        if captureSource == nil {
            guard let src = makeRawSource(allowMicFallback: sub.allowMicFallback || micFallbackWanted) else {
                throw AudioError.noDevice
            }
            src.inputGain = 1                 // unity: per-subscriber gain is applied in fanOut
            src.outputGain = outputGain
            src.onError = { [weak self] m in Task { @MainActor in self?.reportError(m) } }
            captureSource = src
            do {
                try src.start(onFrames: { [weak self] frames in self?.fanOut(frames) })
            } catch {
                captureSource = nil
                throw error
            }
        }
        subLock.lock(); subscribers[sub.id] = sub; subLock.unlock()
    }

    func detachSubscriber(_ sub: AudioSubscription) {
        subLock.lock(); subscribers.removeValue(forKey: sub.id); let empty = subscribers.isEmpty; subLock.unlock()
        if txOwner == sub.id { endTX(sub) }
        if empty { teardownCapture() }
    }

    func beginTX(_ sub: AudioSubscription) throws {
        guard captureSource != nil else { throw AudioError.notSupported }
        guard txOwner == nil || txOwner == sub.id else { throw AudioError.notSupported }
        txOwner = sub.id
        txSub = sub
        try captureSource?.startPlayback(pull: { [weak self] n in self?.txSub?.pullTX(n) ?? [] })
    }

    func endTX(_ sub: AudioSubscription) {
        guard txOwner == sub.id else { return }
        txOwner = nil; txSub = nil
        captureSource?.stopPlayback()
    }

    func setOutputGain(_ g: Float) { if g != outputGain { outputGain = g } }

    private func teardownCapture() {
        txOwner = nil; txSub = nil
        captureSource?.stopPlayback()
        captureSource?.stop()
        captureSource = nil
        micFallbackWanted = false
    }

    private func reportError(_ m: String) {
        subLock.lock(); let subs = Array(subscribers.values); subLock.unlock()
        for s in subs { s.deliverError(m) }
    }

    /// Audio-thread fan-out to every subscriber. Handlers must be non-blocking (they hop
    /// to their own queues). Also accumulates a peak for the shared level meter.
    private nonisolated func fanOut(_ frames: [Float]) {
        subLock.lock(); let subs = Array(subscribers.values); subLock.unlock()
        for s in subs {
            let g = s.subGain
            s.deliver(g == 1 ? frames : frames.map { $0 * g })
        }
        var peak: Float = 0
        for s in frames { let a = abs(s); if a > peak { peak = a } }
        levelLock.lock(); if peak > levelPeak { levelPeak = peak }; levelLock.unlock()
    }

    // MARK: Shared input-level meter (for the monitor/voice card)
    @Published private(set) var inputLevel: Float = 0
    private nonisolated(unsafe) var levelPeak: Float = 0
    private nonisolated(unsafe) let levelLock = NSLock()
    private var levelTimer: DispatchSourceTimer?

    /// Start/stop a lightweight meter (used by the remote-audio card while it's on screen).
    func startLevelMeter() {
        guard levelTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let p = self.levelLock.withLock { () -> Float in let v = self.levelPeak; self.levelPeak = 0; return v }
            self.inputLevel = max(p, self.inputLevel * 0.75)
        }
        t.resume()
        levelTimer = t
    }
    func stopLevelMeter() { levelTimer?.cancel(); levelTimer = nil; inputLevel = 0 }
}

/// A subscriber's handle onto the shared capture. Conforms to `AudioSource` so existing
/// consumers (FT4, SSTV, recorder) use it exactly like a standalone source. It holds its
/// own frame/pull closures; the hub stores a reference to it and calls back on the audio
/// thread, so no non-Sendable closure crosses the actor boundary. All `AudioSource` methods
/// are invoked from the main actor by the consumers.
final class AudioSubscription: AudioSource, @unchecked Sendable {
    private weak var hub: AudioHub?
    let id: String
    let allowMicFallback: Bool
    private var started = false

    private nonisolated(unsafe) var framesHandler: (([Float]) -> Void)?
    private nonisolated(unsafe) var pullHandler: ((Int) -> [Float])?
    private nonisolated(unsafe) var cachedRate: Double = 48_000
    /// Per-subscriber RX gain, applied by the hub's fanOut (read on the audio thread).
    nonisolated(unsafe) var subGain: Float = 1

    init(hub: AudioHub, id: String, allowMicFallback: Bool) {
        self.hub = hub; self.id = id; self.allowMicFallback = allowMicFallback
    }

    /// Audio-thread callbacks from the hub.
    nonisolated func deliver(_ frames: [Float]) { framesHandler?(frames) }
    nonisolated func pullTX(_ n: Int) -> [Float] { pullHandler?(n) ?? [] }
    nonisolated func deliverError(_ m: String) { onError?(m) }

    /// RX gain is this subscriber's own (applied per-subscriber). TX (output) gain is the
    /// shared hardware TX gain (only one subscriber transmits at a time).
    var inputGain: Float = 1 { didSet { subGain = inputGain } }
    var outputGain: Float = 1 { didSet { MainActor.assumeIsolated { hub?.setOutputGain(outputGain) } } }
    nonisolated(unsafe) var onError: ((String) -> Void)?
    var sampleRate: Double { cachedRate }
    var isAvailable: Bool { MainActor.assumeIsolated { hub?.audioAvailable ?? false } }

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        framesHandler = onFrames
        try MainActor.assumeIsolated {
            try hub?.attachSubscriber(self)
            cachedRate = hub?.captureSampleRate ?? 48_000
        }
        started = true
    }
    func stop() {
        guard started else { return }
        started = false
        MainActor.assumeIsolated { hub?.detachSubscriber(self) }
        framesHandler = nil; pullHandler = nil
    }
    func startPlayback(pull: @escaping (Int) -> [Float]) throws {
        pullHandler = pull
        try MainActor.assumeIsolated { try hub?.beginTX(self) }
    }
    func stopPlayback() {
        MainActor.assumeIsolated { hub?.endTX(self) }
        pullHandler = nil
    }
}

// ===========================================================================
//  PhoneAudioBridge — the phone's own mic + speaker for remote voice
//
//  A local AVAudioEngine (voice-chat mode, echo-cancelled) that plays the radio's
//  received audio to the phone speaker/headset and captures the phone mic for
//  transmit. It bridges the network radio audio (via an AudioHub subscription) to
//  the operator: RX PCM in → speaker; mic in → RX-rate mono for TX. Ring-buffered so
//  the network and hardware clocks don't have to line up. Engine work runs on a
//  private queue, never the main thread.
// ===========================================================================
final class PhoneAudioBridge: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let q = DispatchQueue(label: "org.orbitdeck.voice")
    private var rate: Double = 16_000
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var running = false
    private var capturing = false
    var onError: ((String) -> Void)?

    private let rxLock = NSLock(); private var rxBuf: [Float] = []
    private let txLock = NSLock(); private var txBuf: [Float] = []
    /// Live mic peak (0…1) for the TX meter.
    private let peakLock = NSLock(); private var micPeak: Float = 0
    var micPeakLevel: Float { peakLock.withLock { let v = micPeak; micPeak = 0; return v } }

    /// Start the local engine (speaker output; mic tap added on demand). Requests mic
    /// permission first, then configures the session and engine off the main thread.
    func start(rate: Double) {
        self.rate = rate
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.report("Microphone permission is required for remote voice."); return }
            self.q.async { self.begin() }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                           channels: 1, interleaved: false) else { report("Unsupported audio format."); return }
            monoFormat = mono
            let node = AVAudioSourceNode(format: mono) { [weak self] _, _, frameCount, ablPtr -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
                let n = Int(frameCount)
                let out = self?.drainRX(n) ?? []
                for buffer in abl {
                    guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<n { base[i] = i < out.count ? out[i] : 0 }
                }
                return noErr
            }
            sourceNode = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            engine.prepare()
            try engine.start()
            running = true
        } catch {
            report("Could not start remote voice audio: \(error.localizedDescription)")
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self else { return }
            if self.capturing { self.engine.inputNode.removeTap(onBus: 0); self.capturing = false }
            if let node = self.sourceNode { self.engine.detach(node); self.sourceNode = nil }
            self.engine.stop()
            self.converter = nil; self.running = false
            self.rxLock.withLock { self.rxBuf.removeAll() }
            self.txLock.withLock { self.txBuf.removeAll() }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// Radio RX audio (mono Float at `rate`) → speaker ring buffer.
    func enqueueRX(_ frames: [Float]) {
        rxLock.lock()
        rxBuf.append(contentsOf: frames)
        // Cap latency: keep at most ~1 s buffered.
        let cap = Int(rate)
        if rxBuf.count > cap { rxBuf.removeFirst(rxBuf.count - cap) }
        rxLock.unlock()
    }

    private func drainRX(_ n: Int) -> [Float] {
        rxLock.lock(); defer { rxLock.unlock() }
        guard !rxBuf.isEmpty else { return [] }
        let take = min(n, rxBuf.count)
        let out = Array(rxBuf[0..<take])
        rxBuf.removeFirst(take)
        return out
    }

    /// Begin capturing the phone mic into the TX ring (converted to mono at `rate`).
    func startMic() {
        q.async { [weak self] in
            guard let self, self.running, !self.capturing, let mono = self.monoFormat else { return }
            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                self?.handleMic(buffer, mono: mono)
            }
            self.capturing = true
        }
    }

    func stopMic() {
        q.async { [weak self] in
            guard let self, self.capturing else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.capturing = false
            self.txLock.withLock { self.txBuf.removeAll() }
        }
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: mono)
        }
        guard let converter else { return }
        let ratio = mono.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: cap) else { return }
        var consumed = false; var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        var p: Float = 0; for s in samples { let a = abs(s); if a > p { p = a } }
        peakLock.withLock { if p > micPeak { micPeak = p } }
        txLock.lock()
        txBuf.append(contentsOf: samples)
        let capN = Int(rate)      // cap ~1 s
        if txBuf.count > capN { txBuf.removeFirst(txBuf.count - capN) }
        txLock.unlock()
    }

    /// TX pull: `n` mono samples of mic audio (padded with silence on underrun).
    func drainTX(_ n: Int) -> [Float] {
        txLock.lock(); defer { txLock.unlock() }
        guard !txBuf.isEmpty else { return [] }
        let take = min(n, txBuf.count)
        let out = Array(txBuf[0..<take])
        txBuf.removeFirst(take)
        return out
    }

    private func report(_ m: String) { DispatchQueue.main.async { [weak self] in self?.onError?(m) } }
}

// ===========================================================================
//  RemoteVoiceController — listen to the radio and talk (SSB voice) through the app
//
//  Network (RS-BA1) path only: the radio's audio streams to the phone speaker and the
//  phone mic transmits to the radio, with PTT keyed over CAT. Listening shares the
//  AudioHub capture (so pass recording can run alongside); it's mutually exclusive with
//  FT4/SSTV. EXPERIMENTAL: the RS-BA1 audio path is not yet hardware-validated.
// ===========================================================================
@MainActor
final class RemoteVoiceController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isTransmitting = false
    @Published private(set) var micLevel: Float = 0
    @Published var errorText = ""

    private weak var rig: RigController?
    private weak var hub: AudioHub?
    private var sub: AudioSource?
    private let bridge = PhoneAudioBridge()
    private var meter: DispatchSourceTimer?

    func attach(rig: RigController, hub: AudioHub) {
        self.rig = rig; self.hub = hub
        bridge.onError = { [weak self] m in Task { @MainActor in self?.errorText = m; self?.stopListen() } }
    }

    /// Remote voice is a network-radio feature (phone mic → radio, radio audio → phone).
    var available: Bool { hub?.icomAudioReady ?? false }
    var pttOverCAT: Bool { rig?.pttSupported ?? false }

    func startListen() {
        guard !isListening, let hub, available else { return }
        guard AudioActivity.claimMode("Remote voice") else {
            errorText = "Audio is in use by \(AudioActivity.modeHolder ?? "another feature"). Stop it first."; return
        }
        guard let s = hub.makeSource() else {
            errorText = "No network audio available."; AudioActivity.releaseMode("Remote voice"); return
        }
        sub = s
        errorText = ""
        s.onError = { [weak self] m in Task { @MainActor in self?.errorText = m } }
        do {
            try s.start(onFrames: { [weak self] f in self?.bridge.enqueueRX(f) })
        } catch {
            errorText = error.localizedDescription
            sub = nil; AudioActivity.releaseMode("Remote voice"); return
        }
        // Start the phone-audio bridge AFTER the capture attaches, so it uses the true capture
        // rate — the hub reports the 48 kHz default until a subscriber attaches, so starting
        // the bridge earlier ran network audio (16 kHz) at the wrong rate/pitch.
        bridge.start(rate: hub.captureSampleRate)
        isListening = true
        AudioActivity.begin()
        hub.startLevelMeter()
        startMeter()
    }

    func stopListen() {
        guard isListening else { return }
        if isTransmitting { stopTX() }
        sub?.stop(); sub = nil
        bridge.stop()
        hub?.stopLevelMeter()
        meter?.cancel(); meter = nil; micLevel = 0
        AudioActivity.end()
        AudioActivity.releaseMode("Remote voice")
        isListening = false
    }

    /// Push-to-talk down: mic → radio, key PTT.
    func startTX() {
        guard isListening, !isTransmitting, let s = sub else { return }
        isTransmitting = true
        bridge.startMic()
        do { try s.startPlayback(pull: { [weak self] n in self?.bridge.drainTX(n) ?? [] }) }
        catch { errorText = error.localizedDescription }
        Task { await rig?.setPTT(true) }
    }

    /// Push-to-talk up: unkey, stop sending mic.
    func stopTX() {
        guard isTransmitting else { return }
        isTransmitting = false
        Task { await rig?.setPTT(false) }
        sub?.stopPlayback()
        bridge.stopMic()
    }

    private func startMeter() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Show the mic level while transmitting, else the received-audio level.
            let p = self.isTransmitting ? self.bridge.micPeakLevel : (self.hub?.inputLevel ?? 0)
            self.micLevel = max(p, self.micLevel * 0.75)
        }
        t.resume()
        meter = t
    }
}
