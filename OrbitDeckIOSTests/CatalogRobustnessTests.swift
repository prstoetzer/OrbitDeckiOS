import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Catalog, prediction and export robustness
//
// Covers malformed OMM rows (non-finite / overflowing numbers are skipped and
// counted, never trapping), the Alpha-5 TLE catalog field (no wrong IDs above
// 339999), per-dataset CelesTrak cooldown keys, the fast continuity path for a
// geostationary bird, and the imported-elements overlay precedence.

struct CatalogRobustnessTests {

    // MARK: Helpers

    private static let epochString = "2026-11-15T12:00:00.000000"

    /// A well-formed OMM row (ISS-like) to which overrides are applied.
    private func row(_ overrides: [String: Any] = [:], norad: Int = 25544) -> [String: Any] {
        var r: [String: Any] = [
            "OBJECT_NAME": "TEST \(norad)",
            "OBJECT_ID": "1998-067A",
            "NORAD_CAT_ID": norad,
            "EPOCH": Self.epochString,
            "MEAN_MOTION": 15.5,
            "ECCENTRICITY": 0.0005,
            "INCLINATION": 51.64,
            "RA_OF_ASC_NODE": 120.0,
            "ARG_OF_PERICENTER": 90.0,
            "MEAN_ANOMALY": 270.0,
            "BSTAR": 0.0001,
            "EPHEMERIS_TYPE": 0,
            "ELEMENT_SET_NO": 999,
            "REV_AT_EPOCH": 12345
        ]
        for (k, v) in overrides { r[k] = v }
        return r
    }

    private func parse(_ rows: [[String: Any]]) throws -> (records: [SatelliteRecord], skipped: Int) {
        let data = try JSONSerialization.data(withJSONObject: rows)
        return try GPService.parseCounting(data: data)
    }

    /// A QO-100-like geostationary record (NORAD 43700, Es'hail-2).
    private func geoRecord() throws -> SatelliteRecord {
        let r: [String: Any] = [
            "OBJECT_NAME": "ES'HAIL 2", "OBJECT_ID": "2018-090A", "NORAD_CAT_ID": 43700,
            "EPOCH": Self.epochString, "MEAN_MOTION": 1.00271, "ECCENTRICITY": 0.0002,
            "INCLINATION": 0.03, "RA_OF_ASC_NODE": 90.0, "ARG_OF_PERICENTER": 200.0,
            "MEAN_ANOMALY": 100.0, "BSTAR": 0.0, "EPHEMERIS_TYPE": 0,
            "ELEMENT_SET_NO": 999, "REV_AT_EPOCH": 2900
        ]
        return try #require(GPService.parseOMM(r))
    }

    private var startDate: Date {
        ISO8601DateFormatter().date(from: "2026-11-16T00:00:00Z")!
    }

    // MARK: M4 — malformed OMM

    @Test(arguments: ["NORAD_CAT_ID", "EPHEMERIS_TYPE", "ELEMENT_SET_NO", "REV_AT_EPOCH"])
    func nonFiniteOrOverflowingIntegerFieldIsSkipped(field: String) throws {
        for bad in ["nan", "inf", "-inf", "1e30"] as [Any] + [1e30 as Any] {
            let result = try parse([row([field: bad], norad: 11111), row(norad: 22222)])
            #expect(result.records.map(\.id) == [22222], "\(field)=\(bad) should be skipped")
            #expect(result.skipped == 1)
        }
    }

    @Test(arguments: ["MEAN_MOTION", "ECCENTRICITY", "INCLINATION", "RA_OF_ASC_NODE",
                      "ARG_OF_PERICENTER", "MEAN_ANOMALY", "BSTAR"])
    func nonFiniteElementIsSkipped(field: String) throws {
        for bad in ["nan", "inf", "-inf", "1e400"] {
            let result = try parse([row([field: bad], norad: 11111), row(norad: 22222)])
            #expect(result.records.map(\.id) == [22222], "\(field)=\(bad) should be skipped")
            #expect(result.skipped == 1)
        }
    }

    @Test func outOfRangeNoradAndEccentricityAreSkipped() throws {
        let result = try parse([
            row(["NORAD_CAT_ID": 0], norad: 1),
            row(["NORAD_CAT_ID": 1_000_000_000], norad: 2),
            row(["NORAD_CAT_ID": -5], norad: 3),
            row(["ECCENTRICITY": 1.2], norad: 4),
            row(["MEAN_MOTION": 0], norad: 5),
            row(norad: 400_000)
        ])
        #expect(result.records.map(\.id) == [400_000])
        #expect(result.skipped == 5)
    }

