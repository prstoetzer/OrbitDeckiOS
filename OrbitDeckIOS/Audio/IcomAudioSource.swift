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
    private let transport: IcomNetworkTransport
    private(set) var sampleRate: Double
    private var pullHandler: ((Int) -> [Float])?
    private var txTimer: DispatchSourceTimer?
    var onError: ((String) -> Void)?

    init(transport: IcomNetworkTransport) {
        self.transport = transport
        self.sampleRate = transport.audioSampleRate
    }

    var isAvailable: Bool { transport.isConnected }

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        transport.startAudio { pcm in onFrames(pcm.map { Float($0) / 32768.0 }) }
    }

    func stop() { transport.stopAudio() }

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
            let pcm = frames.map { Int16(max(-32768, min(32767, $0 * 32767))) }
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
