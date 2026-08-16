import Foundation
import SatelliteKit

@main
struct Parity097Smoke {
    static func sat(_ id: UInt, name: String, anomaly: Double, tx: [TransponderRecord] = []) -> SatelliteRecord {
        let epoch = Date(timeIntervalSince1970: 1_786_733_000)
        let elements = Elements(commonName: name, noradIndex: id, launchName: "2026-001A", t₀: epoch,
                                e₀: 0.001, i₀: 51.6, ω₀: 20, Ω₀: 30, M₀: anomaly, n₀: 15.2,
                                ephemType: 0, tleClass: "U", tleNumber: 1, revNumber: 1, dragCoeff: 0.0001)
        return SatelliteRecord(id: id, name: name, internationalDesignator: "2026-001A", epoch: epoch,
                               meanMotionRevPerDay: 15.2, eccentricity: 0.001, inclinationDeg: 51.6,
                               raanDeg: 30, argumentOfPerigeeDeg: 20, meanAnomalyDeg: anomaly,
                               bstar: 0.0001, elements: elements, transponders: tx, isManual: false)
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_786_733_000)
        let tp = TransponderRecord(id: "linear", description: "Linear test", downlinkLow: 145_950_000,
                                   downlinkHigh: 145_970_000, uplinkLow: 435_050_000,
                                   uplinkHigh: 435_070_000, mode: "SSB/CW", invert: true,
                                   type: "Transponder", baud: 0, service: "Amateur")
        let a = sat(99971, name: "PARITY 097 A", anomaly: 0, tx: [tp])
        let b = sat(99972, name: "PARITY 097 B", anomaly: 4)
        let sp = try OrbitPredictor.subpoint(a, at: now)
        let home = ObserverSite(name: "Home", latitude: sp.latitude, longitude: sp.longitude, altitudeMeters: 20)

        let bands = FeatureCompletionEngine.emeBandAnalysis(site: home, at: now, solarFlux: 120)
        guard bands.count == 5,
              abs((bands.first { $0.frequencyMHz == 144 }?.faradayDegrees ?? 0) - 90) < 0.001,
              abs((bands.first { $0.frequencyMHz == 144 }?.librationSpreadHz ?? 0) - 2.5) < 0.001 else {
            fatalError("EME band analysis")
        }
        let plan = FeatureCompletionEngine.emePlan(from: now, days: 90)
        guard plan.count == 90 else { fatalError("EME 90-day plan") }

        let sky = FeatureEngine.skyObjects(site: home, at: now, selectedSatellite: a)
        guard sky.count >= 17,
              sky.contains(where: { $0.name == "Cold sky (ref)" }),
              sky.contains(where: { $0.name == a.name && $0.category == "Satellite" }) else {
            fatalError("celestial roster")
        }

        let event = ConjunctionRecord(id: now, date: now, missDistanceKm: 12.3, relativeVelocityKmS: 1.2)
        let detail = try FeatureCompletionEngine.conjunctionDetail(primary: a, secondary: b, event: event)
        guard detail.curve.count >= 40, detail.primaryAltitudeKm > 0,
              detail.secondarySpeedKmS > 0, !detail.awarenessLabel.isEmpty else {
            fatalError("conjunction detail")
        }

        let pass = PredictedPass(id: now, aos: now, los: now.addingTimeInterval(600),
                                 tca: now.addingTimeInterval(300), maxElevation: 70,
                                 aosAzimuth: 20, losAzimuth: 210)
        let rows = try FeatureCompletionEngine.radioPlaybook(satellite: a, observer: home, pass: pass,
                                                              transponder: tp, intervalSeconds: 60,
                                                              hold: "downlink", passbandPercent: 50)
        let passband = FeatureCompletionEngine.passbandPlan(tp)
        let link = FeatureCompletionEngine.linkBudget(rangeKm: 1000, frequencyHz: 145_960_000,
                                                       txPowerW: 1, txGainDb: 2, rxGainDb: 12,
                                                       lineLossDb: 1.5)
        guard rows.count == 11, passband.count == 11, link.freeSpacePathLossDb > 100,
              rows.allSatisfy({ $0.receiveHz > 0 && $0.transmitHz > 0 }) else {
            fatalError("radio parity")
        }

        let eclipses = try FeatureCompletionEngine.satelliteEclipses(satellite: a, from: now, days: 2)
        let daily = FeatureCompletionEngine.satelliteEclipseDailySummary(satellite: a, periods: eclipses,
                                                                          from: now, days: 2)
        guard daily.count == 2,
              eclipses.allSatisfy({ $0.exit >= $0.enter && $0.durationSeconds >= 0 }),
              daily.allSatisfy({ $0.percentOfDay >= 0 && $0.percentOfDay <= 100 }) else {
            fatalError("eclipse ephemeris")
        }
        let eCSV = OrbitExportService.satelliteEclipseCSV(periods: eclipses, daily: daily, satellite: a)
        let ePDF = OrbitExportService.satelliteEclipsePDF(periods: eclipses, daily: daily, satellite: a, days: 2)
        guard eCSV.contains("enter_utc"), eCSV.contains("percent_of_day"), !ePDF.isEmpty else { fatalError("eclipse export") }

        let extra = GPService.makeExtraRecord(ManualSatelliteDefinition(record: a))
        guard !extra.isManual, extra.id == a.id else { fatalError("extra satellite snapshot") }
        let hit = NewLaunchHit(id: a.id, name: a.name, transmitterCount: 1,
                               downlinkHz: tp.downlinkLow, mode: tp.mode,
                               alreadyInCatalog: false, record: a, transponders: [tp])
        let launchCSV = OrbitExportService.newLaunchesCSV([hit])
        let launchPDF = OrbitExportService.newLaunchesPDF([hit])
        guard launchCSV.contains(a.name), launchCSV.contains(String(a.id)), !launchPDF.isEmpty else { fatalError("new launch export") }

        let radioCSV = OrbitExportService.radioPlaybookCSV(rows, satellite: a, transponder: tp, hold: "downlink")
        let radioPDF = OrbitExportService.radioPlaybookPDF(rows, satellite: a, transponder: tp, hold: "downlink", pass: pass)
        let emeCSV = OrbitExportService.emeBandAnalysisCSV(bands, observer: home, at: now)
        let emePDF = OrbitExportService.emeBandAnalysisPDF(bands, observer: home, at: now)
        let conjPDF = OrbitExportService.conjunctionsPDF([event], primary: a, secondary: b, hours: 6, thresholdKm: 800)
        guard radioCSV.contains("range_rate_km_s"), emeCSV.contains("faraday_deg"),
              !radioPDF.isEmpty, !emePDF.isEmpty, !conjPDF.isEmpty else { fatalError("specialist exports") }

        print("PARITY097_OK eme=\(bands.count)/\(plan.count) sky=\(sky.count) conj=\(detail.curve.count) radio=\(rows.count) eclipses=\(eclipses.count) daily=\(daily.count) newlaunch=1")
    }
}