    @Test func csvImportReportsSkippedRows() {
        let csv = """
        OBJECT_NAME,NORAD_CAT_ID,EPOCH,MEAN_MOTION,ECCENTRICITY,INCLINATION,RA_OF_ASC_NODE,ARG_OF_PERICENTER,MEAN_ANOMALY,REV_AT_EPOCH
        GOOD,25544,\(Self.epochString),15.5,0.0005,51.6,120,90,270,100
        BAD,25545,\(Self.epochString),nan,0.0005,51.6,120,90,270,100
        HUGE,25546,\(Self.epochString),15.5,0.0005,51.6,120,90,270,1e30
        """
        let parsed = GPService.parseElementTextCounting(csv)
        #expect(parsed.records.map(\.id) == [25544])
        #expect(parsed.skipped == 2)
    }

    // MARK: M10 — Alpha-5

    @Test func alpha5CatalogField() {
        #expect(TLEFormatter.catalogField(99_999) == "99999")
        #expect(TLEFormatter.catalogField(25_544) == "25544")
        #expect(TLEFormatter.catalogField(100_000) == "A0000")
        #expect(TLEFormatter.catalogField(180_123) == "J0123")   // I is skipped
        #expect(TLEFormatter.catalogField(339_999) == "Z9999")
        #expect(TLEFormatter.catalogField(340_000) == nil)
        #expect(TLEFormatter.catalogField(999_999_999) == nil)
    }

    @Test func tleExportSkipsUnrepresentableIDs() throws {
        let ok = try #require(GPService.parseOMM(row(norad: 25544)))
        let big = try #require(GPService.parseOMM(row(norad: 340_001)))
        #expect(TLEFormatter.lines(for: big) == nil)
        let text = TLEFormatter.text(for: [ok, big])
        #expect(text.contains("1 25544U"))
        #expect(!text.contains("40001"))   // never the truncated (wrong) number
        #expect(TLEFormatter.unrepresentableCount([ok, big]) == 1)
        #expect(TLEFormatter.skippedNote(1) != nil)
        #expect(TLEFormatter.skippedNote(0) == nil)
    }

    // MARK: M2 — cooldown keys

    @Test func cooldownKeyDiffersPerGroupAndOverride() {
        var a = StorePreferences()
        a.celestrakGroup = "amateur"
        var b = a
        b.celestrakGroup = "weather"
        let keyA = OrbitStore.celestrakCooldownKey(for: a)
        #expect(keyA != OrbitStore.celestrakCooldownKey(for: b))
        #expect(keyA == OrbitStore.celestrakCooldownKey(for: a))   // stable

        var c = a
        c.celestrakURLOverride = "https://celestrak.org/NORAD/elements/gp.php?GROUP=geo&FORMAT=json"
        var d = a
        d.celestrakURLOverride = "https://celestrak.org/NORAD/elements/gp.php?GROUP=gps-ops&FORMAT=json"
        let keyC = OrbitStore.celestrakCooldownKey(for: c)
        #expect(keyC != keyA)
        #expect(keyC != OrbitStore.celestrakCooldownKey(for: d))
        #expect(keyC == OrbitStore.celestrakCooldownKey(for: c))
        #expect(keyC != OrbitStore.celestrakExtrasKey && keyA != OrbitStore.celestrakExtrasKey)
    }

    // MARK: M9 — GEO prediction

    @Test func geoCurrentOrNextPassIsFastAndContinuous() throws {
        let geo = try geoRecord()
        let sub = try OrbitPredictor.subpoint(geo, at: startDate)
        // An observer at 45° latitude under the satellite's longitude sees it well up.
        let observer = ObserverSite(name: "Test", latitude: 45, longitude: sub.longitude, altitudeMeters: 0)
        let clock = ContinuousClock()
        var pass: PredictedPass?
        let elapsed = try clock.measure {
            pass = try OrbitPredictor.currentOrNextPass(geo, observer: observer, from: startDate)
        }
        let window = try #require(pass)
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
        #expect(OrbitPredictor.isContinuousWindow(window))
        #expect(window.maxElevation > 20)

        // The sky path is capped and collapses to a handful of points.
        let path = try OrbitPredictor.skyPath(geo, observer: observer, pass: window)
        #expect(path.count <= OrbitPredictor.maxSkyPathPoints + 1)
        #expect(path.count <= 30)

        // nextEvent: always up, so no LOS, and fast.
        let elapsedEvent = try clock.measure {
            _ = try OrbitPredictor.nextEvent(geo, observer: observer, from: startDate)
        }
        #expect(elapsedEvent < .milliseconds(500))
    }

