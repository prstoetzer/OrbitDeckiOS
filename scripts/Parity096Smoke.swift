import Foundation
import SatelliteKit

@main
struct Parity096Smoke {
    static func satellite() -> SatelliteRecord {
        let epoch = Date(timeIntervalSince1970: 1_770_000_000)
        let elements = Elements(commonName: "PARITY 096", noradIndex: 99961, launchName: "TEST", t₀: epoch,
                                e₀: 0.001, i₀: 51.6, ω₀: 20, Ω₀: 30, M₀: 40, n₀: 15.5,
                                ephemType: 0, tleClass: "U", tleNumber: 1, revNumber: 1, dragCoeff: 0.00025)
        return SatelliteRecord(id: 99961, name: "PARITY 096", internationalDesignator: "TEST", epoch: epoch,
                               meanMotionRevPerDay: 15.5, eccentricity: 0.001, inclinationDeg: 51.6,
                               raanDeg: 30, argumentOfPerigeeDeg: 20, meanAnomalyDeg: 40, bstar: 0.00025,
                               elements: elements, transponders: [], isManual: true)
    }

    static func history() -> [OrbitalHistorySample] {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        return (0..<10).map { i in
            let days = Double(i * 20)
            // A slowly shortening period creates a positive mean-motion trend.
            let period = 92.90 - Double(i) * 0.006
            // Deliberately accelerate apogee decline late in the record.
            let apogee = 425.0 - (i < 5 ? Double(i) * 0.8 : 3.2 + Double(i - 4) * 2.0)
            return OrbitalHistorySample(epoch: start.addingTimeInterval(days * 86400),
                                        semiMajorAxis: 6798 - Double(i) * 0.7,
                                        eccentricity: 0.001 - Double(i) * 0.00001,
                                        inclination: 51.6,
                                        period: period,
                                        apogee: apogee,
                                        perigee: 405 - Double(i) * 0.5,
                                        bstar: 0.00025 + Double(i) * 0.000002)
        }
    }

    static func main() throws {
        let dailyA = """
        :Product: Daily Geomagnetic Data
        Middle Latitude
        2026 08 13   8  2 2 2 2 2 2 2 2
        High Latitude
        Estimated Planetary
        2026 08 13  11  2 2 2 3 3 2 2 2
        2026 08 14  17  3 3 4 4 3 3 2 2
        """
        guard SpaceWeatherService.parsePlanetaryA(Data(dailyA.utf8)) == 17 else {
            fatalError("planetary A parser")
        }
        let oldWeatherJSON = #"{"fetchedAt":1000,"flux":120,"kp":2,"aIndex":7,"sunspotNumber":90,"flux90Day":115}"#.data(using: .utf8)!
        let oldWeather = try JSONDecoder().decode(SpaceWeatherSnapshot.self, from: oldWeatherJSON)
        guard oldWeather.aIndex == 7, oldWeather.aIndexSource == nil else { fatalError("weather cache migration") }

        let sat = satellite()
        let workbook = XLSXExportService.workbook(sheets: [
            XLSXSheet(name: "Passes", rows: [
                [.text("AOS"), .text("Satellite"), .text("Max El")],
                [.text("2026-08-14 20:00"), .text("AO-7 & <test>"), .number(42.5)]
            ]),
            XLSXSheet(name: "Station", rows: [[.text("Grid"), .text("FN20")]])
        ])
        guard workbook.count > 2000, workbook.prefix(2) == Data([0x50, 0x4b]) else { fatalError("XLSX package") }
        try workbook.write(to: URL(fileURLWithPath: "/tmp/orbitdeck096.xlsx"))
        let passWorkbook = OrbitExportService.passScheduleXLSX([], satellite: sat, observer: .init(name: "Home", latitude: 39.93, longitude: -74.89, altitudeMeters: 20))
        try passWorkbook.write(to: URL(fileURLWithPath: "/tmp/orbitdeck-pass096.xlsx"))

        let samples = history()
        let window = FeatureEngine.historyWindow(samples, lower: 0.25, upper: 0.75)
        guard !window.isEmpty, window.count < samples.count else { fatalError("history window") }
        let rates = FeatureEngine.historyRateSeries(samples, column: .apogee)
        guard rates.count == samples.count - 1 else { fatalError("history rates") }
        guard let analysis = FeatureEngine.analyzeHistoryRate(samples, column: .apogee),
              analysis.intervalCount == rates.count,
              analysis.peakRate < 0,
              !analysis.verdict.isEmpty else { fatalError("history analysis") }
        guard let ndot = FeatureEngine.historyNdot(samples), ndot > 0 else { fatalError("history n-dot") }
        let decay = FeatureEngine.historyDecayEstimate(samples, satellite: sat)
        guard decay.days >= 0, !decay.source.isEmpty else { fatalError("history decay") }
        let csv = OrbitExportService.orbitalHistorySamplesCSV(window)
        guard csv.contains("semi_major_axis_km"), csv.contains("2020") else { fatalError("history CSV") }
        let pdf = OrbitExportService.orbitalHistoryReportPDF(samples, satellite: sat, lower: 0.25, upper: 0.75)
        guard !pdf.isEmpty else { fatalError("history PDF") }

        let ndotText = String(format: "%.6g", ndot)
        print("PARITY096_OK xlsx=\(workbook.count) A=17 history=\(samples.count)/\(window.count) rates=\(rates.count) jumps=\(analysis.jumps.count) ndot=\(ndotText) decay=\(decay.source)")
    }
}
