import Testing
import Foundation
@testable import OrbitDeck

// Packet stack: FCS, AX.25, KISS, APRS, APRS symbols, and the AFSK 1200 and
// G3RUH 9600 modems end to end.

struct PacketFrameTests {
    @Test func fcsMatchesCRC16X25ReferenceVector() {
        #expect(AX25FCS.compute(Array("123456789".utf8)) == 0x906E)
    }

    @Test func addressParsingAndFormatting() throws {
        let a = try #require(AX25Address("n8hm-7"))
        #expect(a.call == "N8HM" && a.ssid == 7)
        #expect(a.description == "N8HM-7")
        #expect(AX25Address("WIDE2-1*")?.repeated == true)
        #expect(AX25Address("TOOLONGCALL") == nil)
        #expect(AX25Address("N8HM-16") == nil)
    }

    @Test func frameRoundTrip() throws {
        let frame = AX25Frame(destination: AX25Address(call: "APZODK"),
                              source: AX25Address(call: "N8HM", ssid: 9),
                              digipeaters: [AX25Address(call: "ARISS"), AX25Address(call: "WIDE2", ssid: 1, repeated: true)],
                              info: Array("=3854.00N/07702.00W`Test".utf8))
        let decoded = try #require(AX25Frame.decode(frame.encoded()))
        #expect(decoded == frame)
        #expect(decoded.monitorText == "N8HM-9>APZODK,ARISS,WIDE2-1*:=3854.00N/07702.00W`Test")
        #expect(decoded.wasDigipeated)
    }

    @Test func kissEscapesAndStreams() {
        let payload: [UInt8] = [0x01, KISS.fend, 0x02, KISS.fesc, 0x03]
        let wire = KISS.encode(payload)
        #expect(wire == [0xC0, 0x00, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0])
        var decoder = KISS.Decoder()
        // Split across two reads, as BLE notifications arrive.
        let first = decoder.feed(Array(wire.prefix(4)))
        let second = decoder.feed(Array(wire.dropFirst(4)))
        #expect(first.isEmpty)
        #expect(second.count == 1)
        #expect(second.first?.data == payload)
        #expect(second.first?.port == 0 && second.first?.command == 0)
    }
}

struct APRSTests {
    @Test func positionEncodesAndParses() {
        let info = APRS.position(latitude: 38.9, longitude: -77.0333, comment: "FM18")
        #expect(info == "=3854.00N/07702.00W`FM18")
        let p = APRS.parse(info)
        #expect(p.kind == .position)
        #expect(abs((p.latitude ?? 0) - 38.9) < 0.001)
        #expect(abs((p.longitude ?? 0) + 77.0333) < 0.001)
        #expect(p.comment == "FM18")
    }

    @Test func messageAckAndID() {
        let info = APRS.message(to: "w1aw-5", text: "Hi from the ISS{pass}", id: "12")
        // Reserved `{` is stripped from the text; the message ID goes after the only `{`.
        #expect(info == ":W1AW-5   :Hi from the ISSpass}{12")
        let p = APRS.parse(":N8HM     :Thanks for the contact{7")
        #expect(p.kind == .message && p.addressee == "N8HM" && p.text == "Thanks for the contact" && p.messageID == "7")
        #expect(APRS.ack(to: "N8HM", id: "7") == ":N8HM     :ack7")
        let ack = APRS.parse(":N8HM     :ack7")
        #expect(ack.kind == .ack && ack.messageID == "7")
    }

    @Test func compressedPosition() {
        // APRS 1.0.1 ch. 9 example: /5L!!<*e7> sT → 49.5°N, 72.75°W.
        let p = APRS.parse("!/5L!!<*e7>7P[")
        #expect(p.kind == .position)
        #expect(abs((p.latitude ?? 0) - 49.5) < 0.01)
        #expect(abs((p.longitude ?? 0) + 72.75) < 0.01)
    }

    @Test func micEDecodesLatitudeFromDestination() {
        // Destination S32UVT: latitude 33°25.64'N, +100° longitude offset ('V'), west ('T').
        // Info: degrees '(' = 12 (+100 = 112), minutes '#' = 07, hundredths 'f' = 74 → 112°07.74'W.
        let info = "`(#fn\"Oj/"
        let p = APRS.parse(info, destination: "S32UVT")
        #expect(p.kind == .micE)
        #expect(abs((p.latitude ?? 0) - (33 + 25.64 / 60)) < 0.001)
        #expect(abs((p.longitude ?? 0) + (112 + 7.74 / 60)) < 0.01)
    }
}