    @Test func geoBelowHorizonReturnsNilFast() throws {
        let geo = try geoRecord()
        let sub = try OrbitPredictor.subpoint(geo, at: startDate)
        let opposite = sub.longitude > 0 ? sub.longitude - 180 : sub.longitude + 180
        let observer = ObserverSite(name: "Antipode", latitude: 0, longitude: opposite, altitudeMeters: 0)
        let clock = ContinuousClock()
        var pass: PredictedPass?
        let elapsed = try clock.measure {
            pass = try OrbitPredictor.currentOrNextPass(geo, observer: observer, from: startDate)
        }
        #expect(pass == nil)
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }

    @Test func leoPassStillResolvesAtFullResolution() throws {
        let leo = try #require(GPService.parseOMM(row(norad: 25544)))
        let observer = ObserverSite(name: "Test", latitude: 40, longitude: -75, altitudeMeters: 0)
        let pass = try #require(try OrbitPredictor.currentOrNextPass(leo, observer: observer, from: startDate, horizonDays: 2))
        let minutes = pass.los.timeIntervalSince(pass.aos) / 60
        #expect(minutes > 0 && minutes < 20)
        #expect(!OrbitPredictor.isContinuousWindow(pass))
        #expect(OrbitPredictor.scanStep(leo, base: 20) == 20)
        // A ~10 min pass at 20 s is ~30 points — untouched by the cap or collapse.
        let path = try OrbitPredictor.skyPath(leo, observer: observer, pass: pass)
        #expect(path.count >= Int(minutes * 3) - 1)
    }

    // MARK: M3 — imported-elements overlay precedence

    @Test func overlayPrecedenceNewerImportWinsUntilFeedCatchesUp() throws {
        let older = try #require(GPService.parseOMM(row(["EPOCH": "2026-11-10T00:00:00"], norad: 25544)))
        let newer = try #require(GPService.parseOMM(row(["EPOCH": "2026-11-14T00:00:00"], norad: 25544)))
        let other = try #require(GPService.parseOMM(row(["EPOCH": "2026-11-01T00:00:00"], norad: 99001)))

        // Import newer than the feed: active.
        let imported = [ImportedElementSet(record: newer), ImportedElementSet(record: other)]
        var resolved = ImportedElementSet.resolve(imported, feedEpochs: [25544: older.epoch])
        #expect(Set(resolved.active.map(\.norad)) == [25544, 99001])   // 99001 isn't in the feed
        #expect(resolved.superseded.isEmpty)

        // Feed catches up (same epoch) or passes it: the feed wins; prune the import.
        resolved = ImportedElementSet.resolve(imported, feedEpochs: [25544: newer.epoch])
        #expect(resolved.active.map(\.norad) == [99001])
        #expect(resolved.superseded.map(\.norad) == [25544])
        resolved = ImportedElementSet.resolve(imported, feedEpochs: [25544: newer.epoch.addingTimeInterval(86400)])
        #expect(resolved.superseded.map(\.norad) == [25544])
    }

    @Test func overlayRoundTripsThroughJSON() throws {
        let rec = try #require(GPService.parseOMM(row(norad: 25544)))
        let entry = ImportedElementSet(record: rec, importedAt: startDate)
        let data = try JSONEncoder().encode([entry])
        let back = try JSONDecoder().decode([ImportedElementSet].self, from: data)
        #expect(back == [entry])
        #expect(back[0].record.id == 25544)
        #expect(abs(back[0].record.meanMotionRevPerDay - 15.5) < 1e-9)
        #expect(back[0].record.bstar == 0.0001)
    }

    @Test func tleRecordKeepsKozaiMeanMotionAndBstar() throws {
        let tle = """
        ISS (ZARYA)
        1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927
        2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537
        """
        let record = try #require(GPService.parseTLEText(tle).first)
        #expect(abs(record.meanMotionRevPerDay - 15.72125391) < 1e-8)
        #expect(abs(record.bstar - -0.11606e-4) < 1e-12)
    }
}
