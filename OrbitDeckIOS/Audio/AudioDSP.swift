import Foundation
import Accelerate

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

/// Real-FFT magnitude analyzer (Accelerate/vDSP) for the FT4 spectrum waterfall.
/// Used only from a single background queue, so `@unchecked Sendable` is safe.
final class SpectrumAnalyzer: @unchecked Sendable {
    let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(n: Int = 2048) {
        self.n = n
        self.half = n / 2
        self.log2n = vDSP_Length(log2(Double(n)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// Per-bin magnitude in dB for the most recent `n` samples of `input`
    /// (returns `half` bins spanning DC…Nyquist). Empty if too little data.
    func magnitudesDB(_ input: [Float]) -> [Float] {
        guard input.count >= n else { return [] }
        let start = input.count - n
        var windowed = [Float](repeating: 0, count: n)
        input.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // Power → dB (10·log10), with a small floor to avoid log(0).
        var floorv: Float = 1e-9
        vDSP_vsadd(mags, 1, &floorv, &mags, 1, vDSP_Length(half))
        var out = [Float](repeating: 0, count: half)
        var count = Int32(half)
        vvlog10f(&out, mags, &count)
        var ten: Float = 10
        vDSP_vsmul(out, 1, &ten, &out, 1, vDSP_Length(half))
        return out
    }
}

/// Maps a normalized magnitude (0…1) to a blue→cyan→green→yellow→red heatmap,
/// the conventional waterfall palette. Returns premultiplied RGBA components.
enum Heatmap {
    static func color(_ v: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let x = max(0, min(1, v))
        // Five-stop gradient.
        let stops: [(Float, Float, Float)] = [
            (0.0, 0.0, 0.25),  // deep blue
            (0.0, 0.5, 1.0),   // cyan-blue
            (0.0, 0.9, 0.3),   // green
            (1.0, 0.9, 0.0),   // yellow
            (1.0, 0.1, 0.0)    // red
        ]
        let seg = x * Float(stops.count - 1)
        let i = min(stops.count - 2, Int(seg))
        let f = seg - Float(i)
        let a = stops[i], b = stops[i + 1]
        let r = (a.0 + (b.0 - a.0) * f) * 255
        let g = (a.1 + (b.1 - a.1) * f) * 255
        let bl = (a.2 + (b.2 - a.2) * f) * 255
        return (UInt8(max(0, min(255, r))), UInt8(max(0, min(255, g))), UInt8(max(0, min(255, bl))))
    }
}
