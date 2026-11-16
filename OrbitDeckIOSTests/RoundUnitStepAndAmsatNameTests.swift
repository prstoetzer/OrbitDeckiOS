import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Round distance steps and AMSAT display names
//
// The APRS-IS range stepper moves in round values of the displayed unit while the
// range is stored in km, and AMSAT API names get a readable display label without
// changing the name sent to AMSAT. All pure.

struct NearbyRangeStepTests {

    private func miles(_ km: Int) -> Int { Int((Double(km) * UnitConversion.miPerKm).rounded()) }

    @Test func metricStepsByTenKilometers() {
        #expect(NearbyRangeStep.step(100, up: true, customary: false) == 110)
        #expect(NearbyRangeStep.step(100, up: false, customary: false) == 90)
        // An off-grid value (set in miles) snaps to the next round km value.
        #expect(NearbyRangeStep.step(97, up: true, customary: false) == 100)
        #expect(NearbyRangeStep.step(97, up: false, customary: false) == 90)
        #expect(NearbyRangeStep.step(500, up: true, customary: false) == 500)
        #expect(NearbyRangeStep.step(10, up: false, customary: false) == 10)
    }

    @Test func customaryStepsByFiveMilesAndDisplaysRound() {
        let sixty = NearbyRangeStep.km(fromMiles: 60)
        #expect(miles(sixty) == 60)
        #expect(miles(NearbyRangeStep.step(sixty, up: true, customary: true)) == 65)
        #expect(miles(NearbyRangeStep.step(sixty, up: false, customary: true)) == 55)
        // The legacy 100 km default (62 mi) steps to the neighboring round values.
        #expect(miles(NearbyRangeStep.step(100, up: true, customary: true)) == 65)
        #expect(miles(NearbyRangeStep.step(100, up: false, customary: true)) == 60)
        #expect(miles(NearbyRangeStep.step(NearbyRangeStep.km(fromMiles: 300), up: true, customary: true)) == 300)
        #expect(miles(NearbyRangeStep.step(NearbyRangeStep.km(fromMiles: 5), up: false, customary: true)) == 5)
    }

    @Test func everyCustomaryStepDisplaysAsAWholeMultipleOfFive() {
        var km = NearbyRangeStep.km(fromMiles: 5)
        for _ in 0..<70 {
            km = NearbyRangeStep.step(km, up: true, customary: true)
            #expect(miles(km) % 5 == 0)
        }
    }
}

struct AmsatDisplayNameTests {

    @Test func cleansUnderscoresAndBrackets() {
        #expect(AmsatStatusService.displayName(forAPIName: "SO-131_[V/u_FM]") == "SO-131 (V/u FM)")
        #expect(AmsatStatusService.displayName(forAPIName: "AO-7_[V/a]") == "AO-7 (V/a)")
        #expect(AmsatStatusService.displayName(forAPIName: "ISS-FM") == "ISS-FM")
        #expect(AmsatStatusService.displayName(forAPIName: "RS-44") == "RS-44")
    }
}