struct APRSExtrasTests {
    @Test func positionAmbiguityBlanksTrailingDigits() {
        // 38°54.12'N 77°02.34'W at ambiguity 2 (≈1.85 km) → hundredths blanked.
        let info = APRS.position(latitude: 38 + 54.12 / 60, longitude: -(77 + 2.34 / 60), comment: "x", ambiguity: 2)
        #expect(info == "=3854.  N/07702.  W`x")
        let exact = APRS.position(latitude: 38 + 54.129 / 60, longitude: -(77 + 2.349 / 60))
        #expect(exact == "=3854.13N/07702.35W`")      // exact positions round to 0.01'
        // Blanked digits truncate (never round up into the next area).
        #expect(APRS.position(latitude: 38 + 54.99 / 60, longitude: -77, ambiguity: 2) == "=3854.  N/07700.  W`")
        // Ambiguous positions still parse (spaces read as zeros).
        let p = APRS.parse(info)
        #expect(p.kind == .position && abs((p.latitude ?? 0) - 38.9) < 0.01)
    }

    @Test func gridBeaconTelemetryAndLatePosition() {
        let g = APRS.parse("[FM18]Hello")
        #expect(g.kind == .position && g.grid == "FM18" && g.comment == "Hello")
        #expect(abs((g.latitude ?? 0) - 38.5) < 0.01 && abs((g.longitude ?? 0) + 77) < 0.01)
        #expect(APRS.parse("T#005,199,000,255,073,123,01101001").kind == .telemetry)
        let late = APRS.parse("Hi all !3854.00N/07702.00W-")
        #expect(late.kind == .position && abs((late.latitude ?? 0) - 38.9) < 0.001)
        #expect(APRS.parse("=3854.00N/07702.00W`comment /A=001234").altitudeFeet == 1234)
    }

    @Test func plainTextHeuristics() {
        #expect(PacketText.grid(in: "CQ FM18 de N8HM") == "FM18")
        #expect(PacketText.grid(in: "RR73 thanks") == nil)
        #expect(PacketText.report(in: "N8HM FM18 R599") == "599")
        #expect(PacketText.isRoger("R 599 FN31") && PacketText.isRoger("RR73"))
        #expect(PacketText.isSignOff("73 TU") && !PacketText.isSignOff("CQ FM18"))
        #expect(PacketText.isCQ("cq fm18"))
        let c = PacketText.gridCenter("FM18LV")
        #expect(abs((c?.latitude ?? 0) - 38.896) < 0.01 && abs((c?.longitude ?? 0) + 77.04) < 0.01)
    }

    @Test func uissStyleFrameRoundTrip() throws {
        // N8HM-6>CQ,ARISS:CQ FM18 — destination CQ, info = free text.
        let frame = AX25Frame(destination: try #require(AX25Address("CQ")), source: AX25Address(call: "N8HM", ssid: 6),
                              digipeaters: [AX25Address(call: "ARISS")], info: Array("CQ FM18".utf8))
        let back = try #require(AX25Frame.decode(frame.encoded()))
        #expect(back.monitorText == "N8HM-6>CQ,ARISS:CQ FM18")
        #expect(APRS.parse(back.infoText).kind == .other)   // not APRS: shown as plain text
    }
}

struct PacketQSOTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theirReplyAfterOursCompletes() throws {
        var t = PacketQSOTracker()
        // W1AW calls CQ (doesn't name us): nothing yet.
        #expect(t.heard(from: "W1AW-6", mentioningMe: false, text: "CQ FN31", at: t0) == nil)
        t.sent(to: "W1AW-6", text: "W1AW FM18 599", at: t0.addingTimeInterval(20))
        let reply = t.heard(from: "W1AW-6", mentioningMe: true, text: "N8HM R 579 73", at: t0.addingTimeInterval(45))
        let done = try #require(reply)
        #expect(done.reportSent == "599" && done.reportReceived == "579")
        // Completes once only.
        #expect(t.heard(from: "W1AW", mentioningMe: true, text: "N8HM 73", at: t0.addingTimeInterval(60)) == nil)
    }

    @Test func theyCalledFirstNeedsOurDigipeat() {
        var t = PacketQSOTracker()
        #expect(t.heard(from: "W1AW-6", mentioningMe: true, text: "N8HM FN31 599", at: t0) == nil)
        t.sent(to: "W1AW", text: "W1AW R 599 73", at: t0.addingTimeInterval(10))
        // Not yet: no sign W1AW copied us. Our copy coming back off the satellite completes it.
        #expect(t.digipeated(to: "W1AW", at: t0.addingTimeInterval(11)) != nil)
    }

    @Test func oneSidedOrStaleExchangesDontLog() {
        var t = PacketQSOTracker()
        t.sent(to: "W1AW", text: "W1AW FM18", at: t0)
        #expect(t.digipeated(to: "W1AW", at: t0.addingTimeInterval(1)) == nil)   // they never named us
        // Their reply comes a pass later (beyond the window): it starts a new contact.
        #expect(t.heard(from: "W1AW", mentioningMe: true, text: "N8HM 73", at: t0.addingTimeInterval(95 * 60)) == nil)
    }

    @Test func callMatchingIgnoresSSID() {
        #expect(PacketText.mentions("N8HM-6", in: "cq de w1aw, n8hm-7 599"))
        #expect(!PacketText.mentions("N8HM", in: "N8HMX FM18"))
        #expect(PacketText.baseCall("w1aw-12") == "W1AW")
    }
}

