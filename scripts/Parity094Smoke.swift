import Foundation
import SatelliteKit

@main
struct Parity094Smoke {
    static func sat(_ id: UInt, name: String, meanMotion: Double, bstar: Double = 0.0001, transponders: [TransponderRecord] = []) -> SatelliteRecord {
        let epoch = Date(timeIntervalSince1970: 1_776_000_000)
        let e = Elements(commonName: name, noradIndex: id, launchName: "TEST", t₀: epoch,
                         e₀: 0.001, i₀: 51.6, ω₀: 20, Ω₀: 30, M₀: 40, n₀: meanMotion,
                         ephemType: 0, tleClass: "U", tleNumber: 1, revNumber: 1, dragCoeff: bstar)
        return SatelliteRecord(id: id, name: name, internationalDesignator: "TEST", epoch: epoch,
                               meanMotionRevPerDay: meanMotion, eccentricity: 0.001,
                               inclinationDeg: 51.6, raanDeg: 30, argumentOfPerigeeDeg: 20,
                               meanAnomalyDeg: 40, bstar: bstar, elements: e,
                               transponders: transponders, isManual: true)
    }

    static func main() throws {
        guard DXCCNumericData.entities.count == 340, DXCCNumericData.nameByCode.count == 340 else {
            fatalError("DXCC roster count")
        }
        guard Set(DXCCNumericData.entities.map(\.code)) == Set(DXCCNumericData.nameByCode.keys) else {
            fatalError("DXCC coordinate/name code mismatch")
        }
        guard DXCCNumericData.nameByCode[1] == "Canada",
              DXCCNumericData.nameByCode[5] == "Aland Is.",
              DXCCNumericData.nameByCode[94] == "Antigua & Barbuda",
              DXCCNumericData.nameByCode[291] == "United States of America",
              DXCCNumericData.nameByCode[339] == "Japan" else { fatalError("known DXCC names") }
        guard let japan = DXCCNumericData.byCode[339], abs(japan.latitude - 36.40) < 0.001, abs(japan.longitude - 138.38) < 0.001 else {
            fatalError("Japan coordinate")
        }
        guard DXCCNumericData.byCode[23] == nil, DXCCNumericData.nameByCode[23] == nil else {
            fatalError("deleted entity should not be current")
        }
        let nativeCodeCoverage = DXCCData.entities.filter { DXCCNumericData.codeByName[$0.name] != nil }.count
        guard nativeCodeCoverage == 340 else { fatalError("native DXCC name/code coverage \(nativeCodeCoverage)/340") }
        guard let dxccReference = OrbitReferences.tables.first(where: { $0.id == "dxcc" }),
              dxccReference.rows.count == 340,
              dxccReference.rows.allSatisfy({ $0.a.contains(" · ") }) else { fatalError("DXCC reference code column") }

        let basic = try CardSatTinyBasicEngine().run("10 PRINT DXCC$(1)\n20 PRINT DXCC$(5)\n30 PRINT DXCC$(94)\n40 PRINT DXCC$(291)\n50 PRINT DXCC$(339)\n60 PRINT ROUND(DXCCLAT(339));\",\";ROUND(DXCCLON(339))")
        guard basic.output == ["Canada", "Aland Is.", "Antigua & Barbuda", "United States of America", "Japan", "36,138"] else {
            fatalError("BASIC DXCC bridge: \(basic.output)")
        }

        let home = ObserverSite(name: "Home", latitude: 39.93, longitude: -74.89, altitudeMeters: 20)
        let second = ObserverSite(name: "DX", latitude: 51.5, longitude: -0.1, altitudeMeters: 25)
        let tp = TransponderRecord(id: "lin", description: "Linear test", downlinkLow: 145_950_000,
                                   downlinkHigh: 145_970_000, uplinkLow: 435_050_000,
                                   uplinkHigh: 435_070_000, mode: "SSB/CW", invert: true,
                                   type: "Transponder", baud: 0, service: "Amateur")
        let leo = sat(99901, name: "LEO TEST", meanMotion: 15.2, transponders: [tp])
        let now = Date(timeIntervalSince1970: 1_786_733_000)
        let host = TinyBasicHostContext(observer: home, satellites: [leo], selectedNorad: leo.id,
                                        favorites: [leo.id], weather: nil, minimumElevation: 5, now: now)
        let snap = host.snapshot()
        guard let lst = snap["LSTHR"], lst >= 0, lst < 24 else { fatalError("LSTHR") }
        guard (snap["GPAGE"] ?? 0) > 1 else { fatalError("GPAGE") }
        guard (snap["SATOK"] ?? 0) == 1, (snap["BFIELD"] ?? 0) > 0 else { fatalError("host satellite snapshot") }
        guard let tx = host.transponderValues(leo, index: 0),
              (tx["DOPPRX"] ?? 0) > 100_000_000,
              (tx["DOPPTX"] ?? 0) > 400_000_000 else { fatalError("full CAT Doppler dials") }

        let report = try OrbitExportService.satelliteReportPDF(satellite: leo, observer: home, minElevation: 5, days: 3, generatedAt: now)
        guard !report.isEmpty else { fatalError("satellite report") }
        let favoriteReport = OrbitExportService.favoritesPassSchedulePDF(satellites: [leo], observer: home, minElevation: 5, days: 3, generatedAt: now)
        guard !favoriteReport.isEmpty else { fatalError("favorites report") }
        let siteReport = OrbitExportService.siteComparisonPDF(satellite: leo, sites: [home, second], minElevation: 5, days: 3)
        guard !siteReport.isEmpty else { fatalError("site report") }
#if !canImport(UIKit)
        let reportText = String(data: report, encoding: .utf8) ?? ""
        guard reportText.contains("Orbital analysis") && reportText.contains("Equator crossings") else { fatalError("report fallback") }
        let favText = String(data: favoriteReport, encoding: .utf8) ?? ""
        guard favText.contains("Favorite satellites") else { fatalError("favorites fallback") }
        let siteText = String(data: siteReport, encoding: .utf8) ?? ""
        guard siteText.contains("passes by site") else { fatalError("site fallback") }
#endif
        let lstText = String(format: "%.3f", lst)
        let rx = Int(tx["DOPPRX"] ?? 0)
        print("PARITY094_OK dxcc=\(DXCCNumericData.entities.count)/\(nativeCodeCoverage) lst=\(lstText) dopprx=\(rx) reportBytes=\(report.count)")
    }
}
