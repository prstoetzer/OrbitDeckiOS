import Testing
import Foundation
@testable import OrbitDeck

// MARK: - QSO log tests (0.9.14 logging: DXCC, per-leg modes, RST, back-compat)

struct QSOLogTests {

    private func dxcc(_ call: String) -> Int? { DXCCLookup.entity(for: call)?.code }

    @Test func plainCalls() {
        #expect(dxcc("K1ABC") == 291)
        #expect(dxcc("W1AW") == 291)
        #expect(dxcc("AA7XX") == 291)
        #expect(dxcc("KL7ABC") == 6)
        #expect(dxcc("KH6ABC") == 110)
        #expect(dxcc("KP4ABC") == 202)
        #expect(dxcc("VE3ABC") == 1)
        #expect(dxcc("G4ABC") == 223)
        #expect(dxcc("MM0ABC") == 279)
        #expect(dxcc("2E0ABC") == 223)
        #expect(dxcc("DL1ABC") == 230)
        #expect(dxcc("EA8ABC") == 29)
        #expect(dxcc("JA1ABC") == 339)
        #expect(dxcc("VK9XY") == 35)
        #expect(dxcc("PY0FF") == 56)
    }

    @Test func russiaAndGuantanamo() {
        #expect(dxcc("UA3ABC") == 54)
        #expect(dxcc("RA9ABC") == 15)
        #expect(dxcc("UA2FAA") == 126)
        #expect(dxcc("UA3ABC/9") == 15)
        #expect(dxcc("KG4AB") == 105)
        #expect(dxcc("KG4ABC") == 291)
    }

    @Test func compoundAndPortable() {
        #expect(dxcc("K1ABC/VE3") == 1)
        #expect(dxcc("VE3/K1ABC") == 1)
        #expect(dxcc("K1ABC/P") == 291)
        #expect(dxcc("K1ABC/M") == 291)
        #expect(dxcc("K1ABC/QRP") == 291)
        #expect(dxcc("W1AW/KH6") == 110)
        #expect(dxcc("K1ABC/MM") == 0)
        #expect(DXCCLookup.entity(for: "K1ABC/MM")?.name == "")
        #expect(dxcc("VK0ABC") == nil)      // ambiguous: Heard or Macquarie
        #expect(DXCCLookup.baseCall("VE3/K1ABC/P") == "K1ABC")
    }

    @Test func rstByMode() {
        #expect(LoggingConfig.rst(for: "SSB", base: "59") == "59")
        #expect(LoggingConfig.rst(for: "FM", base: "59") == "59")
        #expect(LoggingConfig.rst(for: "CW", base: "59") == "599")
        #expect(LoggingConfig.rst(for: "PKT", base: "59") == "599")
        #expect(LoggingConfig.rst(for: "CW", base: "579") == "579")
        #expect(LoggingConfig.rst(for: "SSB", base: "599") == "59")
        #expect(LoggingConfig.rst(for: "FT4", base: "59") == "")
        #expect(LoggingConfig.rst(for: "SSB", base: "-10") == "-10")
    }

    @Test func oldLogStillDecodes() throws {
        // A QSOLog.json record as written before the 0.9.14 fields existed.
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","utc":700000000,"call":"K1ABC","sat":"AO-91",
          "mode":"FM","dlHz":145960000,"ulHz":435250000,"myGrid":"FN31","myCall":"N8HM",
          "rstSent":"59","rstRcvd":"59","grid":"FN42","notes":"","uploaded":1}]
        """
        let qsos = try JSONDecoder().decode([QSORecord].self, from: Data(json.utf8))
        #expect(qsos.count == 1)
        let q = qsos[0]
        #expect(q.call == "K1ABC" && q.uploaded.contains(.lotw))
        #expect(q.dxcc == nil && q.name.isEmpty && q.uplinkMode == nil)
        #expect(q.effectiveUplinkMode == "FM")
        // Round trip keeps the new fields.
        var r = q; r.uplinkMode = "CW"; r.dxcc = 291; r.country = "United States of America"; r.name = "Bob"
        let back = try JSONDecoder().decode(QSORecord.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }

    @Test func adifRoundTrip() {
        var q = QSORecord(utc: Date(timeIntervalSince1970: 1_700_000_000))
        q.call = "VE3ABC"; q.mode = "SSB"; q.uplinkMode = "FM"; q.name = "Ann"
        q.dxcc = 1; q.country = "Canada"
        let text = ADIF.export([q])
        #expect(text.contains("<DXCC:1>1 "))
        #expect(text.contains("<COUNTRY:6>Canada "))
        #expect(text.contains("<NAME:3>Ann "))
        #expect(text.contains("<APP_ORBITDECK_UPLINK_MODE:2>FM "))
        let back = ADIF.parse(text).first
        #expect(back?.uplinkMode == "FM" && back?.downlinkMode == nil)
        #expect(back?.dxcc == 1 && back?.country == "Canada" && back?.name == "Ann")
    }
}
