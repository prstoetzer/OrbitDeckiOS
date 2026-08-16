import Foundation
import SatelliteKit

@main
struct Parity095Smoke {
    static func sat(_ id: UInt, name: String, meanMotion: Double, transponders: [TransponderRecord] = []) -> SatelliteRecord {
        let epoch = Date(timeIntervalSince1970: 1_776_000_000)
        let e = Elements(commonName: name, noradIndex: id, launchName: "TEST", t₀: epoch,
                         e₀: 0.001, i₀: 51.6, ω₀: 20, Ω₀: 30, M₀: 40, n₀: meanMotion,
                         ephemType: 0, tleClass: "U", tleNumber: 1, revNumber: 1, dragCoeff: 0.0001)
        return SatelliteRecord(id: id, name: name, internationalDesignator: "TEST", epoch: epoch,
                               meanMotionRevPerDay: meanMotion, eccentricity: 0.001,
                               inclinationDeg: 51.6, raanDeg: 30, argumentOfPerigeeDeg: 20,
                               meanAnomalyDeg: 40, bstar: 0.0001, elements: e,
                               transponders: transponders, isManual: true)
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_786_733_000)
        let tp = TransponderRecord(id: "lin", description: "Linear test", downlinkLow: 145_950_000,
                                   downlinkHigh: 145_970_000, uplinkLow: 435_050_000,
                                   uplinkHigh: 435_070_000, mode: "SSB/CW", invert: true,
                                   type: "Transponder", baud: 0, service: "Amateur")
        let leo = sat(99951, name: "PARITY 095", meanMotion: 15.2, transponders: [tp])
        let sp = try OrbitPredictor.subpoint(leo, at: now)
        let home = ObserverSite(name: "Home", latitude: sp.latitude, longitude: sp.longitude, altitudeMeters: 20)
        let dx = ObserverSite(name: "DX", latitude: sp.latitude + 1.0, longitude: sp.longitude + 1.0, altitudeMeters: 30)

        let raster = try OrbitExportService.illuminationRaster(satellite: leo, days: 2, rowsPerOrbit: 16, start: now)
        guard raster.cells.count == 32, raster.daySunlitFractions.count == 2,
              raster.meanSunlitFraction >= 0, raster.meanSunlitFraction <= 1 else {
            fatalError("illumination raster")
        }
        let progression = try OrbitExportService.progressionPasses(satellite: leo, observer: home,
                                                                    minElevation: 5, days: 2, start: now)
        guard !progression.isEmpty else { fatalError("progression passes") }

        let illumPDF = try OrbitExportService.illuminationReportPDF(satellite: leo, days: 2, generatedAt: now)
        let progressionPDF = try OrbitExportService.progressionReportPDF(satellite: leo, observer: home,
                                                                          minElevation: 5, days: 2, generatedAt: now)
        guard !illumPDF.isEmpty, !progressionPDF.isEmpty else { fatalError("standalone reports") }

        let mutualPDF = try OrbitExportService.mutualWindowsReportPDF(satellite: leo, home: home, dx: dx,
                                                                      minimumElevation: 0, days: 0.5,
                                                                      generatedAt: now)
        guard !mutualPDF.isEmpty else { fatalError("mutual report") }

        let windows = try FeatureEngine.mutualWindows(leo, home: home, dx: dx, from: now,
                                                       days: 0.5, minimumElevation: 0, step: 30, maxCount: 4)
        guard let window = windows.first else { fatalError("mutual window fixture") }
        let activation = ActivationRecord(id: "fixture", title: "Fixture activation", date: "2026-08-14",
                                          callsign: "N8HM/P", satellite: leo.name, grid: "TEST",
                                          start: "", end: "", maximumElevation: "", frequency: "145.960",
                                          mode: "SSB", comment: "fixture")
        let detail = ActivationDetailResult(activation: activation, satellite: leo, dxSite: dx,
                                            listedDate: now, windows: windows)
        let rows = try DXDopplerEngine.table(satellite: leo, home: home, dx: dx, transponder: tp,
                                             window: window, offsetHz: 5_000, mode: .fixedDownlink,
                                             anchor: .dxRX, step: 30)
        guard rows.count >= 2 else { fatalError("DX Doppler rows") }
        let operatingCSV = OrbitExportService.activationOperatingCSV(detail: detail, home: home, window: window,
                                                                      transponder: tp, rows: rows,
                                                                      mode: .fixedDownlink, anchor: .dxRX,
                                                                      offsetHz: 5_000)
        guard operatingCSV.contains("activation_callsign"), operatingCSV.contains("N8HM/P"),
              operatingCSV.contains("fixedDownlink") else { fatalError("activation CSV") }
        let operatingPDF = OrbitExportService.activationOperatingPDF(detail: detail, home: home, window: window,
                                                                      transponder: tp, rows: rows,
                                                                      mode: .fixedDownlink, anchor: .dxRX,
                                                                      offsetHz: 5_000)
        guard !operatingPDF.isEmpty else { fatalError("activation PDF") }

        let host = TinyBasicHostContext(observer: home, satellites: [leo], selectedNorad: leo.id,
                                        favorites: [leo.id], weather: nil, minimumElevation: 5, now: now)
        let snapshot = host.snapshot()
        guard abs(snapshot["MAGDECL"] ?? 0) > 0.01 else { fatalError("planning magnetic declination") }

#if !canImport(UIKit)
        let illumText = String(data: illumPDF, encoding: .utf8) ?? ""
        let progText = String(data: progressionPDF, encoding: .utf8) ?? ""
        let mutualText = String(data: mutualPDF, encoding: .utf8) ?? ""
        guard illumText.contains("illumination report"), progText.contains("progression"),
              mutualText.contains("mutual-window report") else { fatalError("report fallbacks") }
#endif
        let mag = String(format: "%.2f", snapshot["MAGDECL"] ?? 0)
        print("PARITY095_OK raster=\(raster.cells.count) progression=\(progression.count) mutual=\(windows.count) dxdoppler=\(rows.count) basicMag=\(mag)")
    }
}