struct AFSKModemTests {
    @Test func offsetBanksRecoverMistunedSignal() {
        // Both tones 400 Hz high (beyond what the nominal correlators tolerate).
        let fs = 48_000.0
        let frame = AX25Frame(destination: AX25Address(call: "CQ"), source: AX25Address(call: "N8HM"),
                              info: Array("Off-frequency test".utf8))
        let tones = HDLC.encode(frame.encoded(), preambleFlags: 24)
        var phase = 0.0, clock = 0.0, audio: [Float] = []
        for t in tones {
            let step = 2 * Double.pi * ((t ? 1200 : 2200) + 400) / fs
            clock += fs / 1200
            while clock >= 1 { audio.append(Float(sin(phase)) * 0.4); phase += step; clock -= 1 }
        }
        #expect(AFSKDemodulator(sampleRate: fs).process(audio) == [frame])
    }

    private func testFrame(_ text: String = "Hello via satellite") -> AX25Frame {
        AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(call: "N8HM", ssid: 7),
                  digipeaters: [AX25Address(call: "ARISS")], info: Array(text.utf8))
    }

    @Test func hdlcRoundTripWithStuffing() {
        // 0xFF-heavy payload exercises zero-bit stuffing.
        let frame = AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(call: "N8HM"),
                              info: [0xFF, 0xFF, 0x7E, 0x7E, 0x00, 0xFE])
        let tones = HDLC.encode(frame.encoded(), preambleFlags: 4)
        var decoder = HDLC.Decoder()
        var out: [[UInt8]] = []
        for t in tones { if let f = decoder.push(level: t) { out.append(f) } }
        #expect(out.count == 1)
        #expect(out.first.flatMap { AX25Frame.decode($0) } == frame)
    }

    @Test(arguments: [48_000.0, 16_000.0, 44_100.0])
    func cleanLoopback(sampleRate: Double) {
        let frame = testFrame()
        let audio = AFSKModulator.transmission(frame, sampleRate: sampleRate, txDelayMs: 200)
        let demod = AFSKDemodulator(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: Int(sampleRate / 5))
        let frames = demod.process(silence + audio + silence)
        #expect(frames == [frame])
    }

    @Test func survivesNoiseAndDeEmphasisTilt() {
        let fs = 48_000.0
        let frame = testFrame("De-emphasized audio with noise, like an FM receiver's speaker output")
        var audio = AFSKModulator.transmission(frame, sampleRate: fs, txDelayMs: 300, amplitude: 0.4)
        // Tilt: a one-pole low-pass (~1 kHz) cuts the 2200 Hz space tone ~5 dB more than mark.
        var y: Float = 0
        let a = Float(exp(-2 * Double.pi * 1000 / fs))
        for i in audio.indices { y = a * y + (1 - a) * audio[i]; audio[i] = y * 2.2 }
        // White noise at roughly 10 dB SNR (deterministic LCG so the test is stable).
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        let noisy = audio.map { $0 + 0.09 * noise() }
        let demod = AFSKDemodulator(sampleRate: fs)
        #expect(demod.process(noisy) == [frame])
    }

    @Test func decodesBackToBackFramesAndReportsBusy() {
        let fs = 48_000.0
        let a = testFrame("first"), b = testFrame("second")
        let audio = AFSKModulator.transmission(a, sampleRate: fs, txDelayMs: 150)
            + AFSKModulator.transmission(b, sampleRate: fs, txDelayMs: 150)
        let demod = AFSKDemodulator(sampleRate: fs)
        let mid = audio.count / 4
        _ = demod.process(Array(audio[..<mid]))
        #expect(demod.channelBusy)
        let frames = demod.process(Array(audio[mid...]))
        #expect(frames.count == 2)
    }

    @Test func ignoresPureNoise() {
        var seed: UInt32 = 99
        let noise = (0..<96_000).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 }
        #expect(AFSKDemodulator(sampleRate: 48_000).process(noise).isEmpty)
    }
}

