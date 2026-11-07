import Testing
import Foundation
import CoreGraphics
@testable import OrbitDeck

// MARK: - Display consistency tests
//
// Catalog name matching (AMSAT/hams.at names → catalog entries, including the
// METEOR-M2 family-member bug), the shared per-satellite palette, the
// minimum-elevation footprint geometry and globe label placement. All pure.

struct SatelliteNameMatchTests {

    private let catalog = ["METEOR-M2 3", "METEOR-M2 4", "METEOR-M 2", "ISS (ZARYA)", "SAUDISAT 1C (SO-50)",
                           "AO-73 (FUNCUBE-1)", "AO-7 (OSCAR 7)", "RS-4", "RS-44 (DOSAAF-85)",
                           "NOAA 15", "NOAA 18", "RADFXSAT (FOX-1B)", "GREENCUBE (IO-117)"]

    private func match(_ query: String, _ names: [String]? = nil) -> String? {
        let list = names ?? catalog
        return SatelliteNameMatch.matchIndex(apiName: query, in: list).map { list[$0] }
    }

    @Test func shortNamePrefersExactSatelliteOverFamilyMember() {
        // CelesTrak spells the original "METEOR-M 2"; the later launches extend the name.
        #expect(match("METEOR-M2") == "METEOR-M 2")
        #expect(match("METEOR-M2 3") == "METEOR-M2 3")
        #expect(match("METEOR-M2 4") == "METEOR-M2 4")
    }

    @Test func shortNameNeverPicksAnAmbiguousFamilyMember() {
        #expect(match("METEOR-M2", ["METEOR-M2 3", "METEOR-M2 4"]) == nil)
        #expect(match("NOAA") == nil)
        // A one-name list (AMSAT catalogMatches) gives no evidence either way.
        #expect(match("METEOR-M2", ["METEOR-M2 3"]) == nil)
    }

    @Test func soleFamilyMemberInACatalogStillMatches() {
        #expect(match("METEOR-M2", ["METEOR-M2 3", "ISS (ZARYA)"]) == "METEOR-M2 3")
    }

    @Test func existingMatchesAreKept() {
        #expect(match("ISS") == "ISS (ZARYA)")
        #expect(match("ISS", ["ISS (ZARYA)"]) == "ISS (ZARYA)")
        #expect(match("SO-50") == "SAUDISAT 1C (SO-50)")
        #expect(match("FOX-1B") == "RADFXSAT (FOX-1B)")
        #expect(match("IO-117") == "GREENCUBE (IO-117)")
        #expect(match("CAS-3H", ["LILACSAT-2"]) == "LILACSAT-2")
        #expect(match("AO-07") == "AO-7 (OSCAR 7)")
    }

    @Test func modeTaggedNamesResolve() {
        #expect(match("AO-7_[U/v]") == "AO-7 (OSCAR 7)")
        #expect(match("AO-7_[V/a]", ["AO-7 (OSCAR 7)"]) == "AO-7 (OSCAR 7)")
        #expect(match("ISS_[FM]") == "ISS (ZARYA)")
    }

    @Test func numberedDesignatorsDoNotCrossMatch() {
        #expect(match("AO-7") == "AO-7 (OSCAR 7)")
        #expect(match("AO-73") == "AO-73 (FUNCUBE-1)")
        #expect(match("RS-44") == "RS-44 (DOSAAF-85)")
        #expect(match("RS-4", ["RS-44 (DOSAAF-85)"]) == nil)
        #expect(match("AO-7", ["AO-73 (FUNCUBE-1)"]) == nil)
    }

    @Test func designatorDetection() {
        #expect(SatelliteNameMatch.startsWithDesignator(" 3"))
        #expect(SatelliteNameMatch.startsWithDesignator(" 15"))
        #expect(SatelliteNameMatch.startsWithDesignator(" 2B"))
        #expect(SatelliteNameMatch.startsWithDesignator(" B"))
        #expect(!SatelliteNameMatch.startsWithDesignator(" (ZARYA)"))
        #expect(!SatelliteNameMatch.startsWithDesignator(" (OSCAR 7)"))
        #expect(!SatelliteNameMatch.startsWithDesignator(""))
    }
}

struct SatellitePaletteTests {

