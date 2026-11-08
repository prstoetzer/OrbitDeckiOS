import Testing
import Foundation
@testable import OrbitDeck

// MARK: - CAT codec / config tests for the CardSat-parity features
//
// rigctld VFO mode framing and the \chk_vfo probe, CI-V ACK/NAK parsing for the self-test,
// the baud-based update-rate floor, and tolerant decoding of the new tuning fields.

struct CATFeatureTests {

    @Test func rigctldVFOModeLines() {
        #expect(CATCodec.rigctldLine("F", vfo: "VFOA", "145900000") == Array("F VFOA 145900000\n".utf8))
        #expect(CATCodec.rigctldLine("F", vfo: nil, "435000000") == Array("F 435000000\n".utf8))
        #expect(CATCodec.rigctldSelectVFO("VFOB") == Array("V VFOB\n".utf8))
        #expect(CATCodec.rigctldVFO(uplink: false) == "VFOA")
        #expect(CATCodec.rigctldVFO(uplink: true) == "VFOB")
        #expect(CATCodec.rigctldChkVFO == Array("\\chk_vfo\n".utf8))
    }

    @Test func rigctldChkVFOReplies() {
        #expect(CATCodec.rigctldParseChkVFO(Array("CHKVFO 1\n".utf8)))
        #expect(CATCodec.rigctldParseChkVFO(Array("1\n".utf8)))
        #expect(!CATCodec.rigctldParseChkVFO(Array("CHKVFO 0\n".utf8)))
        #expect(!CATCodec.rigctldParseChkVFO(Array("0\n".utf8)))
        #expect(!CATCodec.rigctldParseChkVFO([]))
        #expect(CATCodec.rigctldStatus(Array("RPRT -11\n".utf8)) == -11)
        #expect(CATCodec.rigctldParseMode(Array("USB\n2400\n".utf8)) == "USB")
    }

    @Test func civAckAndNak() {
        let echo: [UInt8] = [0xFE, 0xFE, 0xA2, 0xE0, 0x06, 0x01, 0x01, 0xFD]
        let ok: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA2, 0xFB, 0xFD]
        let ng: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA2, 0xFA, 0xFD]
        #expect(CATCodec.civAck(echo + ok, addr: 0xA2) == true)
        #expect(CATCodec.civAck(echo + ng, addr: 0xA2) == false)
        #expect(CATCodec.civAck(echo, addr: 0xA2) == nil)
        #expect(CATCodec.describe(ok, family: .civ).contains("OK (FB)"))
    }

    @Test func updateRateFloorByBaud() {
        var cfg = CATConfig()
        cfg.slots[0].enabled = true
        cfg.slots[0].radioID = "TS-790"          // 4800 baud default
        cfg.tuning.updateMs = 500
        #expect(cfg.effectiveUpdateMs == 1000)
        cfg.slots[0].baudOverride = 19200
        #expect(cfg.effectiveUpdateMs == 500)
        cfg.slots[0].transport = .rigctld        // not a serial link
        cfg.slots[0].baudOverride = 1200
        #expect(cfg.effectiveUpdateMs == 500)
    }

    @Test func tuningDecodesNewFieldsWithDefaults() throws {
        // A config saved before the tune mode existed, following the uplink.
        let old = #"{"followRadio":true,"followLeg":"uplink"}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(CATTuning.self, from: old)
        #expect(t.tuneMode == .fullUplink)
        #expect(t.followSelection == false)
        #expect(t.rigctldVFOMode == true)
        // Round trip keeps the new fields.
        var n = CATTuning(); n.tuneMode = .hold; n.followSelection = true; n.rigctldVFOMode = false
        let back = try JSONDecoder().decode(CATTuning.self, from: JSONEncoder().encode(n))
        #expect(back.tuneMode == .hold && back.followSelection && !back.rigctldVFOMode)
    }
}