struct G3RUHModemTests {
    private func testFrame(_ text: String = "Hello at 9600 via satellite") -> AX25Frame {
        AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(call: "N8HM", ssid: 7),
                  digipeaters: [AX25Address(call: "ARISS")], info: Array(text.utf8))
    }

    private func randomBits(_ n: Int, seed: UInt32) -> [Bool] {
        var s = seed
        return (0..<n).map { _ in s = s &* 1_664_525 &+ 1_013_904_223; return s >> 31 == 1 }
    }

    @Test func scramblerRoundTripAndSelfSync() {
        let bits = randomBits(2000, seed: 7)
        var tx = G3RUHScrambler(), rx = G3RUHScrambler()
        let line = bits.map { tx.scramble($0) }
        #expect(line != bits)
        #expect(line.map { rx.descramble($0) } == bits)
        // A receiver joining mid-stream is in sync after 17 bits.
        var late = G3RUHScrambler()
        let joined = line.dropFirst(100).map { late.descramble($0) }
        #expect(Array(joined.dropFirst(17)) == Array(bits.dropFirst(117)))
        // An inverted channel only inverts the output (NRZI then ignores it).
        var inv = G3RUHScrambler()
        let inverted = line.map { inv.descramble(!$0) }
        #expect(Array(inverted.dropFirst(17)) == bits.dropFirst(17).map { !$0 })
    }

    @Test func scramblerMatchesPolynomial() {
        // An impulse into the descrambler echoes at taps 12 and 17 (1 + x^12 + x^17).
        var rx = G3RUHScrambler()
        let out = ([true] + [Bool](repeating: false, count: 30)).map { rx.descramble($0) }
        #expect(out.indices.filter { out[$0] } == [0, 12, 17])
    }

    @Test(arguments: [48_000.0, 44_100.0, 16_000.0])
    func cleanLoopback(sampleRate: Double) {
        let frame = testFrame()
        let audio = G3RUHModulator.transmission(frame, sampleRate: sampleRate, txDelayMs: 100)
        let silence = [Float](repeating: 0, count: Int(sampleRate / 10))
        #expect(G3RUHDemodulator(sampleRate: sampleRate).process(silence + audio + silence) == [frame])
        // Discriminator polarity doesn't matter.
        #expect(G3RUHDemodulator(sampleRate: sampleRate).process(silence + audio.map { -$0 } + silence) == [frame])
    }

    @Test(arguments: [48_000.0, 16_000.0])
    func survivesDCStepAndNoise(sampleRate: Double) {
        // A mistuned receiver shifts the baseband: step the DC offset mid-frame (a CAT
        // Doppler retune) on top of noise.
        let frame = testFrame("DC step halfway through the frame, as when CAT retunes the receiver")
        let audio = G3RUHModulator.transmission(frame, sampleRate: sampleRate, txDelayMs: 100)
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        let start = audio.count / 2
        let shifted = audio.indices.map { audio[$0] + 0.1 * noise() + ($0 >= start ? 0.3 : 0) }
        #expect(G3RUHDemodulator(sampleRate: sampleRate).process(shifted) == [frame])
    }

    @Test func toleratesClockOffsetAndChunking() {
        let fs = 48_000.0
        let frame = testFrame()
        let audio = G3RUHModulator.transmission(frame, sampleRate: fs, txDelayMs: 100)
        // 300 ppm sample-clock mismatch between the two sound cards.
        var resampled: [Float] = []
        var t = 0.0
        while t < Double(audio.count - 1) {
            let i = Int(t), f = Float(t - Double(i))
            resampled.append(audio[i] * (1 - f) + audio[i + 1] * f)
            t += 1.0003
        }
        let demod = G3RUHDemodulator(sampleRate: fs)
        var frames: [AX25Frame] = []
        var i = 0
        while i < resampled.count {
            let end = min(resampled.count, i + 480)          // 10 ms audio buffers
            frames += demod.process(Array(resampled[i..<end]))
            i = end
        }
        #expect(frames == [frame])
    }

    @Test func backToBackFramesAndNoise() {
        let fs = 48_000.0
        let audio = G3RUHModulator.transmission(testFrame("first"), sampleRate: fs, txDelayMs: 50)
            + G3RUHModulator.transmission(testFrame("second"), sampleRate: fs, txDelayMs: 50)
        #expect(G3RUHDemodulator(sampleRate: fs).process(audio).count == 2)
        var seed: UInt32 = 99
        let noise = (0..<96_000).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 }
        #expect(G3RUHDemodulator(sampleRate: fs).process(noise).isEmpty)
    }

    @Test func profileDecodesWithoutModemField() throws {
        // Profiles saved before 9600 support have no `modem` key.
        let old = Data(#"{"path":"ARISS","format":"plainText"}"#.utf8)
        let p = try JSONDecoder().decode(PacketSatelliteProfile.self, from: old)
        #expect(p.path == "ARISS" && p.format == .plainText && p.modem == .automatic)
        let settings = try JSONDecoder().decode(PacketSettings.self, from: Data("{}".utf8))
        #expect(settings.useDataMode)
    }
}

