import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Moon phase naming and unit rewriting
//
// The principal phases (new, quarters, full) only name a narrow band around their
// instant, and the display-text unit rewriter leaves amateur band names alone. All pure.

struct MoonPhaseNameTests {

    private func name(_ angle: Double) -> String { SunMoonSnapshot.phaseName(elongation: angle) }

    @Test func principalPhasesAtTheirInstants() {
        #expect(name(0) == "New")
        #expect(name(90) == "First quarter")
        #expect(name(180) == "Full")
        #expect(name(270) == "Last quarter")
        #expect(name(359) == "New")
    }

    @Test func fortyThreePercentLitIsACrescentNotAQuarter() {
        // 43% illuminated: (1 − cos a) / 2 = 0.43 → a ≈ 82°, waxing.
        let a = acos(1 - 2 * 0.43) * 180 / .pi
        #expect(name(a) == "Waxing crescent")
        #expect(name(360 - a) == "Waning crescent")
    }

    @Test func intermediatePhasesFollowWaxingAndWaning() {
        #expect(name(45) == "Waxing crescent")
        #expect(name(135) == "Waxing gibbous")
        #expect(name(225) == "Waning gibbous")
        #expect(name(315) == "Waning crescent")
    }

    @Test func quarterBandIsNarrow() {
        #expect(name(85) == "First quarter")
        #expect(name(95) == "First quarter")
        #expect(name(80) == "Waxing crescent")
        #expect(name(100) == "Waxing gibbous")
        #expect(name(265) == "Last quarter")
        #expect(name(260) == "Waning gibbous")
        #expect(name(280) == "Waning crescent")
    }

    @Test func outOfRangeAnglesAreNormalized() {
        #expect(name(450) == "First quarter")
        #expect(name(-90) == "Last quarter")
    }
}

struct UnitRewriteBandNameTests {

    @Test func bandNamesInFrequencyTextAreNotConverted() {
        #expect(UnitConversion.rewrite("Workable 10.0 MHz • 30 m • 6080 km", toCustomary: true)
                == "Workable 10.0 MHz • 30 m • 3778 mi")
        #expect(UnitConversion.rewrite("70 cm at 435 MHz", toCustomary: true) == "70 cm at 435 MHz")
    }

    @Test func bandNamesBeforeBandAreNotConverted() {
        #expect(UnitConversion.rewrite("The 2 m band is open", toCustomary: true) == "The 2 m band is open")
    }

    @Test func lengthsAreStillConverted() {
        #expect(UnitConversion.rewrite("Mast 10 m", toCustomary: true) == "Mast 33 ft")
        #expect(UnitConversion.rewrite("Perigee 408 km", toCustomary: true) == "Perigee 254 mi")
        #expect(UnitConversion.rewrite("Overall 32.96 ft", toCustomary: false) == "Overall 10.046 m")
    }
}