    @Test func favoritesTakeSlotsInNoradOrder() {
        let palette = SatellitePalette(favorites: [43017, 7530, 25544])
        #expect(palette.slot(7530) == 0)
        #expect(palette.slot(25544) == 1)
        #expect(palette.slot(43017) == 2)
    }

    @Test func othersAreDeterministicAndAvoidFavoriteSlots() {
        let palette = SatellitePalette(favorites: [7530, 25544])
        for norad: UInt in [1, 27607, 40069, 57166, 99999] {
            let slot = palette.slot(norad)
            #expect(slot == SatellitePalette(favorites: [25544, 7530]).slot(norad))
            #expect(slot >= 2 && slot < SatellitePalette.colors.count)
        }
    }

    @Test func slotsStayInRangeWithManyFavorites() {
        let favorites = Set((1...20).map { UInt($0) })
        let palette = SatellitePalette(favorites: favorites)
        for norad in favorites.union([500, 600]) {
            #expect((0..<SatellitePalette.colors.count).contains(palette.slot(norad)))
        }
    }
}

struct FootprintGeometryTests {

    private let re = OrbitPredictor.earthRadiusKm

    /// Elevation seen from a ground point `lambda` degrees from the sub-point.
    private func elevation(centralAngle lambda: Double, altitudeKm: Double) -> Double {
        let l = lambda * .pi / 180
        return atan((cos(l) - re / (re + altitudeKm)) / sin(l)) * 180 / .pi
    }

    @Test func horizonFootprintMatchesClassicFormula() {
        let h = 420.0
        let expected = acos(re / (re + h)) * 180 / .pi
        #expect(abs(FootprintGeometry.centralAngle(altitudeKm: h) - expected) < 1e-9)
    }

    @Test func ringPointsSeeTheSatelliteAtTheRequestedElevation() {
        for h in [420.0, 800.0, 1450.0, 35786.0] {
            for eps in [5.0, 10.0, 20.0, 45.0] {
                let lambda = FootprintGeometry.centralAngle(altitudeKm: h, elevation: eps)
                #expect(abs(elevation(centralAngle: lambda, altitudeKm: h) - eps) < 1e-6)
                #expect(lambda < FootprintGeometry.centralAngle(altitudeKm: h))
            }
        }
    }

    @Test func ringIsAtTheRequestedDistance() {
        let ring = FootprintGeometry.ring(latitude: 60, longitude: 170, angleDeg: 15, samples: 72)
        #expect(ring.count == 73)
        let p1 = 60.0 * .pi / 180
        for point in ring {
            let p2 = point.latitude * .pi / 180, dl = (point.longitude - 170) * .pi / 180
            let d = acos(max(-1, min(1, sin(p1) * sin(p2) + cos(p1) * cos(p2) * cos(dl)))) * 180 / .pi
            #expect(abs(d - 15) < 1e-6)
            #expect(point.longitude >= -180 && point.longitude <= 180)
        }
    }
}

struct GlobeLabelPlacementTests {

    private let canvas = CGSize(width: 300, height: 400)
    private let label = CGSize(width: 60, height: 10)

    @Test func labelSitsAboveByDefault() {
        let p = GlobeView.labelPosition(glyph: CGPoint(x: 150, y: 200), offset: 12, label: label,
                                        canvas: canvas, headingAngle: 0)
        #expect(p == CGPoint(x: 150, y: 188))
    }

    @Test func labelFlipsBelowNearTheTopEdge() {
        let p = GlobeView.labelPosition(glyph: CGPoint(x: 150, y: 8), offset: 12, label: label,
                                        canvas: canvas, headingAngle: 0)
        #expect(p.y == 20)
    }

    @Test func labelFlipsBelowWhenHeadingUpScreen() {
        let p = GlobeView.labelPosition(glyph: CGPoint(x: 150, y: 200), offset: 12, label: label,
                                        canvas: canvas, headingAngle: -.pi / 2)
        #expect(p.y == 212)
    }

    @Test func labelIsClampedHorizontally() {
        let left = GlobeView.labelPosition(glyph: CGPoint(x: 5, y: 200), offset: 12, label: label,
                                           canvas: canvas, headingAngle: nil)
        let right = GlobeView.labelPosition(glyph: CGPoint(x: 298, y: 200), offset: 12, label: label,
                                            canvas: canvas, headingAngle: nil)
        #expect(left.x - label.width / 2 >= 0)
        #expect(right.x + label.width / 2 <= canvas.width)
    }
}