struct APRSSymbolTests {
    @Test func commonSymbolsMapToSFSymbols() {
        #expect(APRSSymbol(table: "/", code: ">").systemImage == "car.fill")
        #expect(APRSSymbol(table: "/", code: "-").systemImage == "house.fill")
        #expect(APRSSymbol(table: "/", code: "#").name == "Digipeater")
        #expect(APRSSymbol(table: "\\", code: "S").name == "Satellite")
        // Overlay digipeater: alternate table with the overlay character shown.
        let overlay = APRSSymbol(table: "S", code: "#")
        #expect(overlay.name == "Digipeater" && overlay.overlay == "S")
        #expect(APRSSymbol(table: "/", code: "3").systemImage == "3.circle.fill")
        #expect(APRSSymbol(table: nil, code: nil).systemImage == "mappin.circle.fill")
        #expect(APRSSymbol(table: "/", code: "z").systemImage == "mappin.circle.fill")
    }
}

// Objects, items, weather, third-party traffic, the monitor path, filters, watch
// list, pass log, message retry and the satgate (RF → APRS-IS) rules.

struct APRSObjectWeatherTests {
    @Test func objectsAndKilledObjects() {
        let p = APRS.parse(";LEADER   *092345z4903.50N/07201.75W>088/036")
        #expect(p.kind == .object && p.objectName == "LEADER" && !p.killed)
        #expect(abs((p.latitude ?? 0) - 49.058333) < 0.001)
        #expect(abs((p.longitude ?? 0) + 72.029167) < 0.001)
        #expect(p.symbolCode == ">")
        let killed = APRS.parse(";LEADER   _092345z4903.50N/07201.75W>")
        #expect(killed.kind == .object && killed.killed)
    }

    @Test func itemsAndKilledItems() {
        let p = APRS.parse(")AID #2!4903.50N/07201.75WA")
        #expect(p.kind == .item && p.objectName == "AID #2" && !p.killed && p.symbolCode == "A")
        let killed = APRS.parse(")AID #2_4903.50N/07201.75WA")
        #expect(killed.kind == .item && killed.killed)
        #expect(APRS.parse(")AB").kind == .other)
    }

    @Test func positionlessWeather() throws {
        let p = APRS.parse("_10090556c220s004g005t077r000p000P000h50b09900wRSW")
        #expect(p.kind == .weather)
        let wx = try #require(p.weather)
        #expect(wx.windDirection == 220 && wx.windSpeedMph == 4 && wx.gustMph == 5)
        #expect(wx.temperatureF == 77 && wx.rain1h == 0 && wx.humidity == 50 && wx.pressureTenths == 9900)
        #expect(wx.remainder == "wRSW")
        #expect(wx.summary.contains("77 °F"))
    }

    @Test func weatherInAPosition() throws {
        let p = APRS.parse("=4903.50N/07201.75W_220/004g005t-05h00b10132")
        #expect(p.kind == .position && p.symbolCode == "_")
        let wx = try #require(p.weather)
        #expect(wx.windDirection == 220 && wx.windSpeedMph == 4 && wx.temperatureF == -5)
        #expect(wx.humidity == 100 && wx.pressureTenths == 10132)
        // Missing values ("...") stay nil.
        let missing = APRS.parse("=4903.50N/07201.75W_.../...t050")
        #expect(missing.weather?.windDirection == nil && missing.weather?.temperatureF == 50)
    }

