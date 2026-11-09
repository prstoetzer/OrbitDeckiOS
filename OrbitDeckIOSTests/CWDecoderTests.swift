import Testing
import Foundation
@testable import OrbitDeck

// CW decoder: Morse table, callsign spotting, settings decoding, and the full signal
// chain on synthesized keyed audio (noise, pitch drift, several speeds and rates).

/// Deterministic Gaussian noise (LCG + Box–Muller) so the audio tests are repeatable.
private struct TestNoise {
    var state: UInt64
    mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

/// Key `text` as CW: `wpm` element speed, raised-cosine 5 ms edges, a pitch that drifts
/// linearly by `drift` Hz over the clip, white noise of standard deviation `noise`, and
/// `farnsworthWPM` (ARRL timing) stretching the character and word gaps when set.
private func keyedCW(_ text: String, wpm: Double, rate: Double = 48_000, pitch: Double = 700,
                     drift: Double = 0, amplitude: Double = 0.3, noise: Double = 0,
                     farnsworthWPM: Double? = nil, lead: Double = 1.5, tail: Double = 2,
                     seed: UInt64 = 1) -> [Float] {
    let dit = 1.2 / wpm
    var gapUnit = dit
    if let fw = farnsworthWPM { gapUnit = (60 * wpm - 37.2 * fw) / (wpm * fw) / 19 }
    var keying: [(on: Bool, seconds: Double)] = [(false, lead)]
    let codes = CWMorse.encode(text)
    for (i, code) in codes.enumerated() {
        if code == " " { keying.append((false, 4 * gapUnit)); continue }   // 3 + 4 = 7 units
        if i > 0 { keying.append((false, 3 * gapUnit)) }
        for (j, e) in code.enumerated() {
            if j > 0 { keying.append((false, dit)) }
            keying.append((true, e == "." ? dit : 3 * dit))
        }
    }
    keying.append((false, tail))
    let total = keying.reduce(0) { $0 + $1.seconds }
    var out: [Float] = []
    out.reserveCapacity(Int(total * rate) + 1)
    var rng = TestNoise(state: seed)
    var phase = 0.0, t = 0.0
    let rise = 0.005
    for k in keying {
        let n = Int(k.seconds * rate)
        for s in 0..<n {
            let ts = Double(s) / rate
            var env = 0.0
            if k.on {
                let r = max(0, min(1, min(ts / rise, (k.seconds - ts) / rise)))
                env = 0.5 - 0.5 * cos(Double.pi * r)
            }
            phase += 2 * Double.pi * (pitch + drift * t / total) / rate
            out.append(Float(amplitude * env * sin(phase) + noise * rng.gaussian()))
            t += 1 / rate
        }
    }
    return out
}

/// Run the demodulator over `audio` in ~100 ms blocks (like the capture) and return the
/// decoded text plus the demodulator for inspecting its estimates.
private func decode(_ audio: [Float], rate: Double = 48_000, settings: CWSettings = CWSettings())
    -> (text: String, demod: CWDemodulator) {
    let d = CWDemodulator(inputRate: rate, settings: settings)
    let block = Int(rate / 10)
    var text = ""
    var i = 0
    while i < audio.count {
        let j = min(audio.count, i + block)
        d.process(Array(audio[i..<j]))
        text += d.drainText().joined()
        i = j
    }
    d.flush()
    text += d.drainText().joined()
    return (text, d)
}

/// Collapse word spaces and line breaks to single spaces.
private func words(_ s: String) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
}

struct CWMorseTableTests {
    @Test func everyCharacterRoundTrips() {
        // The four characters that share a code with a prosign decode as the prosign.
        let prosignAliases: [Character: String] = ["+": "<AR>", "=": "<BT>", "(": "<KN>", "&": "<AS>"]
        for (ch, code) in CWMorse.codes {
            #expect(CWMorse.encode(String(ch)) == [code])
            #expect(CWMorse.decode(code) == (prosignAliases[ch] ?? String(ch)), "\(ch)")
        }
        #expect(CWMorse.codes.count == 26 + 10 + 18)
    }

    @Test func prosignsEncodeAndDecode() {
        for (name, code) in CWMorse.prosigns {
            #expect(CWMorse.encode("<\(name)>") == [code])
            #expect(CWMorse.decode(code) == "<\(name)>")
        }
        #expect(CWMorse.decode("...-.-") == "<SK>")
        #expect(CWMorse.decode("-...-.-") == "<BK>")
        #expect(CWMorse.decode("-.-..-..") == "<CL>")
        #expect(CWMorse.decode("..........") == "<HH>")
    }

    @Test func unknownSequencesUsePlaceholder() {
        #expect(CWMorse.decode("..--") == CWMorse.unknown)
        #expect(CWMorse.decode("--------") == CWMorse.unknown)
    }

    @Test func encodeHandlesWordsAndCase() {
        #expect(CWMorse.encode("cq de") == ["-.-.", "--.-", " ", "-..", "."])
        #expect(CWMorse.encode("  K  ") == ["-.-"])
        #expect(CWMorse.encode("73 <SK>") == ["--...", "...--", " ", "...-.-"])
    }

    @Test func callsignSpotting() {
        for call in ["N8HM", "K1ABC", "2E0ABC", "VE3/K1ABC", "K1ABC/P", "W1AW", "9A1AA"] {
            #expect(CWMorse.isCallsign(call), "\(call)")
        }
        for word in ["5NN", "599", "73", "CQ", "DE", "FN31", "TU", "<AR>", "*", "UR", "R5", "1234"] {
            #expect(!CWMorse.isCallsign(word), "\(word)")
        }
    }
}

