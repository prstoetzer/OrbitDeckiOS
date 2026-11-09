import Testing
import Foundation
@testable import OrbitDeck

// MARK: - FT4 auto-sequencer, FM-only gate and SSTV half-height modes
//
// `FT4Sequencer` is the pure decision behind FT4Engine's auto-sequence (no audio, no UI),
// so each exchange edge case can be driven slot by slot.

struct FT4SequencerTests {

    private func seq() -> FT4Sequencer { FT4Sequencer(myCall: "N8HM") }

    @Test func gridReplyToCQGetsReport() throws {
        var s = seq()
        let step = try #require(s.step([("N8HM K1ABC FN42", -7)], endedSlot: 11))
        #expect(step.message == "K1ABC N8HM -07")
        #expect(step.txEven == true)          // they sent on odd slot 11 → we go even
        #expect(!step.logNow)
        #expect(s.workedCall == "K1ABC" && s.workedGrid == "FN42")
    }

    @Test func plainReportWhileCallingCQGetsRogerReport() throws {
        // They skipped the grid and sent a report straight away.
        var s = seq()
        let step = try #require(s.step([("N8HM K1ABC -12", -3)], endedSlot: 4))
        #expect(step.message == "K1ABC N8HM R-03")
        #expect(step.txEven == false)
        #expect(s.reportIn == -12)
        #expect(!step.logNow)
    }

    @Test func rogerReportGetsRR73AndLogsOnce() throws {
        var s = seq()
        s.engage("K1ABC", grid: "FN42", report: -5)
        let first = try #require(s.step([("N8HM K1ABC R-09", -5)], endedSlot: 3))
        #expect(first.message == "K1ABC N8HM RR73")
        #expect(first.logNow)
        // They repeat R-report (missed our RR73): resend RR73, no second log.
        let again = try #require(s.step([("N8HM K1ABC R-09", -6)], endedSlot: 5))
        #expect(again.message == "K1ABC N8HM RR73")
        #expect(!again.logNow)
    }

    @Test func signoffSendsOne73ThenStops() throws {
        var s = seq()
        s.engage("K1ABC", report: -5)
        _ = s.step([("N8HM K1ABC R-09", -5)], endedSlot: 3)
        let step = try #require(s.step([("N8HM K1ABC 73", -5)], endedSlot: 5))
        #expect(step.message == "K1ABC N8HM 73")
        #expect(step.stopAfterTx)
        #expect(!step.logNow)                 // already logged at RR73
    }

    @Test func repeatedRR73AfterCompletionResends73OnceWithoutRelogging() throws {
        var s = seq()
        s.engage("K1ABC", report: -5)
        let fin = try #require(s.step([("N8HM K1ABC RR73", -5)], endedSlot: 7))
        #expect(fin.logNow && fin.stopAfterTx)
        s.complete()                          // our 73 went out
        #expect(s.workedCall.isEmpty)
        // They missed our 73 and send RR73 again: one retry, never logged twice.
        let retry = try #require(s.step([("N8HM K1ABC RR73", -6)], endedSlot: 9))
        #expect(retry.message == "K1ABC N8HM 73")
        #expect(retry.stopAfterTx && !retry.logNow)
        s.complete()
        #expect(s.step([("N8HM K1ABC RR73", -6)], endedSlot: 11) == nil)
    }

    @Test func unsolicitedSignoffNeverStartsAQSO() {
        var s = seq()
        #expect(s.step([("N8HM W9XYZ 73", -2)], endedSlot: 1) == nil)
        #expect(s.step([("N8HM W9XYZ RR73", -2)], endedSlot: 1) == nil)
        #expect(s.workedCall.isEmpty && !s.logged)
    }

    @Test func ignoresMessagesNotToMe() {
        var s = seq()
        #expect(s.step([("W1AW K1ABC FN42", 0), ("CQ K1ABC FN42", 0), ("K1ABC N8HM -10", 0)], endedSlot: 1) == nil)
        s.engage("K1ABC", report: -5)
        // Another station calling me mid-QSO is ignored; so is our own echo.
        #expect(s.step([("N8HM W9XYZ EN37", 0), ("N8HM N8HM -10", 0)], endedSlot: 3) == nil)
        #expect(s.workedCall == "K1ABC")
    }