    @Test func thirdPartyIsUnwrapped() {
        let p = APRS.parse("}W1AW>APRS,TCPIP,N8HM*:=4903.50N/07201.75W-Hello")
        #expect(p.kind == .position && p.thirdPartySource == "W1AW" && p.thirdPartyDestination == "APRS")
        #expect(p.thirdPartyPath == ["TCPIP", "N8HM*"])
        #expect(p.comment == "Hello")
        // A nested third-party header isn't unwrapped twice.
        #expect(APRS.parse("}W1AW>APRS:}K1ABC>APRS:>x").kind == .other)
        let msg = APRS.parse("}W1AW>APRS,TCPIP:BLN1     :Net tonight")
        #expect(msg.isBulletin)
    }
}

struct PacketMonitorTests {
    private func frame(_ info: String, from: String = "W1AW-7", repeated: Bool = true) -> AX25Frame {
        AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(from)!,
                  digipeaters: [AX25Address(call: "RS0ISS", repeated: repeated), AX25Address(call: "WIDE2", ssid: 1)],
                  info: Array(info.utf8))
    }

    @Test func pathMarksTheRepeatingDigipeater() {
        let f = frame("=4903.50N/07201.75W-")
        #expect(f.pathText == ["RS0ISS*", "WIDE2-1"])
        #expect(f.tnc2Header == "W1AW-7>APZODK,RS0ISS*,WIDE2-1")
        #expect(PacketDigis.isSatellite("RS0ISS*") && PacketDigis.isSatellite("ARISS"))
        #expect(!PacketDigis.isSatellite("WIDE2-1"))
    }

    @Test func filterMatching() {
        let f = frame("=4903.50N/07201.75W-")
        var e = PacketLogEntry(date: Date(), direction: .received, frame: f, aprs: APRS.parse(f.infoText), text: "Hello")
        e.isBeacon = true
        var filter = PacketMonitorFilter()
        #expect(filter.matches(e) && filter.activeCount == 0)
        filter.hideBeacons = true
        #expect(!filter.matches(e))
        filter = PacketMonitorFilter(); filter.call = "W1A"
        #expect(filter.matches(e))
        filter.call = "K1"
        #expect(!filter.matches(e))
        filter = PacketMonitorFilter(); filter.text = "hello"
        #expect(filter.matches(e))
        filter = PacketMonitorFilter(); filter.digipeatedOnly = true
        let direct = frame("x", repeated: false)
        #expect(!filter.matches(PacketLogEntry(date: Date(), direction: .received, frame: direct,
                                               aprs: APRS.parse("x"), text: "x")))
        filter.onlyMine = true
        #expect(!filter.matches(e) && filter.activeCount == 2)
    }

    @Test func watchList() {
        #expect(PacketWatch.parseList("w1aw, field day ,,") == ["W1AW", "FIELD DAY"])
        #expect(PacketWatch.match(["W1AW"], source: "W1AW-7", text: "") == "W1AW")
        #expect(PacketWatch.match(["W1AW-5"], source: "W1AW-7", text: "") == nil)
        #expect(PacketWatch.match(["W1AW"], source: "K1ABC", text: "cq de w1aw") == "W1AW")
        #expect(PacketWatch.match(["field day"], source: "K1ABC", text: "Field Day setup") == "FIELD DAY")
        #expect(PacketWatch.match(["ISS"], source: "K1ABC", text: "ISS pass tonight") == "ISS")
        #expect(PacketWatch.match(["ISS"], source: "K1ABC", text: "nothing") == nil)
    }

    @Test func messageRetryPolicy() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var r = PacketMessageRetry(id: "12", logID: UUID(), frame: frame(":N8HM-6   :hi{12"), firstSent: t0)
        #expect(r.action(now: t0.addingTimeInterval(10), satelliteUp: true, enabled: true) == .wait)
        #expect(r.action(now: t0.addingTimeInterval(30), satelliteUp: false, enabled: true) == .wait)
        #expect(r.action(now: t0.addingTimeInterval(30), satelliteUp: true, enabled: false) == .wait)
        #expect(r.action(now: t0.addingTimeInterval(30), satelliteUp: true, enabled: true) == .resend)
        r.didResend(at: t0.addingTimeInterval(30))
        #expect(r.action(now: t0.addingTimeInterval(45), satelliteUp: true, enabled: true) == .wait)
        #expect(r.action(now: t0.addingTimeInterval(60), satelliteUp: true, enabled: true) == .resend)
        r.didResend(at: t0.addingTimeInterval(60))
        // Two retries done: give up once the last one has had its 30 s.
        #expect(r.action(now: t0.addingTimeInterval(80), satelliteUp: true, enabled: true) == .wait)
        #expect(r.action(now: t0.addingTimeInterval(90), satelliteUp: true, enabled: true) == .giveUp)
        let never = PacketMessageRetry(id: "1", logID: UUID(), frame: frame("x"), firstSent: t0)
        #expect(never.action(now: t0.addingTimeInterval(16 * 60), satelliteUp: false, enabled: true) == .giveUp)
    }
}