struct CWSettingsTests {
    @Test func decodesPartialAndUnknownFields() throws {
        let json = #"{"bandwidthHz": 50, "afc": false, "futureField": 3}"#
        let s = try JSONDecoder().decode(CWSettings.self, from: Data(json.utf8))
        #expect(s.bandwidthHz == 50)
        #expect(s.afc == false)
        #expect(s.searchLowHz == 300 && s.searchHighHz == 1200)
        #expect(s.timestamps == false)
    }

    @Test func roundTripsAndNormalizes() throws {
        var s = CWSettings()
        s.squelchDb = 12; s.fixedSpeed = true; s.fixedWPM = 25; s.timestamps = true
        let back = try JSONDecoder().decode(CWSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        var bad = CWSettings()
        bad.searchLowHz = 1500; bad.searchHighHz = 400; bad.minWPM = 40; bad.maxWPM = 10
        let n = bad.normalized
        #expect(n.searchHighHz > n.searchLowHz)
        #expect(n.maxWPM > n.minWPM)
    }
}

struct CWDemodulatorTests {
    @Test func decodesNoisyDriftingCQ() {
        // 20 WPM at 700 Hz drifting +30 Hz, with noise near 0 dB SNR in a 2.5 kHz
        // bandwidth.
        let audio = keyedCW("CQ CQ DE N8HM K", wpm: 20, pitch: 700, drift: 30, noise: 0.3)
        let (text, d) = decode(audio)
        #expect(words(text) == "CQ CQ DE N8HM K")
        #expect(abs(d.snapshot.wpm - 20) <= 1.5)
        #expect(d.acquired)
        #expect(abs(d.pitchHz - 730) <= 15)
    }

    @Test(arguments: [12.0, 20, 30, 40])
    func estimatesSpeed(wpm: Double) {
        let audio = keyedCW("CQ CQ DE N8HM K", wpm: wpm, pitch: 800, noise: 0.15, seed: UInt64(wpm))
        var s = CWSettings()
        if wpm > 30 { s.bandwidthHz = 200 }
        let (text, d) = decode(audio, settings: s)
        #expect(words(text) == "CQ CQ DE N8HM K", "\(wpm) WPM")
        #expect(abs(d.snapshot.wpm - wpm) <= wpm * 0.08, "\(wpm) WPM estimated \(d.snapshot.wpm)")
    }

    @Test func decodesProsigns() {
        let audio = keyedCW("<AR> <SK> <BT> <KN> <BK> <CL> TEST", wpm: 18, noise: 0.2)
        #expect(words(decode(audio).text) == "<AR> <SK> <BT> <KN> <BK> <CL> TEST")
    }

    @Test func decodesNetworkAudioRate() {
        // RS-BA1 network audio arrives at 16 kHz.
        let audio = keyedCW("CQ CQ DE N8HM K", wpm: 15, rate: 16_000, pitch: 650, drift: -20, noise: 0.15)
        #expect(words(decode(audio, rate: 16_000).text) == "CQ CQ DE N8HM K")
    }

    @Test func fixedSpeedDecodes() {
        var s = CWSettings(); s.fixedSpeed = true; s.fixedWPM = 22
        let audio = keyedCW("N8HM 5NN", wpm: 22, noise: 0.1)
        let (text, d) = decode(audio, settings: s)
        #expect(words(text) == "N8HM 5NN")
        #expect(d.snapshot.wpm == 22)
    }

    @Test func farnsworthSpacingKeepsWordsTogether() {
        // 20 WPM characters at 12 WPM effective speed.
        let audio = keyedCW("CQ CQ DE N8HM N8HM K", wpm: 20, noise: 0.1, farnsworthWPM: 12)
        let decoded = words(decode(audio).text)
        // The gap estimate needs a few characters to learn the spacing.
        #expect(decoded.hasSuffix("DE N8HM N8HM K"), "\(decoded)")
    }

    @Test func noiseAloneStaysQuiet() {
        var rng = TestNoise(state: 42)
        let audio = (0..<(48_000 * 20)).map { _ in Float(0.5 * rng.gaussian()) }
        let (text, d) = decode(audio)
        #expect(!d.acquired)
        #expect(text.isEmpty)
    }

    @Test func manualPitchOnNoiseIsSquelched() {
        var rng = TestNoise(state: 7)
        let audio = (0..<(48_000 * 20)).map { _ in Float(0.5 * rng.gaussian()) }
        let d = CWDemodulator(inputRate: 48_000)
        d.setPitch(700)
        d.pitchLocked = true
        var text = ""
        for i in stride(from: 0, to: audio.count, by: 4800) {
            d.process(Array(audio[i..<min(audio.count, i + 4800)]))
            text += d.drainText().joined()
        }
        #expect(text.isEmpty)
    }

    @Test func picksStrongerOfTwoSignals() {
        let strong = keyedCW("TEST DE N8HM", wpm: 20, pitch: 900, noise: 0.1, seed: 3)
        var weak = keyedCW("EEEEEEEEEEEE", wpm: 20, pitch: 500, amplitude: 0.05, seed: 4)
        weak += [Float](repeating: 0, count: max(0, strong.count - weak.count))
        let mixed = zip(strong, weak).map { $0 + $1 }
        let (text, d) = decode(mixed)
        #expect(abs(d.pitchHz - 900) <= 15)
        #expect(words(text) == "TEST DE N8HM")
    }
}
