import Foundation

// ===========================================================================
//  IcomAudioSource.swift — RS-BA1 network audio (EXPERIMENTAL, unverified)
//
//  An `AudioSource` backed by the Icom RS-BA1 audio stream, piggybacking on the
//  live `IcomNetworkTransport` session (same session IDs negotiated for CAT). RX
//  delivers the radio's 16 kHz 16-bit PCM as Float; TX paces PCM back to the radio
//  in ~20 ms blocks (there's no hardware clock as with USB).
//
//  CardSat never opens the audio stream, so there is no validated reference — the
//  packet format is clean-roomed from public reverse engineering. Flagged for
//  on-hardware verification against a real IC-9700 / IC-705.
// ===========================================================================

final class IcomAudioSource: AudioSource, @unchecked Sendable {
    // `var`, not `let`: a CAT control-link drop makes RigController tear this transport down
    // and build a NEW one on reconnect. `rebind(to:)` re-points at the new session so audio
    // resumes; TX follows automatically because the playback timer reads `transport` live.
    private var transport: IcomNetworkTransport
    private(set) var sampleRate: Double
    private var pullHandler: ((Int) -> [Float])?
    /// Retained so RX audio can be re-established on a new transport after a reconnect.
    private var framesHandler: (([Float]) -> Void)?
    private var txTimer: DispatchSourceTimer?
    var onError: ((String) -> Void)?
    var inputGain: Float = 1
    var outputGain: Float = 1

    init(transport: IcomNetworkTransport) {
        self.transport = transport
        self.sampleRate = transport.audioSampleRate
    }

    var isAvailable: Bool { transport.isConnected }

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        framesHandler = onFrames
        bindRX()
    }

    private func bindRX() {
        guard let onFrames = framesHandler else { return }
        transport.startAudio { [weak self] pcm in
            let g = self?.inputGain ?? 1
            onFrames(pcm.map { Float($0) / 32768.0 * g })
        }
    }

    /// Re-point at the transport RigController built on a reconnect (the old one was torn
    /// down, closing its audio stream). Re-establishes the RX stream on the new session so
    /// network audio doesn't stay dead for the rest of the pass. No-op if unchanged.
    func rebind(to newTransport: IcomNetworkTransport) {
        guard newTransport !== transport else { return }
        transport.stopAudio()
        transport = newTransport
        bindRX()
        ODLog.shared.log("network audio: re-bound to new RS-BA1 session after reconnect", category: "cat")
    }

    func stop() { framesHandler = nil; transport.stopAudio() }

    func startPlayback(pull: @escaping (Int) -> [Float]) throws {
        pullHandler = pull
        let interval = 0.02
        let n = max(1, Int(sampleRate * interval))
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.orbitdeck.icomaudio.tx"))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self, let pull = self.pullHandler else { return }
            let frames = pull(n)
            guard !frames.isEmpty else { return }
            let g = self.outputGain
            let pcm = frames.map { Int16(max(-32768, min(32767, $0 * g * 32767))) }
            self.transport.sendAudioPCM(pcm)
        }
        t.resume()
        txTimer = t
    }

    func stopPlayback() {
        txTimer?.cancel(); txTimer = nil
        pullHandler = nil
    }
}
