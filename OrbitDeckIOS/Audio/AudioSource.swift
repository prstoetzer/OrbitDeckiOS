import Foundation

// ===========================================================================
//  AudioSource.swift — audio-capture/playback abstraction
//
//  The audio analogue of `CATTransport`: one protocol, two implementations
//  (`USBAudioSource` over a USB audio interface, `IcomAudioSource` over the
//  RS-BA1 network audio stream). Pass recording, SSTV decoding and full-duplex
//  FT4 all consume mono Float PCM through this interface, so they don't care
//  where the audio comes from.
// ===========================================================================

/// A source of received (downlink) audio, optionally with a transmit (uplink)
/// playback path for full-duplex digital modes.
protocol AudioSource: AnyObject {
    /// Sample rate of the mono Float frames delivered to `onFrames` (Hz).
    var sampleRate: Double { get }
    /// Whether the underlying device/stream is currently present.
    var isAvailable: Bool { get }
    /// Optional async-error sink (invoked on the main queue). Setup runs off the
    /// main thread, so start-time failures are reported here rather than thrown.
    var onError: ((String) -> Void)? { get set }

    /// Linear gain applied to captured (RX) frames before delivery. Default 1.0.
    var inputGain: Float { get set }
    /// Linear gain applied to played-back (TX) samples. Default 1.0.
    var outputGain: Float { get set }

    /// Begin capturing. `onFrames` receives blocks of mono Float PCM at
    /// `sampleRate`. The callback may arrive on a real-time audio thread, so
    /// consumers must hop to their own queue for heavy work.
    func start(onFrames: @escaping ([Float]) -> Void) throws
    func stop()

    /// Begin full-duplex playback (TX). The device pulls up to `count` mono Float
    /// samples per render cycle from `pull`; return fewer (padded with silence) or
    /// an empty array when idle.
    func startPlayback(pull: @escaping (_ count: Int) -> [Float]) throws
    func stopPlayback()
}

/// Persists audio-setup slider values (input/output gain) across launches so the
/// operator doesn't re-adjust every session. Backs the `@Published` gains in FT4Engine,
/// SSTVDecoder and PassRecorder — plain UserDefaults, since those are ObservableObjects
/// (not SwiftUI Views, so `@AppStorage` doesn't apply).
enum AudioGainStore {
    /// Load a saved gain, or `fallback` when nothing is stored yet (0 is a valid muted
    /// value, so we test for the key's presence rather than a zero reading).
    static func load(_ key: String, _ fallback: Float = 1) -> Float {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.float(forKey: key)
    }
    static func save(_ key: String, _ value: Float) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

enum AudioError: LocalizedError {
    case noDevice
    case sessionFailed(String)
    case engineFailed(String)
    case notSupported

    var errorDescription: String? {
        switch self {
        case .noDevice: "No audio interface is available. Connect a USB audio interface or a network-audio radio."
        case .sessionFailed(let m): "Could not configure the audio session: \(m)"
        case .engineFailed(let m): "Could not start the audio engine: \(m)"
        case .notSupported: "This audio source does not support that operation."
        }
    }
}
