import Foundation
import SatelliteKit

@main
struct Parity093Smoke {
    static func sat(_ id: UInt, name: String, meanMotion: Double, transponders: [TransponderRecord] = []) -> SatelliteRecord {
        let epoch = Date(timeIntervalSince1970: 1_786_733_000)
        let e = Elements(commonName: name, noradIndex: id, launchName: "TEST", t₀: epoch,
                         e₀: 0.001, i₀: 51.6, ω₀: 20, Ω₀: 30, M₀: 40, n₀: meanMotion,
                         ephemType: 0, tleClass: "U", tleNumber: 1, revNumber: 1, dragCoeff: 0)
        return SatelliteRecord(id: id, name: name, internationalDesignator: "TEST", epoch: epoch,
                               meanMotionRevPerDay: meanMotion, eccentricity: 0.001,
                               inclinationDeg: 51.6, raanDeg: 30, argumentOfPerigeeDeg: 20,
                               meanAnomalyDeg: 40, bstar: 0, elements: e,
                               transponders: transponders, isManual: true)
    }

    static func main() throws {
        guard WorldMapData.coastlines.count == 19 else { fatalError("coastline polyline count") }
        let coastPoints = WorldMapData.coastlines.reduce(0) { $0 + $1.count }
        guard coastPoints == 375 else { fatalError("coastline point count") }

        let home = ObserverSite(name: "Home", latitude: 39.93, longitude: -74.89, altitudeMeters: 20)
        let dx = ObserverSite(name: "DX", latitude: 51.5, longitude: -0.1, altitudeMeters: 25)
        let tp = TransponderRecord(id: "lin", description: "Linear test", downlinkLow: 145_950_000,
                                   downlinkHigh: 145_970_000, uplinkLow: 435_050_000,
                                   uplinkHigh: 435_070_000, mode: "SSB/CW", invert: true,
                                   type: "Transponder", baud: 0, service: "Amateur")
        let leo = sat(99901, name: "LEO TEST", meanMotion: 15.2, transponders: [tp])
        let high = sat(99902, name: "HIGH TEST", meanMotion: 2.0)

        let start = Date(timeIntervalSince1970: 1_786_733_000)
        let refs = try OrbitExportService.referenceOrbitRows(satellite: leo, observer: home, days: 30, start: start)
        guard refs.count == 30 else { fatalError("reference orbit row count") }
        guard refs.map(\.date).sorted() == refs.map(\.date) else { fatalError("reference dates unordered") }

        let refPdf = OrbitExportService.referenceOrbitsPDF(satellites: [high], observer: home, days: 30, start: start)
        guard !refPdf.isEmpty else { fatalError("empty reference PDF") }
        let locator = OrbitExportService.oscarLocatorPDF(satellite: leo, observer: home, at: start)
        guard !locator.isEmpty else { fatalError("empty OSCARLOCATOR printable") }
#if !canImport(UIKit)
        let refText = String(data: refPdf, encoding: .utf8) ?? ""
        guard refText.contains("HIGH TEST") && refText.contains("no useful daily equator-crossing reference") else {
            fatalError("reference fallback missing high-orbit notice")
        }
        let locatorText = String(data: locator, encoding: .utf8) ?? ""
        guard locatorText.contains("three-sheet") && locatorText.contains("Base map") && locatorText.contains("Path arc") else {
            fatalError("OSCARLOCATOR fallback missing sheet set")
        }
#endif

        let activation = ActivationRecord(id: "a", title: "Test", date: "2026-08-14", callsign: "N8HM",
                                          satellite: "LEO TEST", grid: "IO91wm", start: "", end: "",
                                          maximumElevation: "", frequency: "145.960 MHz", mode: "SSB", comment: "")
        guard let match = DXDopplerEngine.matchingTransponder(activation, in: leo), match.leg == "downlink" else {
            fatalError("activation transponder match")
        }
        let window = MutualWindowRecord(id: start, start: start, end: start.addingTimeInterval(60), myMaxElevation: 45, dxMaxElevation: 35)
        let rows = try DXDopplerEngine.table(satellite: leo, home: home, dx: dx, transponder: tp,
                                             window: window, offsetHz: 10_000, mode: .trueRule, anchor: .myTX, step: 30)
        guard rows.count == 3 else { fatalError("doppler table rows") }
        for row in rows {
            guard row.myRX > 0, row.myTX > 0, row.dxRX > 0, row.dxTX > 0 else { fatalError("doppler dial value") }
        }
        let solved = DXDopplerEngine.solvePassbandOffset(targetHz: 145_960_000, satellite: leo, home: home, dx: dx,
                                                          transponder: tp, reference: start, mode: .fixedDownlink, anchor: .dxRX)
        guard solved >= 0 && solved <= tp.bandwidth else { fatalError("passband solve bounds") }

        print("PARITY093_OK coastlines=\(WorldMapData.coastlines.count)/\(coastPoints) refs=\(refs.count) dopplerRows=\(rows.count) solved=\(solved) refBytes=\(refPdf.count) locatorBytes=\(locator.count)")
    }
}