    @Test func blockedCallerIsNotAutoAnswered() {
        var s = seq()
        #expect(s.step([("N8HM K1ABC FN42", 0)], endedSlot: 1, isBlocked: { $0 == "K1ABC" }) == nil)
        #expect(s.workedCall.isEmpty)
    }

    @Test func reportWhileWorkingGetsRogerWithOurReport() throws {
        var s = seq()
        s.engage("K1ABC", grid: "FN42", report: 4)
        let step = try #require(s.step([("N8HM K1ABC -15", -1)], endedSlot: 3))
        #expect(step.message == "K1ABC N8HM R+04")
        #expect(step.txEven == nil)           // parity only changes when engaging from CQ
    }

    // MARK: FM-only gate

    private func tp(mode: String, linear: Bool) -> TransponderRecord {
        TransponderRecord(id: "t", description: "test",
                          downlinkLow: 145_950_000, downlinkHigh: linear ? 145_990_000 : 145_950_000,
                          uplinkLow: 435_150_000, uplinkHigh: linear ? 435_190_000 : 435_150_000,
                          mode: mode, invert: linear, type: linear ? "Transponder" : "Transmitter",
                          baud: 0, service: "Amateur")
    }

    @Test func fmOnlyTransponderIsRefusedButLinearNeverIs() {
        #expect(FT4Engine.fmOnlyReason(tp(mode: "FM", linear: false)) != nil)
        #expect(FT4Engine.fmOnlyReason(tp(mode: "USB", linear: true)) == nil)
        // AO-7-style linear entry whose mode string is odd still isn't gated.
        #expect(FT4Engine.fmOnlyReason(tp(mode: "FM", linear: true)) == nil)
        #expect(FT4Engine.fmOnlyReason(nil) == nil)
    }

    // MARK: DSP helpers

    @Test func waterfallSpeedMapsToTicks() {
        #expect(FT4Engine.ticksPerLine(forSeconds: 12) == 1)
        #expect(FT4Engine.ticksPerLine(forSeconds: 24) == 2)
        #expect(FT4Engine.ticksPerLine(forSeconds: 48) == 4)
    }

    @Test func gfskPhaseLengthMatchesMessage() {
        let tones = [UInt8](repeating: 1, count: 105)
        let ph = FT4DSP.gfskPhase(tones: tones, rate: 12_000, f0: 1000)
        #expect(ph.count == 105 * 576)
        #expect(ph.allSatisfy { abs($0) <= Float.pi + 0.01 })
    }

    @Test func subtractionRemovesARebuiltSignal() {
        // A clean synthesized FT4 signal subtracts to a small residual.
        let rate = 12_000.0
        var tones = [UInt8](repeating: 0, count: 105)
        for i in 0..<105 { tones[i] = UInt8((i * 7 + i / 3) % 4) }
        let ph = FT4DSP.gfskPhase(tones: tones, rate: rate, f0: 1500)
        var x = [Float](repeating: 0, count: Int(7.5 * rate))
        let n0 = Int(0.5 * rate)
        for i in 0..<ph.count { x[n0 + i] = 0.3 * cosf(ph[i] + 0.8) }
        let e0 = x.reduce(0) { $0 + Double($1 * $1) }
        FT4DSP.subtract(&x, rate: rate, tones: tones, f0: 1500, start: 0.5)
        let e1 = x.reduce(0) { $0 + Double($1 * $1) }
        #expect(10 * log10(e1 / e0) < -20)
    }
}

struct SSTVHalfHeightModeTests {
    @Test func martinAndScottieHalfHeightModesDecodeFromVIS() throws {
        let cases: [(Int, String, Int, String)] = [
            (0x24, "Martin M3", 128, "Martin M1"), (0x20, "Martin M4", 128, "Martin M2"),
            (0x34, "Scottie S3", 128, "Scottie S1"), (0x30, "Scottie S4", 128, "Scottie S2")
        ]
        for (vis, name, height, sibling) in cases {
            let m = try #require(SSTVModes.mode(forVIS: vis), "\(name)")
            let full = try #require(SSTVModes.mode(named: sibling))
            #expect(m.name == name)
            #expect(m.height == height && m.width == 320)
            #expect(abs(m.lineMs - full.lineMs) < 1e-9, "\(name) shares \(sibling)'s line timing")
        }
    }
}
