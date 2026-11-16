import Testing
import Foundation
@testable import OrbitDeck

// DeepCW neural CW decoder: the front end against the Python prototype
// (tools/deepcw/cw_ref.py), the resampler's anti-aliasing, the CTC stitcher on
// hand-built posteriors, and (when the Core ML model is in the app bundle) end-to-end
// copy of keyed audio.

/// Deterministic Gaussian noise (LCG + Box–Muller).
private struct Noise {
    var state: UInt64
    mutating func gaussian() -> Double {
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

/// Keyed CW at `wpm` (PARIS timing, 5 ms raised-cosine edges) with optional noise.
private func keyed(_ text: String, wpm: Double, pitch: Double = 700, rate: Double = 48_000,
                   noise: Double = 0, lead: Double = 1, tail: Double = 2) -> [Float] {
    let dit = 1.2 / wpm
    var keying: [(Bool, Double)] = [(false, lead)]
    for (i, code) in CWMorse.encode(text).enumerated() {
        if code == " " { keying.append((false, 4 * dit)); continue }
        if i > 0 { keying.append((false, 3 * dit)) }
        for (j, e) in code.enumerated() {
            if j > 0 { keying.append((false, dit)) }
            keying.append((true, e == "." ? dit : 3 * dit))
        }
    }
    keying.append((false, tail))
    var rng = Noise(state: 7)
    var out: [Float] = []
    var phase = 0.0
    for (on, seconds) in keying {
        let n = Int(seconds * rate)
        for s in 0..<n {
            let ts = Double(s) / rate
            let r = on ? max(0, min(1, min(ts / 0.005, (seconds - ts) / 0.005))) : 0
            phase += 2 * Double.pi * pitch / rate
            out.append(Float(0.3 * (0.5 - 0.5 * cos(Double.pi * r)) * sin(phase) + noise * rng.gaussian()))
        }
    }
    return out
}

/// Tone power at `hz` (Goertzel), for checking what survives resampling.
private func power(_ x: [Float], hz: Double, rate: Double) -> Double {
    let w = 2 * cos(2 * Double.pi * hz / rate)
    var s1 = 0.0, s2 = 0.0
    for v in x { let s0 = Double(v) + w * s1 - s2; s2 = s1; s1 = s0 }
    return (s1 * s1 + s2 * s2 - w * s1 * s2) / Double(x.count * x.count)
}

struct DeepCWFrontEndTests {
    @Test func matchesPythonPrototype() {
        // 800 Hz keyed on for 1–2 s plus a quiet 1000 Hz tone throughout (see cw_ref.py).
        let audio = (0..<9600).map { n -> Float in
            let t = Double(n) / 3200
            let mark = (3200..<6400).contains(n) ? 0.4 * sin(2 * Double.pi * 800 * t) : 0
            return Float(mark + 0.01 * sin(2 * Double.pi * 1000 * t))
        }
        let (spec, frames) = DeepCWFrontEnd().spectrogram(audio[...])
        #expect(frames == 201)
        func at(_ t: Int, _ bin: Int) -> Float { spec[t * DeepCWSpec.bins + bin] }
        // Reference values from numpy (float64 FFT); bins 32 and 48 are 800 and 1000 Hz.
        let expected: [(Int, Int, Float)] = [(50, 48, 3.23151), (100, 32, 6.88111), (100, 48, 3.23151),
                                             (133, 0, 2.42899), (133, 32, 6.40919), (133, 48, 3.45919),
                                             (200, 48, 3.15688), (0, 32, 0.6529)]
        for (t, bin, value) in expected {
            #expect(abs(at(t, bin) - value) < 2e-3, "frame \(t) bin \(bin): \(at(t, bin)) vs \(value)")
        }
    }

    @Test func normalizationIsScaleInvariant() {
        let fe = DeepCWFrontEnd()
        let quiet = (0..<6400).map { Float(0.01 * sin(Double($0) * 0.9)) }
        let loud = quiet.map { $0 * 50 }
        let a = fe.spectrogram(quiet[...]).values, b = fe.spectrogram(loud[...]).values
        #expect(a.count == b.count)
        #expect(zip(a, b).map { abs($0 - $1) }.max() ?? 1 < 1e-3)
    }
}

struct DeepCWResamplerTests {
    @Test(arguments: [48_000.0, 44_100, 16_000])
    func keepsTheBandAndRejectsAliases(rate: Double) {
        let n = Int(rate * 2)
        let inBand = (0..<n).map { Float(sin(2 * Double.pi * 800 * Double($0) / rate)) }
        // 2500 Hz would fold onto 700 Hz at 3.2 kHz without the low-pass.
        let alias = (0..<n).map { Float(sin(2 * Double.pi * 2500 * Double($0) / rate)) }
        let a = DeepCWResampler(inputRate: rate).process(inBand)
        let b = DeepCWResampler(inputRate: rate).process(alias)
        #expect(abs(Double(a.count) - 2 * DeepCWSpec.sampleRate) < 400)
        let pass = power(Array(a.dropFirst(400)), hz: 800, rate: DeepCWSpec.sampleRate)
        let leak = power(Array(b.dropFirst(400)), hz: 700, rate: DeepCWSpec.sampleRate)
        #expect(pass > 0.2)                       // ~0.25 for a unit sine
        #expect(10 * log10(pass / max(leak, 1e-20)) > 40)
    }
}

struct DeepCWStitcherTests {
    /// Posteriors that strongly favor `classes[t]` at frame t (blank elsewhere).
    private func logits(_ classes: [Int]) -> [Float] {
        var out = [Float](repeating: -20, count: classes.count * DeepCWSpec.classes)
        for (t, c) in classes.enumerated() { out[t * DeepCWSpec.classes + c] = 0 }
        return out
    }

    private func index(_ ch: Character) -> Int { DeepCWSpec.chars.firstIndex(of: ch)! }

    @Test func collapsesRepeatsAndBlanks() {
        let b = DeepCWSpec.blank, a = index("A"), x = index("B")
        let s = DeepCWStitcher()
        s.add(start: 0, logits: logits([b, a, a, b, b, x, x, b, a, b]), final: true)
        let c = s.take(final: true)
        #expect(c?.text == "ABA")
        #expect(c?.leadingSpace == true)
    }

    @Test func longBlankRunBecomesAWordSpace() {
        let b = DeepCWSpec.blank, a = index("A")
        let gap = [Int](repeating: b, count: DeepCWStitcher.wordGapFrames + 2)
        let s = DeepCWStitcher()
        s.add(start: 0, logits: logits([a] + gap + [a]), final: true)
        #expect(s.take(final: true)?.text == "A A")
    }

    @Test func holdsBackTextNearTheLiveEdge() {
        // A character inside the freeze guard isn't committed until a later window.
        let b = DeepCWSpec.blank, a = index("E")
        var frames = [Int](repeating: b, count: 300)
        frames[50] = a
        frames[290] = a
        let s = DeepCWStitcher()
        s.add(start: 0, logits: logits(frames), final: false)
        #expect(s.take(final: false)?.text == "E")
        #expect(s.take(final: true)?.text == "E")
    }
}

struct DeepCWStreamTests {
    /// A fake model that never sees a character: the stream must stay silent and keep
    /// its buffers bounded.
    @Test func silentModelPrintsNothing() {
        var calls = 0
        let stream = DeepCWStream(inputRate: 48_000) { window in
            calls += 1
            #expect(window.count == DeepCWSpec.windowFrames * DeepCWSpec.bins)
            var out = [Float](repeating: -20, count: DeepCWSpec.outputFrames * DeepCWSpec.classes)
            for t in 0..<DeepCWSpec.outputFrames { out[t * DeepCWSpec.classes + DeepCWSpec.blank] = 0 }
            return out
        }
        let audio = keyed("TEST", wpm: 20, noise: 0.01)
        var i = 0
        while i < audio.count {
            stream.process(Array(audio[i..<min(audio.count, i + 4800)]))
            i += 4800
        }
        stream.flush()
        #expect(stream.drainText().isEmpty)
        #expect(calls >= Int(Double(audio.count) / 48_000) - 2)
    }

    @Test(.enabled(if: DeepCWModel.isAvailable, "DeepCW model isn't in the app bundle"),
          .timeLimit(.minutes(3)),
          arguments: [(20.0, 700.0, 0.0), (25.0, 600.0, 0.02), (15.0, 900.0, 0.03)])
    func copiesKeyedCW(wpm: Double, pitch: Double, noise: Double) throws {
        let text = "CQ CQ DE N8HM N8HM K"
        let model = try #require(DeepCWModel.shared)
        let stream = DeepCWStream(inputRate: 48_000) { DeepCWModel.logProbs($0, model: model) }
        let audio = keyed(text, wpm: wpm, pitch: pitch, noise: noise)
        var out = ""
        var i = 0
        while i < audio.count {
            stream.process(Array(audio[i..<min(audio.count, i + 4800)]))
            out += stream.drainText().joined()
            i += 4800
        }
        stream.flush()
        out += stream.drainText().joined()
        let copied = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        #expect(copied == text)
    }
}
