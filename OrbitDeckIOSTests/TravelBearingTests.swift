import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Direction-of-travel helper tests (Phase 1: HEO arrow fix)
//
// These cover the two pure helpers behind the corrected motion arrows:
// `OrbitPredictor.initialBearing` (must be antimeridian-safe) and
// `travelSampleStep` (must scale the sampling step to the orbital period and
// clamp it, so a slow HEO apogee still subtends a measurable arc). Both are
// deterministic and need no propagation.

struct TravelBearingTests {

    private func near(_ a: Double, _ b: Double, _ tol: Double = 0.5) -> Bool { abs(a - b) <= tol }

    @Test func bearingDueEastAndNorth() {
        #expect(near(OrbitPredictor.initialBearing(fromLat: 0, lon: 0, toLat: 0, lon: 10), 90))
        #expect(near(OrbitPredictor.initialBearing(fromLat: 0, lon: 0, toLat: 10, lon: 0), 0))
        #expect(near(OrbitPredictor.initialBearing(fromLat: 0, lon: 0, toLat: 0, lon: -10), 270))
        #expect(near(OrbitPredictor.initialBearing(fromLat: 0, lon: 0, toLat: -10, lon: 0), 180))
    }

    @Test func bearingIsAntimeridianSafe() {
        // Crossing the ±180° seam eastbound should read ~90°, not a reversed value.
        #expect(near(OrbitPredictor.initialBearing(fromLat: 0, lon: 179, toLat: 0, lon: -179), 90))
        // And westbound ~270°.
        #expect(near(OrbitPredictor.initialBearing(fromLat: 0, lon: -179, toLat: 0, lon: 179), 270))
    }

    @Test func sampleStepScalesWithPeriodAndClamps() {
        // LEO (~96 min) → a few seconds; comfortably inside the clamp.
        let leoStep = OrbitPredictor.travelSampleStep(periodMinutes: 96)
        #expect(leoStep >= 2 && leoStep <= 90)
        // Molniya-type HEO (~717 min) → a much larger step than LEO (so apogee
        // motion is measurable), still under the 90 s clamp.
        let heoStep = OrbitPredictor.travelSampleStep(periodMinutes: 717)
        #expect(heoStep > leoStep)
        #expect(heoStep <= 90)
        // Geostationary (~1436 min) → clamped to the 90 s ceiling.
        #expect(OrbitPredictor.travelSampleStep(periodMinutes: 1436) == 90)
        // A degenerate zero period falls back to a sane default inside the clamp.
        #expect(OrbitPredictor.travelSampleStep(periodMinutes: 0) >= 2)
    }
}
