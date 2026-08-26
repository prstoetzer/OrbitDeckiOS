import Foundation

// ===========================================================================
//  AudioDSP.swift — small, pure DSP helpers shared by SSTV and FT4
//
//  Deliberately dependency-free and testable: a lock-free-enough ring buffer for
//  handing real-time audio blocks to a worker, a Goertzel single-tone detector
//  (VIS/sync detection), and an arctan FM discriminator (the SSTV video
//  subcarrier is FM). Heavier spectral work for FT4 is done inside ft8_lib.
// ===========================================================================

enum AudioDSP {
    /// Magnitude of one frequency bin via the Goertzel algorithm — cheaper than a
    /// full FFT when only a few tones matter (SSTV VIS bits, 1200 Hz sync).
    static func goertzelMagnitude(_ samples: [Float], targetHz: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, !samples.isEmpty else { return 0 }
        let k = (2.0 * Double.pi * targetHz) / sampleRate
        let coeff = 2.0 * cos(k)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for x in samples {
            s0 = Double(x) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return sqrt(max(0, power)) / Double(samples.count)
    }

    /// Dominant instantaneous frequency (Hz) of a block, estimated from the phase
    /// advance of the analytic signal via a one-sample arctan discriminator.
    /// `samples` should already be band-limited to the mode's subcarrier range.
    static func instantaneousFrequency(_ samples: [Float], sampleRate: Double) -> [Double] {
        var disc = FMDiscriminator(sampleRate: sampleRate)
        return disc.process(samples)
    }
}

/// Arctan FM discriminator: differentiates the phase of a real signal's Hilbert
/// pair. A minimal single-pole Hilbert approximation is used so this stays pure
/// and allocation-light; SSTV only needs coarse instantaneous frequency.
struct FMDiscriminator {
    let sampleRate: Double
    private var prevI = 0.0, prevQ = 0.0
    // Simple 90° all-pass state for a crude quadrature estimate.
    private var d1 = 0.0, d2 = 0.0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func process(_ samples: [Float]) -> [Double] {
        var out = [Double](); out.reserveCapacity(samples.count)
        for s in samples {
            let i = Double(s)
            // Quadrature via a two-sample delay differentiator (approx. Hilbert).
            let q = (i - d2) * 0.5
            d2 = d1; d1 = i
            let dphi = atan2(i * prevQ - q * prevI, i * prevI + q * prevQ)
            prevI = i; prevQ = q
            out.append(dphi * sampleRate / (2.0 * Double.pi))
        }
        return out
    }
}

/// A fixed-capacity single-producer/single-consumer sample ring buffer for handing
/// real-time audio blocks to a worker without unbounded growth. Guarded by a lock
/// (audio blocks are large and infrequent enough that contention is negligible).
final class AudioRingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private var count = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Append samples, dropping the oldest if capacity is exceeded.
    func write(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity { count += 1 }
        }
    }

    /// Drain up to `max` of the oldest samples, or all available if `max` is nil.
    func read(max maxCount: Int? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let n = min(count, maxCount ?? count)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let start = (writeIndex - count + capacity) % capacity
        for i in 0..<n { out[i] = storage[(start + i) % capacity] }
        count -= n
        return out
    }

    var available: Int { lock.lock(); defer { lock.unlock() }; return count }
}
