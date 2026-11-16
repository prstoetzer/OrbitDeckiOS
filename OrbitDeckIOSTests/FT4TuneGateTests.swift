import Testing
import Foundation
@testable import OrbitDeck

// MARK: - FT4 Tune gate, operator callsign and the gain-slider scale
//
// `FT4Engine.tuneBlockedReason` is the pure decision behind the Tune button (the engine
// enforces it in `toggleTune`; the card dims the button with the same reason). The tune
// carrier goes on the air like a burst, so it needs the Transmit switch and a callsign.

struct FT4TuneGateTests {

    private let fmOnly = "FT4 isn't used on FM transponders."
    private let rxOnly = "Transmit disabled: this transponder has no uplink (receive only)."

    @Test func allowedWithTransmitOnAndCallsign() {
        #expect(FT4Engine.tuneBlockedReason(txEnabled: true, myCall: "N8HM", fmOnly: nil, pttBlocked: nil) == nil)
    }

    @Test func refusedWithTransmitOff() {
        let why = FT4Engine.tuneBlockedReason(txEnabled: false, myCall: "N8HM", fmOnly: nil, pttBlocked: nil)
        #expect(why == "Turn on Transmit to tune.")
    }

    @Test func refusedWithoutCallsign() {
        for call in ["", "   "] {
            let why = FT4Engine.tuneBlockedReason(txEnabled: true, myCall: call, fmOnly: nil, pttBlocked: nil)
            #expect(why == FT4Engine.noCallsignReason)
        }
    }

    @Test func refusedWhenPTTBlockedEvenIfOtherwiseReady() {
        let why = FT4Engine.tuneBlockedReason(txEnabled: true, myCall: "N8HM", fmOnly: nil, pttBlocked: rxOnly)
        #expect(why == rxOnly)
    }

    @Test func fmOnlyTakesPrecedence() {
        // The transponder reason is the most useful one to show: fixing the switch or the
        // callsign wouldn't help.
        let why = FT4Engine.tuneBlockedReason(txEnabled: false, myCall: "", fmOnly: fmOnly, pttBlocked: rxOnly)
        #expect(why == fmOnly)
    }

    @Test func callsignReasonBeforeTransmitSwitch() {
        let why = FT4Engine.tuneBlockedReason(txEnabled: false, myCall: "", fmOnly: nil, pttBlocked: nil)
        #expect(why == FT4Engine.noCallsignReason)
    }

    // MARK: Operator callsign (FT4 and packet)

    @Test func logCallsignWinsOverSettings() {
        #expect(FT4Engine.operatorCallsign(logCall: " n8hm ", settingsCall: "K1ABC") == "N8HM")
    }

    @Test func fallsBackToSettingsCallsign() {
        #expect(FT4Engine.operatorCallsign(logCall: "  ", settingsCall: "w1aw") == "W1AW")
        #expect(FT4Engine.operatorCallsign(logCall: "", settingsCall: nil) == "")
    }

    // MARK: Gain slider scale

    @Test func gainSliderIsDecibelScaled() {
        #expect(abs(AudioLevelControl.db(1)) < 1e-5)
        #expect(abs(AudioLevelControl.db(0.01) + 40) < 1e-3)
        #expect(abs(AudioLevelControl.db(10) - 20) < 1e-3)
        // The visible label is also the spoken value.
        #expect(AudioLevelControl.gainText(1) == "1.00×")
    }
}