struct PacketSessionTests {
    private func record(_ dir: PacketLogRecord.Direction, from: String, at t: Double, delay: Double? = nil,
                        retry: Bool = false) -> PacketLogRecord {
        let f = AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(from)!,
                          digipeaters: [AX25Address(call: "RS0ISS", repeated: dir == .received)],
                          info: Array("=hi".utf8))
        var r = PacketLogRecord(date: Date(timeIntervalSince1970: 1_800_000_000 + t), direction: dir, frame: f)
        r.digipeatDelay = delay
        r.retry = retry
        return r
    }

    @Test func statistics() {
        let records = [
            record(.received, from: "W1AW", at: 0),
            record(.received, from: "K1ABC", at: 10),
            record(.sent, from: "N8HM-6", at: 20, delay: 2),
            record(.sent, from: "N8HM-6", at: 30, delay: 4),
            record(.sent, from: "N8HM-6", at: 40),
            record(.sent, from: "N8HM-6", at: 50, retry: true),
            record(.received, from: "W1AW", at: 60),
        ]
        let s = PacketSessionStats.compute(records)
        #expect(s.framesHeard == 3 && s.stationsHeard == 2)
        #expect(s.sent == 3 && s.digipeated == 2 && s.successPercent == 67)
        #expect(s.medianDelay == 3)
        #expect(abs(s.framesPerMinute - 3) < 0.001)
        #expect(PacketSessionStats.compute([]).successPercent == nil)
    }

    @Test func exportsAndPersistence() throws {
        var session = PacketSession(start: Date(timeIntervalSince1970: 1_800_000_000),
                                    end: Date(timeIntervalSince1970: 1_800_000_060),
                                    satellite: "ISS", norad: 25544, myCall: "N8HM-6")
        var r = record(.received, from: "W1AW", at: 0)
        r.info = ">hi, \"there\""
        session.records = [r]
        let text = PacketSessionExport.tnc2(session)
        #expect(text.contains("2027-01-15 08:00:00Z RX W1AW>APZODK,RS0ISS*:>hi, \"there\""))
        #expect(text.hasPrefix("# OrbitDeck packet log — ISS (25544) — N8HM-6"))
        let csv = PacketSessionExport.csv(session)
        #expect(csv.contains("W1AW,APZODK,RS0ISS*,\">hi, \"\"there\"\"\",1,0,,0,0"))
        #expect(PacketSessionExport.csvField("=SUM(A1)") == "'=SUM(A1)")
        #expect(PacketSessionExport.csvField("plain") == "plain")
        #expect(PacketSessionExport.fileStem(session) == "OrbitDeck-packet-ISS-20270115-0800")
        // Round trip, and tolerant decoding of a record missing newer fields.
        let back = try JSONDecoder().decode(PacketSession.self, from: JSONEncoder().encode(session))
        #expect(back == session)
        let old = try JSONDecoder().decode(PacketLogRecord.self,
                                           from: Data(#"{"source":"W1AW","destination":"CQ","info":"hi"}"#.utf8))
        #expect(old.source == "W1AW" && old.direction == .received && old.path.isEmpty && !old.retry)
    }

    @Test func settingsDecodeTolerantly() throws {
        let s = try JSONDecoder().decode(PacketSettings.self, from: Data("{}".utf8))
        #expect(s.transport == .builtInModem && s.kissPort == 8001 && s.minElevationDeg == 0)
        #expect(!s.satgateEnabled && s.satgateHost == "rotate.aprs2.net" && s.satgatePort == 14580)
        #expect(!s.alertToMe && !s.speakMessages && s.retryMessages && s.beaconContent == .position)
        #expect(s.monitorFilter == PacketMonitorFilter())
        var changed = s
        changed.transport = .tcpKISS; changed.kissHost = "192.168.1.20"; changed.minElevationDeg = 10
        changed.watchList = ["W1AW"]; changed.monitorFilter.hideBeacons = true; changed.beaconContent = .alternate
        changed.profiles["25544"] = PacketSatelliteProfile(path: "ARISS", format: .aprs, minElevationDeg: 15)
        let back = try JSONDecoder().decode(PacketSettings.self, from: JSONEncoder().encode(changed))
        #expect(back == changed)
        let filter = try JSONDecoder().decode(PacketMonitorFilter.self, from: Data(#"{"hideStatus":true}"#.utf8))
        #expect(filter.hideStatus && !filter.showRaw)
        let profile = try JSONDecoder().decode(PacketSatelliteProfile.self, from: Data(#"{"path":"ARISS"}"#.utf8))
        #expect(profile.minElevationDeg == nil)
    }
}

struct APRSISGateTests {
    private func frame(_ info: String, from: String = "W1AW-7", digis: [AX25Address]? = nil) -> AX25Frame {
        AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(from)!,
                  digipeaters: digis ?? [AX25Address(call: "RS0ISS", repeated: true), AX25Address(call: "WIDE2", ssid: 1)],
                  info: Array(info.utf8))
    }
    private let own: Set<String> = ["N8HM-6", "N8HM-10"]

    @Test func appendsQARAndKeepsThePath() {
        #expect(APRSISGate.line(for: frame("=4903.50N/07201.75W-"), igate: "N8HM-10", ownCalls: own)
                == "W1AW-7>APZODK,RS0ISS*,WIDE2-1,qAR,N8HM-10:=4903.50N/07201.75W-")
        // Cut at the first CR/LF.
        #expect(APRSISGate.line(for: frame(">status\rjunk"), igate: "N8HM-10", ownCalls: own)?.hasSuffix(":>status") == true)
    }

    @Test func refusesWhatMustNotBeGated() {
        #expect(APRSISGate.line(for: frame(">hi", from: "N8HM-6"), igate: "N8HM-10", ownCalls: own) == nil)
        for word in ["NOGATE", "RFONLY", "TCPIP", "TCPXX"] {
            let f = frame(">hi", digis: [AX25Address(call: word)])
            #expect(APRSISGate.line(for: f, igate: "N8HM-10", ownCalls: own) == nil)
        }
        #expect(APRSISGate.line(for: frame("?APRS?"), igate: "N8HM-10", ownCalls: own) == nil)
        #expect(APRSISGate.line(for: frame(""), igate: "N8HM-10", ownCalls: own) == nil)
        var notUI = frame(">hi"); notUI.control = 0x00
        #expect(APRSISGate.line(for: notUI, igate: "N8HM-10", ownCalls: own) == nil)
        #expect(APRSISGate.line(for: frame(">hi"), igate: "", ownCalls: own) == nil)
    }

    @Test func thirdPartyTraffic() {
        // Internet traffic sent to RF (TCPIP inside) is never gated back.
        #expect(APRSISGate.line(for: frame("}K1ABC>APRS,TCPIP,W1AW*:>hi"), igate: "N8HM-10", ownCalls: own) == nil)
        // RF third-party traffic: the inner packet is gated.
        #expect(APRSISGate.line(for: frame("}K1ABC>APRS,WIDE1-1:>hi"), igate: "N8HM-10", ownCalls: own)
                == "K1ABC>APRS,WIDE1-1,qAR,N8HM-10:>hi")
        #expect(APRSISGate.line(for: frame("}garbage"), igate: "N8HM-10", ownCalls: own) == nil)
    }

    @Test func duplicatesWithin30SecondsAreDropped() {
        var dupes = APRSISDupeFilter()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = "W1AW-7>APZODK,RS0ISS*,qAR,N8HM-10:>hi"
        let b = "W1AW-7>APZODK,WIDE2-1,qAR,N8HM-10:>hi"     // same packet, other path
        #expect(!dupes.isDuplicate(a, at: t0))
        #expect(dupes.isDuplicate(b, at: t0.addingTimeInterval(5)))
        #expect(!dupes.isDuplicate("W1AW-7>APZODK,qAR,N8HM-10:>other", at: t0.addingTimeInterval(6)))
        #expect(!dupes.isDuplicate(a, at: t0.addingTimeInterval(31)))
    }
}
