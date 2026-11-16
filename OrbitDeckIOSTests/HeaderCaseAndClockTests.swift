import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Section-header casing and the secondary clock
//
// `ODTheme.headerCase` uppercases section titles but keeps unit symbols
// (MHz, kHz, dB, …) as written; `ODFormat.secondaryClock` is empty when the
// device's zone is UTC, so the same time isn't shown twice.

struct HeaderCaseTests {

    @Test func uppercasesPlainTitles() {
        #expect(ODTheme.headerCase("Pass details") == "PASS DETAILS")
        #expect(ODTheme.headerCase("") == "")
    }

    @Test func keepsFrequencyUnits() {
        #expect(ODTheme.headerCase("Downlink 437.275000 MHz") == "DOWNLINK 437.275000 MHz")
        #expect(ODTheme.headerCase("Four-dial Doppler · MHz") == "FOUR-DIAL DOPPLER · MHz")
        #expect(ODTheme.headerCase("Offset (kHz)") == "OFFSET (kHz)")
        #expect(ODTheme.headerCase("10.45 GHz beacon") == "10.45 GHz BEACON")
        #expect(ODTheme.headerCase("Tone 67.0 Hz") == "TONE 67.0 Hz")
    }

    @Test func keepsDecibelUnits() {
        #expect(ODTheme.headerCase("Link budget dB") == "LINK BUDGET dB")
        #expect(ODTheme.headerCase("Power 30dBm") == "POWER 30dBm")
        #expect(ODTheme.headerCase("Gain (dBi)") == "GAIN (dBi)")
    }

    @Test func onlyExactUnitTokensAreKept() {
        // A word that merely contains a unit, or a unit in the wrong case, is uppercased.
        #expect(ODTheme.headerCase("Hzz mhz db") == "HZZ MHZ DB")
        #expect(ODTheme.headerCase("dBase") == "DBASE")
    }
}

struct SecondaryClockTests {

    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func emptyWhenDeviceZoneIsUTC() {
        #expect(ODFormat.secondaryClock(date, timeZone: TimeZone(secondsFromGMT: 0)!) == "")
        #expect(ODFormat.secondaryClock(date, timeZone: TimeZone(identifier: "UTC")!) == "")
    }

    @Test func emptyForAZoneOnUTCOnlyPartOfTheYear() {
        // London is UTC+0 in winter and UTC+1 in summer.
        let london = TimeZone(identifier: "Europe/London")!
        let winter = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        let summer = Date(timeIntervalSince1970: 1_782_000_000)   // 2026-06-21
        #expect(london.secondsFromGMT(for: winter) == 0)
        #expect(ODFormat.secondaryClock(winter, timeZone: london) == "")
        #expect(london.secondsFromGMT(for: summer) != 0)
        #expect(!ODFormat.secondaryClock(summer, timeZone: london).isEmpty)
    }

    @Test func presentWhenDeviceZoneIsOffset() {
        #expect(!ODFormat.secondaryClock(date, timeZone: TimeZone(identifier: "America/New_York")!).isEmpty)
    }
}
