import Foundation
#if canImport(UIKit)
import UIKit
#endif


/// The printable OSCARLOCATOR sheet(s) to export. Mirrors the desktop generator:
/// a full three-sheet set, either overlay on its own, the base map alone, or a
/// two-sheet (base + range circle) set.
enum OscarPDFKind: String, CaseIterable, Identifiable, Sendable {
    case fullSet = "Full set (3 sheets)"
    case baseMap = "Base map only"
    case rangeCircle = "Range circle only"
    case pathArc = "Path arc only"
    case baseAndRange = "Base + range circle"
    case qthCentered = "QTH-centered set (3 sheets)"
    case qthCombined = "QTH-centered · map+range + arc (2 sheets)"
    var id: String { rawValue }

    var includesBaseMap: Bool { self == .fullSet || self == .baseMap || self == .baseAndRange }
    var includesRangeCircle: Bool { self == .fullSet || self == .rangeCircle || self == .baseAndRange }
    var includesPathArc: Bool { self == .fullSet || self == .pathArc }
    /// Station-centered azimuthal-equidistant sheets instead of the polar set.
    var isQTHCentered: Bool { self == .qthCentered || self == .qthCombined }
}

struct PassComparisonEntry: Identifiable, Sendable {
    let satellite: SatelliteRecord
    let passCount: Int
    let bestPass: PredictedPass?
    var id: UInt { satellite.id }
}


struct ReferenceOrbitEntry: Identifiable, Sendable {
    let date: Date
    let crossing: Date?
    let longitude: Double?
    var id: Date { date }
}

struct IlluminationRasterSnapshot: Sendable {
    let days: Int
    let rowsPerOrbit: Int
    let periodMinutes: Double
    let cells: [Bool]
    let daySunlitFractions: [Double]
    let meanSunlitFraction: Double

    func isSunlit(day: Int, row: Int) -> Bool {
        guard day >= 0, day < days, row >= 0, row < rowsPerOrbit else { return false }
        return cells[day * rowsPerOrbit + row]
    }
}

struct OrbitExportService {
    static func passesCSV(_ passes: [PredictedPass], satellite: SatelliteRecord, observer: ObserverSite) -> String {
        let header = ["satellite", "norad", "station", "aos_utc", "los_utc", "tca_utc", "max_el_deg", "duration_min", "aos_az_deg", "los_az_deg"]
        var rows = [header]
        rows += passes.map { pass in
            [
                satellite.name,
                String(satellite.id),
                observer.name,
                iso(pass.aos), iso(pass.los), iso(pass.tca),
                String(format: "%.1f", pass.maxElevation),
                String(format: "%.1f", pass.duration / 60.0),
                String(format: "%.1f", pass.aosAzimuth),
                String(format: "%.1f", pass.losAzimuth)
            ]
        }
        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func passScheduleXLSX(_ passes: [PredictedPass], satellite: SatelliteRecord, observer: ObserverSite) -> Data {
        var rows: [[XLSXSheet.Cell]] = [[
            .text("AOS"), .text("LOS"), .text("TCA"), .text("Max El (deg)"),
            .text("Duration (min)"), .text("AOS az"), .text("LOS az")
        ]]
        rows += passes.map { pass in
            [
                .text(human(pass.aos)), .text(human(pass.los)), .text(human(pass.tca)),
                .number(pass.maxElevation), .number(pass.duration / 60.0),
                .number(pass.aosAzimuth), .number(pass.losAzimuth)
            ]
        }
        let metadata: [[XLSXSheet.Cell]] = [
            [.text("Satellite"), .text(satellite.name)],
            [.text("NORAD"), .integer(Int(satellite.id))],
            [.text("Station"), .text(observer.name)],
            [.text("Latitude"), .number(observer.latitude)],
            [.text("Longitude"), .number(observer.longitude)]
        ]
        return XLSXExportService.workbook(sheets: [
            XLSXSheet(name: "Passes", rows: rows),
            XLSXSheet(name: "Station", rows: metadata)
        ])
    }

    static func compactAOSLOSCSV(_ passes: [PredictedPass], satellite: SatelliteRecord) -> String {
        var rows = [["satellite","aos_utc","los_utc","duration","max_el_deg","aos_az_deg","los_az_deg"]]
        for pass in passes {
            let seconds = Int(pass.duration.rounded())
            let h = seconds / 3600, m = (seconds % 3600) / 60, sec = seconds % 60
            rows.append([satellite.name, human(pass.aos), human(pass.los), String(format:"%d:%02d:%02d",h,m,sec), String(format:"%.1f",pass.maxElevation), String(format:"%.0f",pass.aosAzimuth), String(format:"%.0f",pass.losAzimuth)])
        }
        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator:"\r\n") + "\r\n"
    }

    static func equatorCrossingsCSV(_ crossings: [(Date, Double)], satellite: SatelliteRecord) -> String {
        var rows = [["satellite","time_utc","eqx_longitude_deg"]]
        rows += crossings.map { [satellite.name, human($0.0), String(format:"%.2f",$0.1)] }
        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator:"\r\n") + "\r\n"
    }


    static func referenceOrbitRows(
        satellite: SatelliteRecord,
        observer: ObserverSite,
        days: Int = 60,
        start: Date = .now
    ) throws -> [ReferenceOrbitEntry] {
        let count = max(1, min(days, 366))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        guard let dayZero = calendar.date(from: components) else { return [] }
        let end = dayZero.addingTimeInterval(Double(count + 1) * 86400)
        let ascending = observer.latitude >= 0
        let nodes = try OrbitPredictor.equatorCrossings(
            satellite,
            from: dayZero,
            to: end,
            ascending: ascending
        )
        var cursor = 0
        var rows: [ReferenceOrbitEntry] = []
        rows.reserveCapacity(count)
        for offset in 0..<count {
            let ds = dayZero.addingTimeInterval(Double(offset) * 86400)
            let de = ds.addingTimeInterval(86400)
            while cursor < nodes.count && nodes[cursor].0 < ds { cursor += 1 }
            if cursor < nodes.count && nodes[cursor].0 < de {
                rows.append(.init(date: ds, crossing: nodes[cursor].0, longitude: nodes[cursor].1))
            } else {
                rows.append(.init(date: ds, crossing: nil, longitude: nil))
            }
        }
        return rows
    }

    static func referenceOrbitsPDF(
        satellites: [SatelliteRecord],
        observer: ObserverSite,
        days: Int = 60,
        start: Date = .now
    ) -> Data {
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let dayCount = max(1, min(days, 366))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HH:mm:ss"

        return renderer.pdfData { context in
            for satellite in satellites {
                if satellite.periodMinutes > 600 {
                    context.beginPage()
                    ("\(satellite.name) — OSCARLOCATOR Reference Orbits" as NSString).draw(
                        in: CGRect(x: 44, y: 58, width: 524, height: 40),
                        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.label]
                    )
                    ("This satellite is geosynchronous / high-altitude and does not have a useful daily equator-crossing reference orbit for a physical OSCARLOCATOR." as NSString).draw(
                        in: CGRect(x: 44, y: 145, width: 524, height: 110),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.secondaryLabel]
                    )
                    continue
                }
                let rows = (try? referenceOrbitRows(satellite: satellite, observer: observer, days: dayCount, start: start)) ?? []
                let descending = observer.latitude < 0
                let nodeName = descending ? "Descending" : "Ascending"
                let hemisphere = descending ? "southern" : "northern"

                for pageStart in stride(from: 0, to: max(rows.count, 1), by: 31) {
                    context.beginPage()
                    let title = "\(satellite.name) — OSCARLOCATOR Reference Orbits"
                    (title as NSString).draw(
                        in: CGRect(x: 44, y: 42, width: 524, height: 30),
                        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 17), .foregroundColor: UIColor.label]
                    )
                    ("First \(nodeName.lowercased()) equator crossing of each UTC day (\(hemisphere)-hemisphere station, lat \(String(format: "%.2f", observer.latitude))°)" as NSString).draw(
                        in: CGRect(x: 44, y: 74, width: 524, height: 28),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.secondaryLabel]
                    )
                    ("Set the path-arc overlay to the listed sub-longitude at the listed UTC time, then step forward one orbit per pass." as NSString).draw(
                        in: CGRect(x: 44, y: 98, width: 524, height: 30),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.secondaryLabel]
                    )

                    let headers = ["UTC date", "\(nodeName) UTC", "Sub-longitude"]
                    let xs: [CGFloat] = [54, 245, 405]
                    for (i, header) in headers.enumerated() {
                        (header as NSString).draw(
                            in: CGRect(x: xs[i], y: 142, width: 150, height: 18),
                            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.label]
                        )
                    }
                    var y: CGFloat = 168
                    let chunk = Array(rows.dropFirst(pageStart).prefix(31))
                    for (index, row) in chunk.enumerated() {
                        if index.isMultiple(of: 2) == false {
                            UIColor.secondarySystemBackground.setFill()
                            context.cgContext.fill(CGRect(x: 48, y: y - 3, width: 516, height: 19))
                        }
                        let date = dateFormatter.string(from: row.date)
                        let clock = row.crossing.map { timeFormatter.string(from: $0) } ?? "—"
                        let lon = row.longitude.map { String(format: "%.1f°%@", abs($0), $0 >= 0 ? "E" : "W") } ?? "—"
                        for (i, value) in [date, clock, lon].enumerated() {
                            (value as NSString).draw(
                                in: CGRect(x: xs[i], y: y, width: 150, height: 17),
                                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: UIColor.label]
                            )
                        }
                        y += 19
                    }
                    ("OrbitDeck · Paul Stoetzer, N8HM · reference-orbit planning sheet · \(observer.name)" as NSString).draw(
                        in: CGRect(x: 44, y: 754, width: 524, height: 16),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: UIColor.secondaryLabel]
                    )
                }
            }
        }
#else
        var lines = ["OrbitDeck OSCARLOCATOR Reference Orbits", "Station: \(observer.name)"]
        for satellite in satellites {
            lines.append("\n\(satellite.name)")
            if satellite.periodMinutes > 600 {
                lines.append("This satellite is geosynchronous / high-altitude and has no useful daily equator-crossing reference orbit.")
                continue
            }
            if let rows = try? referenceOrbitRows(satellite: satellite, observer: observer, days: days, start: start) {
                for row in rows {
                    let date = ISO8601DateFormatter().string(from: row.date)
                    let crossing = row.crossing.map { iso($0) } ?? "—"
                    let lon = row.longitude.map { String(format: "%.1f", $0) } ?? "—"
                    lines.append("\(date)\t\(crossing)\t\(lon)")
                }
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
#endif
    }

    static func steppedListingCSV(satellite: SatelliteRecord, observer: ObserverSite, hours: Double = 6, stepSeconds: TimeInterval = 60, start: Date = .now) throws -> String {
        var rows = [["satellite","site","time_utc","az_deg","el_deg","range_km","range_rate_kms","sub_lat","sub_lon","alt_km","sunlit"]]
        var t = start
        let end = start.addingTimeInterval(max(0.1,hours)*3600)
        while t <= end {
            let look = try OrbitPredictor.look(satellite, observer: observer, at: t)
            rows.append([satellite.name, observer.name, human(t), String(format:"%.1f",look.azimuth), String(format:"%.1f",look.elevation), String(format:"%.0f",look.rangeKm), String(format:"%.3f",look.rangeRateKmS), String(format:"%.2f",look.subLatitude), String(format:"%.2f",look.subLongitude), String(format:"%.0f",look.altitudeKm), look.sunlit ? "yes":"no"])
            t = t.addingTimeInterval(max(10,stepSeconds))
        }
        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator:"\r\n") + "\r\n"
    }

    static func twoSiteListingCSV(satellite: SatelliteRecord, first: ObserverSite, second: ObserverSite, hours: Double = 3, stepSeconds: TimeInterval = 60, start: Date = .now) throws -> String {
        let h1 = first.name.isEmpty ? "obs1" : first.name, h2 = second.name.isEmpty ? "obs2" : second.name
        var rows = [["satellite","time_utc","\(h1)_az","\(h1)_el","\(h1)_range_km","\(h2)_az","\(h2)_el","\(h2)_range_km","sub_lat","sub_lon","alt_km"]]
        var t=start; let end=start.addingTimeInterval(max(0.1,hours)*3600)
        while t <= end {
            let a=try OrbitPredictor.look(satellite,observer:first,at:t), b=try OrbitPredictor.look(satellite,observer:second,at:t)
            rows.append([satellite.name,human(t),String(format:"%.1f",a.azimuth),String(format:"%.1f",a.elevation),String(format:"%.0f",a.rangeKm),String(format:"%.1f",b.azimuth),String(format:"%.1f",b.elevation),String(format:"%.0f",b.rangeKm),String(format:"%.2f",a.subLatitude),String(format:"%.2f",a.subLongitude),String(format:"%.0f",a.altitudeKm)])
            t=t.addingTimeInterval(max(10,stepSeconds))
        }
        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator:"\r\n") + "\r\n"
    }

    static func passesJSON(_ passes: [PredictedPass], satellite: SatelliteRecord, observer: ObserverSite, minElevation: Double) throws -> Data {
        let object: [String: Any] = [
            "satellite": satellite.name,
            "norad": satellite.id,
            "station": [
                "name": observer.name,
                "latitude": observer.latitude,
                "longitude": observer.longitude,
                "altitude_m": observer.altitudeMeters
            ],
            "minimum_elevation_deg": minElevation,
            "passes": passes.map { pass in
                [
                    "aos_utc": iso(pass.aos),
                    "los_utc": iso(pass.los),
                    "tca_utc": iso(pass.tca),
                    "max_el_deg": pass.maxElevation,
                    "duration_s": pass.duration,
                    "aos_az_deg": pass.aosAzimuth,
                    "los_az_deg": pass.losAzimuth
                ] as [String: Any]
            }
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func passesICS(_ passes: [PredictedPass], satellite: SatelliteRecord, observer: ObserverSite, leadMinutes: Int = 10) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//OrbitDeck iOS//Pass Schedule//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH"
        ]
        for (index, pass) in passes.enumerated() {
            let summary = "\(satellite.name) pass (max el \(String(format: "%.0f", pass.maxElevation)) deg)"
            let description = "Max elevation \(String(format: "%.1f", pass.maxElevation)) deg at \(iso(pass.tca)). AOS az \(String(format: "%.0f", pass.aosAzimuth)), LOS az \(String(format: "%.0f", pass.losAzimuth)). Station: \(observer.name)."
            lines += [
                "BEGIN:VEVENT",
                "UID:\(satellite.id)-\(index)-\(icsDate(pass.aos))@orbitdeck-ios",
                "DTSTAMP:\(icsDate(Date()))",
                "DTSTART:\(icsDate(pass.aos))",
                "DTEND:\(icsDate(pass.los))",
                "SUMMARY:\(icsEscape(summary))",
                "DESCRIPTION:\(icsEscape(description))"
            ]
            if leadMinutes > 0 {
                lines += [
                    "BEGIN:VALARM",
                    "TRIGGER:-PT\(leadMinutes)M",
                    "ACTION:DISPLAY",
                    "DESCRIPTION:\(icsEscape(summary))",
                    "END:VALARM"
                ]
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func passReportPDF(_ passes: [PredictedPass], satellite: SatelliteRecord, observer: ObserverSite, minElevation: Double) -> Data {
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            let margin: CGFloat = 42
            let titleFont = UIFont.boldSystemFont(ofSize: 19)
            let headFont = UIFont.boldSystemFont(ofSize: 10)
            let bodyFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            let muted = UIColor.secondaryLabel
            var y: CGFloat = margin

            func beginPageIfNeeded(_ needed: CGFloat) {
                if y + needed > page.height - margin {
                    context.beginPage()
                    y = margin
                }
            }
            func draw(_ text: String, x: CGFloat, width: CGFloat, font: UIFont, color: UIColor = .label) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let rect = CGRect(x: x, y: y, width: width, height: 24)
                (text as NSString).draw(in: rect, withAttributes: attrs)
            }

            context.beginPage()
            draw("OrbitDeck Pass Schedule", x: margin, width: 500, font: titleFont)
            y += 28
            draw("\(satellite.name) — NORAD \(satellite.id)", x: margin, width: 500, font: UIFont.boldSystemFont(ofSize: 13))
            y += 19
            draw("Station: \(observer.name)  \(String(format: "%.4f", observer.latitude)), \(String(format: "%.4f", observer.longitude))   minimum elevation \(String(format: "%.0f", minElevation))°", x: margin, width: 520, font: UIFont.systemFont(ofSize: 9), color: muted)
            y += 26

            let columns: [(String, CGFloat)] = [("AOS UTC", 145), ("LOS UTC", 145), ("Max El", 55), ("AOS Az", 55), ("LOS Az", 55)]
            var x = margin
            for (label, width) in columns {
                draw(label, x: x, width: width, font: headFont)
                x += width
            }
            y += 17

            for pass in passes {
                beginPageIfNeeded(20)
                let values = [human(pass.aos), human(pass.los), String(format: "%.1f°", pass.maxElevation), String(format: "%.0f°", pass.aosAzimuth), String(format: "%.0f°", pass.losAzimuth)]
                x = margin
                for (index, value) in values.enumerated() {
                    draw(value, x: x, width: columns[index].1, font: bodyFont)
                    x += columns[index].1
                }
                y += 16
            }
        }
#else
        return Data(("OrbitDeck pass report\n\(satellite.name)\n" + passesCSV(passes, satellite: satellite, observer: observer)).utf8)
#endif
    }


    static func illuminationRaster(
        satellite: SatelliteRecord,
        days: Int = 60,
        rowsPerOrbit: Int = 96,
        start: Date = .now
    ) throws -> IlluminationRasterSnapshot {
        let safeDays = max(1, min(days, 366))
        let safeRows = max(8, min(rowsPerOrbit, 360))
        let periodSeconds = max(60, satellite.periodMinutes * 60)
        var cells = Array(repeating: false, count: safeDays * safeRows)
        var dayFractions = Array(repeating: 0.0, count: safeDays)
        var totalLit = 0
        for day in 0..<safeDays {
            let dayStart = start.addingTimeInterval(Double(day) * 86400)
            var lit = 0
            for row in 0..<safeRows {
                let t = dayStart.addingTimeInterval(Double(row) / Double(safeRows) * periodSeconds)
                let state = try OrbitPredictor.sunlit(satellite, at: t)
                cells[day * safeRows + row] = state
                if state { lit += 1; totalLit += 1 }
            }
            dayFractions[day] = Double(lit) / Double(safeRows)
        }
        return IlluminationRasterSnapshot(
            days: safeDays,
            rowsPerOrbit: safeRows,
            periodMinutes: satellite.periodMinutes,
            cells: cells,
            daySunlitFractions: dayFractions,
            meanSunlitFraction: Double(totalLit) / Double(safeDays * safeRows)
        )
    }

    static func progressionPasses(
        satellite: SatelliteRecord,
        observer: ObserverSite,
        minElevation: Double,
        days: Int = 30,
        start: Date = .now
    ) throws -> [PredictedPass] {
        let safeDays = max(1, min(days, 90))
        return try OrbitPredictor.predictPasses(
            satellite,
            observer: observer,
            from: start,
            minElevation: minElevation,
            maxCount: 4000,
            horizonDays: Double(safeDays)
        )
    }

    static func illuminationReportPDF(
        satellite: SatelliteRecord,
        days: Int = 60,
        generatedAt: Date = .now
    ) throws -> Data {
        let raster = try illuminationRaster(satellite: satellite, days: days, rowsPerOrbit: 96, start: generatedAt)
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            drawIlluminationPage(context: context, page: page, satellite: satellite, raster: raster, generatedAt: generatedAt)
        }
#else
        let eclipse = (1 - raster.meanSunlitFraction) * 100
        return Data("OrbitDeck illumination report\nSatellite: \(satellite.name)\nDays: \(raster.days)\nSamples/orbit: \(raster.rowsPerOrbit)\nMean sunlit: \(String(format: "%.1f", raster.meanSunlitFraction * 100))%\nMean eclipse: \(String(format: "%.1f", eclipse))%\n".utf8)
#endif
    }

    static func progressionReportPDF(
        satellite: SatelliteRecord,
        observer: ObserverSite,
        minElevation: Double,
        days: Int = 30,
        generatedAt: Date = .now
    ) throws -> Data {
        let safeDays = max(1, min(days, 90))
        let passes = try progressionPasses(satellite: satellite, observer: observer, minElevation: minElevation, days: safeDays, start: generatedAt)
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            drawProgressionPages(context: context, page: page, satellite: satellite, observer: observer, minElevation: minElevation, days: safeDays, passes: passes, generatedAt: generatedAt, includeTable: true)
        }
#else
        return Data(("OrbitDeck pass progression\n\(satellite.name)\n" + passesCSV(passes, satellite: satellite, observer: observer)).utf8)
#endif
    }

    static func mutualWindowsReportPDF(
        satellite: SatelliteRecord,
        home: ObserverSite,
        dx: ObserverSite,
        minimumElevation: Double = 0,
        days: Double = 10,
        generatedAt: Date = .now
    ) throws -> Data {
        let windows = try FeatureEngine.mutualWindows(
            satellite, home: home, dx: dx, from: generatedAt,
            days: max(0.1, min(days, 30)), minimumElevation: minimumElevation,
            step: 30, maxCount: 60
        )
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            let margin: CGFloat = 42
            let usable = page.width - margin * 2
            context.beginPage()
            ("\(satellite.name) — mutual windows" as NSString).draw(in: CGRect(x: margin, y: 42, width: usable, height: 28), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.label])
            ("\(home.name) (\(String(format: "%.3f", home.latitude)), \(String(format: "%.3f", home.longitude))) ↔ \(dx.name) (\(String(format: "%.3f", dx.latitude)), \(String(format: "%.3f", dx.longitude))) · minimum elevation \(String(format: "%.0f", minimumElevation))° · \(String(format: "%.0f", days)) day(s)" as NSString).draw(in: CGRect(x: margin, y: 74, width: usable, height: 34), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.secondaryLabel])
            var y: CGFloat = 120
            let widths: [CGFloat] = [80, 72, 72, 65, 75, 75]
            let headers = ["Day", "Start", "End", "Dur", "Home max", "DX max"]
            var x = margin
            for (h, w) in zip(headers, widths) {
                (h as NSString).draw(in: CGRect(x: x, y: y, width: w, height: 16), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 8.5), .foregroundColor: UIColor.label])
                x += w
            }
            y += 19
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0); df.dateFormat = "EEE MM-dd"
            let tf = DateFormatter(); tf.locale = df.locale; tf.timeZone = df.timeZone; tf.dateFormat = "HH:mm:ss"
            for window in windows.prefix(35) {
                if y > 730 { break }
                let values = [df.string(from: window.start), tf.string(from: window.start), tf.string(from: window.end), durationHMS(window.duration), String(format: "%.0f°", window.myMaxElevation), String(format: "%.0f°", window.dxMaxElevation)]
                x = margin
                for (v, w) in zip(values, widths) {
                    (v as NSString).draw(in: CGRect(x: x, y: y, width: w, height: 15), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 8.0, weight: .regular), .foregroundColor: UIColor.label])
                    x += w
                }
                y += 15
            }
            if windows.isEmpty {
                ("No simultaneous visibility windows were found." as NSString).draw(in: CGRect(x: margin, y: y + 10, width: usable, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.secondaryLabel])
            }
            ("OrbitDeck · mutual-window report · paired sky plots follow for up to 12 windows" as NSString).draw(in: CGRect(x: margin, y: 764, width: usable, height: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 6.8), .foregroundColor: UIColor.secondaryLabel])

            for (index, window) in windows.prefix(12).enumerated() {
                context.beginPage()
                ("\(satellite.name) — mutual window #\(index + 1)" as NSString).draw(in: CGRect(x: margin, y: 38, width: usable, height: 26), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 17), .foregroundColor: UIColor.label])
                ("\(human(window.start)) UTC → \(human(window.end)) UTC · \(durationHMS(window.duration)) · home max \(String(format: "%.0f°", window.myMaxElevation)) · DX max \(String(format: "%.0f°", window.dxMaxElevation))" as NSString).draw(in: CGRect(x: margin, y: 68, width: usable, height: 22), withAttributes: [.font: UIFont.systemFont(ofSize: 8.7), .foregroundColor: UIColor.secondaryLabel])
                let homeTrack = (try? DXDopplerEngine.skyTrack(satellite: satellite, observer: home, window: window)) ?? []
                let dxTrack = (try? DXDopplerEngine.skyTrack(satellite: satellite, observer: dx, window: window)) ?? []
                drawSkyPlot(context.cgContext, rect: CGRect(x: 36, y: 150, width: 255, height: 255), title: home.name, points: homeTrack)
                drawSkyPlot(context.cgContext, rect: CGRect(x: 321, y: 150, width: 255, height: 255), title: dx.name, points: dxTrack)
                ("Green = window start · orange = window end · center = zenith" as NSString).draw(in: CGRect(x: margin, y: 430, width: usable, height: 18), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.secondaryLabel])
            }
        }
#else
        var rows = [["start_utc","end_utc","duration","home_max_el","dx_max_el"]]
        rows += windows.map { [human($0.start), human($0.end), durationHMS($0.duration), String(format: "%.1f", $0.myMaxElevation), String(format: "%.1f", $0.dxMaxElevation)] }
        return Data(("OrbitDeck mutual-window report\n\(satellite.name)\n" + csv(rows)).utf8)
#endif
    }

    static func activationOperatingCSV(
        detail: ActivationDetailResult,
        home: ObserverSite,
        window: MutualWindowRecord,
        transponder: TransponderRecord,
        rows: [DXDopplerRow],
        mode: DXDopplerMode,
        anchor: DXDopplerAnchor,
        offsetHz: Int64
    ) -> String {
        var output = [["activation_callsign","satellite","norad","home","dx","window_start_utc","window_end_utc","mode","anchor","offset_hz","transponder","time_utc","my_rx_hz","my_tx_hz","dx_rx_hz","dx_tx_hz"]]
        let tpName = transponder.description.isEmpty ? transponder.kind : transponder.description
        for row in rows {
            output.append([
                detail.activation.callsign, detail.satellite.name, String(detail.satellite.id), home.name,
                detail.dxSite.name, iso(window.start), iso(window.end), mode.rawValue, anchor.rawValue,
                String(offsetHz), tpName, iso(row.date), String(row.myRX), String(row.myTX), String(row.dxRX), String(row.dxTX)
            ])
        }
        return csv(output)
    }

    static func activationOperatingPDF(
        detail: ActivationDetailResult,
        home: ObserverSite,
        window: MutualWindowRecord,
        transponder: TransponderRecord,
        rows: [DXDopplerRow],
        mode: DXDopplerMode,
        anchor: DXDopplerAnchor,
        offsetHz: Int64
    ) -> Data {
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 792, height: 612)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            let margin: CGFloat = 34
            let usable = page.width - margin * 2
            let tpName = transponder.description.isEmpty ? transponder.kind : transponder.description
            context.beginPage()
            ("Activation operating detail — \(detail.activation.callsign) on \(detail.satellite.name)" as NSString).draw(in: CGRect(x: margin, y: 28, width: usable, height: 26), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.label])
            ("\(detail.activation.grid) · advertised \(detail.activation.frequency.isEmpty ? "frequency not listed" : detail.activation.frequency) · \(human(window.start))–\(human(window.end)) UTC · \(mode.label) · anchor \(anchor.label) · offset \(offsetHz) Hz" as NSString).draw(in: CGRect(x: margin, y: 58, width: usable, height: 32), withAttributes: [.font: UIFont.systemFont(ofSize: 8.7), .foregroundColor: UIColor.secondaryLabel])
            ("Transponder: \(tpName)" as NSString).draw(in: CGRect(x: margin, y: 92, width: usable, height: 18), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 9.5), .foregroundColor: UIColor.label])
            var y: CGFloat = 122
            let widths: [CGFloat] = [100, 135, 135, 135, 135]
            let heads = ["UTC", "My RX MHz", "My TX MHz", "DX RX MHz", "DX TX MHz"]
            var x = margin
            for (h, w) in zip(heads, widths) { (h as NSString).draw(in: CGRect(x: x, y: y, width: w, height: 16), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 8.5), .foregroundColor: UIColor.label]); x += w }
            y += 18
            let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.timeZone = TimeZone(secondsFromGMT: 0); tf.dateFormat = "HH:mm:ss"
            for row in rows {
                if y > 570 {
                    context.beginPage(); y = 42
                    ("\(detail.activation.callsign) / \(detail.satellite.name) — DX Doppler (continued)" as NSString).draw(in: CGRect(x: margin, y: 20, width: usable, height: 18), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.label])
                }
                let vals = [tf.string(from: row.date), mhz(row.myRX), mhz(row.myTX), mhz(row.dxRX), mhz(row.dxTX)]
                x = margin
                for (v, w) in zip(vals, widths) { (v as NSString).draw(in: CGRect(x: x, y: y, width: w, height: 14), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 8.1, weight: .regular), .foregroundColor: UIColor.label]); x += w }
                y += 14
            }
        }
#else
        return Data(activationOperatingCSV(detail: detail, home: home, window: window, transponder: transponder, rows: rows, mode: mode, anchor: anchor, offsetHz: offsetHz).utf8)
#endif
    }

    static func satelliteReportPDF(
        satellite: SatelliteRecord,
        observer: ObserverSite,
        minElevation: Double,
        days: Int = 7,
        generatedAt: Date = .now
    ) throws -> Data {
        let horizonDays = max(1, min(days, 30))
        let passes = try OrbitPredictor.predictPasses(
            satellite,
            observer: observer,
            from: generatedAt,
            minElevation: minElevation,
            maxCount: 200,
            horizonDays: Double(horizonDays)
        )
        let ascending = observer.latitude >= 0
        let crossings: [(Date, Double)]
        if satellite.periodMinutes > 600 {
            crossings = []
        } else {
            crossings = try OrbitPredictor.equatorCrossings(
                satellite,
                from: generatedAt,
                to: generatedAt.addingTimeInterval(Double(horizonDays) * 86400),
                ascending: ascending
            )
        }
        let currentLook = try? OrbitPredictor.look(satellite, observer: observer, at: generatedAt)
        let rates = LearnMath.j2Rates(
            meanMotionRevDay: satellite.meanMotionRevPerDay,
            inclinationDeg: satellite.inclinationDeg,
            eccentricity: satellite.eccentricity
        )
        let meanAltitude = satellite.semiMajorAxisKm - LearnMath.earthRadiusKm
        let footprintRadiusKm = OrbitPredictor.footprintRadius(altitudeKm: max(1, meanAltitude))
        let decay = LearnMath.decayEstimate(
            meanMotion: satellite.meanMotionRevPerDay,
            eccentricity: satellite.eccentricity,
            bstar: satellite.bstar
        )
        let sunSync = abs(rates.nodeDegDay - 0.9856) < 0.12

#if canImport(UIKit)
        // Desktop's combined satellite report always carries these two graphic
        // sections in addition to analysis/passes/EQX/polar pages. Compute them
        // once before entering the PDF renderer so drawing stays deterministic.
        let illumination = try illuminationRaster(satellite: satellite, days: 60, rowsPerOrbit: 96, start: generatedAt)
        let progression = try progressionPasses(satellite: satellite, observer: observer, minElevation: minElevation, days: 30, start: generatedAt)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            let margin: CGFloat = 42
            let usable = page.width - margin * 2
            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let sectionFont = UIFont.boldSystemFont(ofSize: 13)
            let keyFont = UIFont.systemFont(ofSize: 9.2)
            let valFont = UIFont.monospacedSystemFont(ofSize: 9.2, weight: .semibold)
            let tableFont = UIFont.monospacedSystemFont(ofSize: 8.1, weight: .regular)
            let tableHead = UIFont.boldSystemFont(ofSize: 8.3)
            let muted = UIColor.secondaryLabel
            var y: CGFloat = 42

            func beginPage(_ continuation: Bool = false) {
                context.beginPage()
                y = 42
                let header = continuation ? "\(satellite.name) — satellite report (continued)" : "OrbitDeck Satellite Report"
                (header as NSString).draw(in: CGRect(x: margin, y: y, width: usable, height: 28), withAttributes: [.font: continuation ? UIFont.boldSystemFont(ofSize: 12) : titleFont, .foregroundColor: UIColor.label])
                y += continuation ? 28 : 34
                if !continuation {
                    ("\(satellite.name) — NORAD \(satellite.id)" as NSString).draw(in: CGRect(x: margin, y: y, width: usable, height: 22), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.label])
                    y += 20
                    ("Station \(observer.name) · \(String(format: "%.4f", observer.latitude)), \(String(format: "%.4f", observer.longitude)) · generated \(human(generatedAt)) UTC" as NSString).draw(in: CGRect(x: margin, y: y, width: usable, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 8.8), .foregroundColor: muted])
                    y += 30
                }
            }
            func ensure(_ height: CGFloat) {
                if y + height > page.height - 42 { beginPage(true) }
            }
            func section(_ text: String) {
                ensure(35)
                y += 7
                (text as NSString).draw(in: CGRect(x: margin, y: y, width: usable, height: 20), withAttributes: [.font: sectionFont, .foregroundColor: UIColor.label])
                y += 22
                UIColor.separator.setStroke()
                let line = UIBezierPath(); line.move(to: CGPoint(x: margin, y: y)); line.addLine(to: CGPoint(x: page.width-margin, y: y)); line.lineWidth = 0.6; line.stroke()
                y += 9
            }
            func kv(_ pairs: [(String, String)]) {
                let colW = usable / 2
                var i = 0
                while i < pairs.count {
                    ensure(20)
                    for c in 0..<2 where i + c < pairs.count {
                        let x = margin + CGFloat(c) * colW
                        let pair = pairs[i+c]
                        (pair.0 as NSString).draw(in: CGRect(x: x, y: y, width: colW * 0.46, height: 17), withAttributes: [.font: keyFont, .foregroundColor: muted])
                        (pair.1 as NSString).draw(in: CGRect(x: x + colW * 0.45, y: y, width: colW * 0.52, height: 17), withAttributes: [.font: valFont, .foregroundColor: UIColor.label])
                    }
                    y += 18
                    i += 2
                }
            }
            func footer() {
                ("OrbitDeck iOS · satellite report · planning/operating reference" as NSString).draw(in: CGRect(x: margin, y: 764, width: usable, height: 14), withAttributes: [.font: UIFont.systemFont(ofSize: 6.8), .foregroundColor: muted])
            }

            beginPage()
            section("Orbital analysis")
            var analysis: [(String, String)] = [
                ("Catalog #", String(satellite.id)),
                ("Int'l designator", satellite.internationalDesignator.isEmpty ? "—" : satellite.internationalDesignator),
                ("Inclination", String(format: "%.4f°", satellite.inclinationDeg)),
                ("Eccentricity", String(format: "%.7f", satellite.eccentricity)),
                ("Mean motion", String(format: "%.8f rev/day", satellite.meanMotionRevPerDay)),
                ("Period", String(format: "%.2f min", satellite.periodMinutes)),
                ("Semi-major axis", String(format: "%.1f km", satellite.semiMajorAxisKm)),
                ("Mean altitude", String(format: "%.1f km", meanAltitude)),
                ("Perigee", String(format: "%.1f km", satellite.perigeeKm)),
                ("Apogee", String(format: "%.1f km", satellite.apogeeKm)),
                ("RAAN", String(format: "%.4f°", satellite.raanDeg)),
                ("Arg. of perigee", String(format: "%.4f°", satellite.argumentOfPerigeeDeg)),
                ("Mean anomaly", String(format: "%.4f°", satellite.meanAnomalyDeg)),
                ("BSTAR", String(format: "%.6g", satellite.bstar)),
                ("Footprint diameter", String(format: "%.0f km", 2 * footprintRadiusKm)),
                ("Node regression", String(format: "%.4f°/day", rates.nodeDegDay)),
                ("Perigee precession", String(format: "%.4f°/day", rates.perigeeDegDay)),
                ("Sun-synchronous", sunSync ? "yes" : "no"),
                ("Element epoch", human(satellite.epoch) + " UTC"),
                ("Element age", String(format: "%.2f days", generatedAt.timeIntervalSince(satellite.epoch) / 86400))
            ]
            if decay.days.isFinite {
                analysis.append(("Est. orbital lifetime", decay.days >= 1e7 ? "effectively stable" : String(format: "%.0f days (%@)", decay.days, decay.source)))
            }
            kv(analysis)

            if let look = currentLook {
                section("Current propagated state")
                kv([
                    ("Azimuth / elevation", String(format: "%.1f° / %.1f°", look.azimuth, look.elevation)),
                    ("Range / range-rate", String(format: "%.0f km / %+.3f km/s", look.rangeKm, look.rangeRateKmS)),
                    ("Sub-point", String(format: "%.2f°, %.2f°", look.subLatitude, look.subLongitude)),
                    ("Altitude", String(format: "%.1f km", look.altitudeKm)),
                    ("Illumination", look.sunlit ? "sunlit" : "Earth shadow"),
                    ("Beta angle", String(format: "%.1f°", look.betaAngleDeg))
                ])
            }

            section("Next passes — minimum elevation \(String(format: "%.0f", minElevation))° · next \(horizonDays) day(s)")
            if passes.isEmpty {
                ("No passes above the configured minimum elevation in this window." as NSString).draw(in: CGRect(x: margin, y: y, width: usable, height: 20), withAttributes: [.font: keyFont, .foregroundColor: muted])
                y += 20
            } else {
                let widths: [CGFloat] = [72, 73, 45, 65, 45, 65, 45, 55]
                let headers = ["Date", "AOS", "Az", "TCA", "Max", "LOS", "Az", "Dur"]
                ensure(22)
                UIColor.secondarySystemBackground.setFill(); UIBezierPath(rect: CGRect(x: margin, y: y-2, width: usable, height: 18)).fill()
                var x = margin
                for (h,w) in zip(headers,widths) { (h as NSString).draw(in: CGRect(x:x+2,y:y,width:w-4,height:16),withAttributes:[.font:tableHead,.foregroundColor:UIColor.label]); x += w }
                y += 18
                let dateF = DateFormatter(); dateF.locale = Locale(identifier:"en_US_POSIX"); dateF.timeZone = TimeZone(secondsFromGMT:0); dateF.dateFormat="MM-dd"
                let timeF = DateFormatter(); timeF.locale = dateF.locale; timeF.timeZone = dateF.timeZone; timeF.dateFormat="HH:mm:ss"
                for pass in passes.prefix(40) {
                    ensure(17)
                    let vals = [dateF.string(from:pass.aos),timeF.string(from:pass.aos),String(format:"%.0f°",pass.aosAzimuth),timeF.string(from:pass.tca),String(format:"%.0f°",pass.maxElevation),timeF.string(from:pass.los),String(format:"%.0f°",pass.losAzimuth),String(format:"%.1fm",pass.duration/60)]
                    x=margin
                    for (v,w) in zip(vals,widths) { (v as NSString).draw(in:CGRect(x:x+2,y:y,width:w-4,height:15),withAttributes:[.font:tableFont,.foregroundColor:UIColor.label]); x += w }
                    y += 15
                }
            }

            section("Equator crossings — \(ascending ? "ascending" : "descending") node · next \(horizonDays) day(s)")
            if satellite.periodMinutes > 600 {
                ("Geosynchronous / high-altitude orbit: no useful OSCARLOCATOR daily equator-crossing schedule." as NSString).draw(in:CGRect(x:margin,y:y,width:usable,height:30),withAttributes:[.font:keyFont,.foregroundColor:muted]); y += 30
            } else if crossings.isEmpty {
                ("No equator crossings found in this window." as NSString).draw(in:CGRect(x:margin,y:y,width:usable,height:20),withAttributes:[.font:keyFont,.foregroundColor:muted]); y += 20
            } else {
                for (idx,node) in crossings.prefix(80).enumerated() {
                    ensure(16)
                    let hemi = node.1 >= 0 ? "E" : "W"
                    let text = String(format:"%3d   %@ UTC   %.1f° %@",idx+1,human(node.0),abs(node.1),hemi)
                    (text as NSString).draw(in:CGRect(x:margin,y:y,width:usable,height:15),withAttributes:[.font:tableFont,.foregroundColor:UIColor.label]); y += 14
                }
            }
            footer()

            // Desktop reports add pass-sky graphics. Include the first upcoming pass
            // as a full-page polar plot using the same predictor samples as Pass Detail.
            if let first = passes.first, let sky = try? OrbitPredictor.skyPath(satellite, observer: observer, pass: first, step: 12) {
                context.beginPage()
                ("\(satellite.name) — next-pass sky track" as NSString).draw(in:CGRect(x:margin,y:40,width:usable,height:28),withAttributes:[.font:UIFont.boldSystemFont(ofSize:18),.foregroundColor:UIColor.label])
                ("AOS \(human(first.aos)) UTC · max \(String(format:"%.0f°",first.maxElevation)) · LOS \(human(first.los)) UTC" as NSString).draw(in:CGRect(x:margin,y:72,width:usable,height:18),withAttributes:[.font:UIFont.systemFont(ofSize:9),.foregroundColor:muted])
                let c = CGPoint(x: page.midX, y: 405), r: CGFloat = 230
                let cg=context.cgContext
                cg.setStrokeColor(UIColor.lightGray.cgColor); cg.setLineWidth(0.7)
                for elevation in [0.0,30.0,60.0] {
                    let rr=r*CGFloat((90-elevation)/90)
                    cg.strokeEllipse(in:CGRect(x:c.x-rr,y:c.y-rr,width:2*rr,height:2*rr))
                }
                for az in stride(from:0.0,to:360.0,by:45.0) {
                    let t=CGFloat(az*Double.pi/180)
                    cg.move(to:c); cg.addLine(to:CGPoint(x:c.x+r*sin(t),y:c.y-r*cos(t))); cg.strokePath()
                }
                ("N" as NSString).draw(at:CGPoint(x:c.x-5,y:c.y-r-22),withAttributes:[.font:UIFont.boldSystemFont(ofSize:12)])
                ("E" as NSString).draw(at:CGPoint(x:c.x+r+8,y:c.y-6),withAttributes:[.font:UIFont.boldSystemFont(ofSize:12)])
                ("S" as NSString).draw(at:CGPoint(x:c.x-5,y:c.y+r+8),withAttributes:[.font:UIFont.boldSystemFont(ofSize:12)])
                ("W" as NSString).draw(at:CGPoint(x:c.x-r-20,y:c.y-6),withAttributes:[.font:UIFont.boldSystemFont(ofSize:12)])
                let path=UIBezierPath()
                for (i,p) in sky.enumerated() {
                    let rr=r*CGFloat((90-max(0,min(90,p.elevation)))/90)
                    let t=CGFloat(p.azimuth*Double.pi/180)
                    let pt=CGPoint(x:c.x+rr*sin(t),y:c.y-rr*cos(t))
                    i==0 ? path.move(to:pt) : path.addLine(to:pt)
                }
                UIColor.systemBlue.setStroke(); path.lineWidth=2.8; path.stroke()
                if let a=sky.first, let z=sky.last {
                    for (p,color) in [(a,UIColor.systemGreen),(z,UIColor.systemOrange)] {
                        let rr=r*CGFloat((90-max(0,min(90,p.elevation)))/90),t=CGFloat(p.azimuth*Double.pi/180)
                        color.setFill(); UIBezierPath(ovalIn:CGRect(x:c.x+rr*sin(t)-5,y:c.y-rr*cos(t)-5,width:10,height:10)).fill()
                    }
                }
                ("Green = AOS · orange = LOS · center = zenith" as NSString).draw(in:CGRect(x:margin,y:680,width:usable,height:20),withAttributes:[.font:UIFont.systemFont(ofSize:9),.foregroundColor:muted])
                footer()
            }

            // Desktop parity: 60-day illumination raster followed by the
            // 30-day pass-progression lanes. The combined report omits the
            // progression's duplicate detailed pass table, matching desktop.
            drawIlluminationPage(context: context, page: page, satellite: satellite, raster: illumination, generatedAt: generatedAt)
            drawProgressionPages(context: context, page: page, satellite: satellite, observer: observer, minElevation: minElevation, days: 30, passes: progression, generatedAt: generatedAt, includeTable: false)
        }
#else
        var lines = [
            "OrbitDeck Satellite Report",
            "\(satellite.name) — NORAD \(satellite.id)",
            "Station: \(observer.name)",
            "Generated: \(human(generatedAt)) UTC",
            "",
            "Orbital analysis",
            String(format:"Inclination: %.4f deg",satellite.inclinationDeg),
            String(format:"Eccentricity: %.7f",satellite.eccentricity),
            String(format:"Mean motion: %.8f rev/day",satellite.meanMotionRevPerDay),
            String(format:"Period: %.2f min",satellite.periodMinutes),
            String(format:"Semi-major axis: %.1f km",satellite.semiMajorAxisKm),
            String(format:"Perigee / apogee: %.1f / %.1f km",satellite.perigeeKm,satellite.apogeeKm),
            String(format:"RAAN / arg perigee / mean anomaly: %.4f / %.4f / %.4f deg",satellite.raanDeg,satellite.argumentOfPerigeeDeg,satellite.meanAnomalyDeg),
            String(format:"Node regression: %.4f deg/day",rates.nodeDegDay),
            "",
            "Next passes",
            passesCSV(passes,satellite:satellite,observer:observer),
            "Equator crossings"
        ]
        lines += crossings.map { "\(human($0.0)) UTC\t\(String(format:"%.2f",$0.1))" }
        return Data(lines.joined(separator:"\n").utf8)
#endif
    }

    static func favoritesPassSchedulePDF(
        satellites: [SatelliteRecord],
        observer: ObserverSite,
        minElevation: Double,
        days: Int = 7,
        generatedAt: Date = .now
    ) -> Data {
        let horizon = max(1,min(days,30))
        var events: [(Date, SatelliteRecord, PredictedPass)] = []
        for satellite in satellites {
            let passes = (try? OrbitPredictor.predictPasses(satellite, observer: observer, minElevation: minElevation, maxCount: 200, horizonDays: Double(horizon))) ?? []
            events += passes.map { ($0.aos,satellite,$0) }
        }
        events.sort { $0.0 < $1.0 }
        let rows = [["day","aos_utc","satellite","norad","aos_az","max_el","los_utc","duration_min"]] + events.map { _,sat,p in
            [human(p.aos),human(p.aos),sat.name,String(sat.id),String(format:"%.0f",p.aosAzimuth),String(format:"%.0f",p.maxElevation),human(p.los),String(format:"%.1f",p.duration/60)]
        }
        return planningReportPDF(
            title: "Favorite satellites — chronological pass schedule",
            subtitle: "Station \(observer.name) · next \(horizon) day(s) · minimum elevation \(String(format:"%.0f",minElevation))° · \(satellites.count) favorite(s) · \(events.count) pass(es)",
            csvText: csv(rows)
        )
    }

    static func siteComparisonPDF(
        satellite: SatelliteRecord,
        sites: [ObserverSite],
        minElevation: Double,
        days: Int = 3
    ) -> Data {
        let horizon=max(1,min(days,30))
        var rows=[["site","latitude","longitude","passes","next_aos_utc","next_max_el","best_max_el"]]
        for site in sites {
            let passes=(try? OrbitPredictor.predictPasses(satellite,observer:site,minElevation:minElevation,maxCount:200,horizonDays:Double(horizon))) ?? []
            let next=passes.first
            let best=passes.max(by:{$0.maxElevation<$1.maxElevation})
            rows.append([site.name,String(format:"%.4f",site.latitude),String(format:"%.4f",site.longitude),String(passes.count),next.map{human($0.aos)} ?? "—",next.map{String(format:"%.0f",$0.maxElevation)} ?? "—",best.map{String(format:"%.0f",$0.maxElevation)} ?? "—"])
        }
        return planningReportPDF(
            title: "\(satellite.name) — passes by site",
            subtitle: "Primary and saved stations · next \(horizon) day(s) · minimum elevation \(String(format:"%.0f",minElevation))°",
            csvText: csv(rows)
        )
    }

    // Defined here (top of the OSCARLOCATOR PDF support) so both the view and the
    // exporter share the same set of printable sheet choices.
    static func oscarLocatorPDF(satellite: SatelliteRecord, observer: ObserverSite, at date: Date = .now,
                                kind: OscarPDFKind = .fullSet, cleanTransparencies: Bool = false,
                                southHemisphere: Bool? = nil) -> Data {
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let center = CGPoint(x: page.midX, y: 365)
        let radius: CGFloat = 238
        let south = southHemisphere ?? (observer.latitude < 0)
        let siderealDay = 86164.0905

        func point(lat: Double, lon: Double) -> CGPoint? {
            let rho = south ? 90 + lat : 90 - lat
            guard rho >= 0, rho <= 90 else { return nil }
            let rr = radius * CGFloat(rho / 90)
            let theta = CGFloat(lon * .pi / 180)
            let sign: CGFloat = south ? -1 : 1
            return CGPoint(x: center.x + sign * rr * sin(theta), y: center.y + rr * cos(theta))
        }
        func wrappedLon(_ lon: Double) -> Double {
            var x = lon.truncatingRemainder(dividingBy: 360)
            if x > 180 { x -= 360 }
            if x < -180 { x += 360 }
            return x
        }
        func drawTitle(_ title: String, subtitle: String) {
            (title as NSString).draw(in: CGRect(x: 42, y: 30, width: 528, height: 30),
                                     withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.black])
            (subtitle as NSString).draw(in: CGRect(x: 42, y: 60, width: 528, height: 42),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.darkGray])
        }
        func drawFooter(_ text: String) {
            (text as NSString).draw(in: CGRect(x: 42, y: 704, width: 528, height: 48),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
            let credit = "OrbitDeck · Paul Stoetzer, N8HM · print at 100% (actual size)"
            let creditAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 6.5), .foregroundColor: UIColor(white: 0.6, alpha: 1)]
            let creditSize = (credit as NSString).size(withAttributes: creditAttrs)
            (credit as NSString).draw(at: CGPoint(x: center.x - creditSize.width/2, y: 762), withAttributes: creditAttrs)
        }
        func drawFrame(_ cg: CGContext, rings: Bool = true, spokes: Bool = true) {
            let sign: CGFloat = south ? -1 : 1
            cg.setStrokeColor(UIColor.black.cgColor); cg.setLineWidth(1.3)
            cg.strokeEllipse(in: CGRect(x: center.x-radius, y: center.y-radius, width: 2*radius, height: 2*radius))
            // 1°/5°/10° rim registration ticks, bold at the four cardinal longitudes,
            // so stacked transparencies align — matches desktop OSCARLOCATOR.
            for deg in 0..<360 {
                let theta = CGFloat(Double(deg) * .pi / 180)
                let ux = sign * sin(theta), uy = cos(theta)
                let rim = CGPoint(x: center.x + radius * ux, y: center.y + radius * uy)
                let cardinal = deg % 90 == 0
                let len: CGFloat = deg % 10 == 0 ? 7.6 : (deg % 5 == 0 ? 4.8 : 2.4)
                cg.setLineWidth(cardinal ? 2.2 : (deg % 10 == 0 ? 1.1 : (deg % 5 == 0 ? 0.8 : 0.5)))
                cg.setStrokeColor((cardinal ? UIColor.black : UIColor.darkGray).cgColor)
                cg.move(to: rim); cg.addLine(to: CGPoint(x: rim.x + len*ux, y: rim.y + len*uy)); cg.strokePath()
            }
            cg.setStrokeColor(UIColor.lightGray.cgColor); cg.setLineWidth(0.55)
            if rings {
                for rho in stride(from: 15.0, through: 75.0, by: 15.0) {
                    let rr = radius * CGFloat(rho/90)
                    cg.setStrokeColor(UIColor.lightGray.cgColor); cg.setLineWidth(0.55)
                    cg.strokeEllipse(in: CGRect(x:center.x-rr,y:center.y-rr,width:2*rr,height:2*rr))
                    // Latitude label for each ring, on the 30° spoke.
                    let lat = south ? rho - 90 : 90 - rho
                    let t = CGFloat(30.0 * .pi / 180)
                    let lp = CGPoint(x: center.x + sign*rr*sin(t), y: center.y + rr*cos(t))
                    ("\(Int(abs(lat)))°" as NSString).draw(at: CGPoint(x: lp.x-6, y: lp.y-4),
                        withAttributes:[.font:UIFont.boldSystemFont(ofSize:6.5),.foregroundColor:UIColor.gray])
                }
            }
            if spokes {
                for lon in stride(from: -180.0, to: 180.0, by: 30.0) {
                    let t = CGFloat(lon * .pi / 180)
                    cg.setStrokeColor(UIColor.lightGray.cgColor); cg.setLineWidth(0.55)
                    cg.move(to:center); cg.addLine(to:CGPoint(x:center.x+sign*radius*sin(t),y:center.y+radius*cos(t))); cg.strokePath()
                }
            }
            for lon in stride(from: -150, through: 180, by: 30) {
                let t = CGFloat(Double(lon) * .pi / 180)
                let p = CGPoint(x:center.x+sign*(radius+16)*sin(t), y:center.y+(radius+16)*cos(t))
                let txt = "\(abs(lon))°\(lon < 0 ? "W" : lon > 0 ? "E" : "")"
                (txt as NSString).draw(at: CGPoint(x:p.x-13,y:p.y-5),
                                       withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:6,weight:.regular),.foregroundColor:UIColor.darkGray])
            }
        }
        func strokeGeo(_ pts: [(Double, Double)], color: UIColor, width: CGFloat) {
            let path = UIBezierPath(); var open = false; var previous: CGPoint?
            for ll in pts {
                guard let p = point(lat: ll.0, lon: ll.1) else { open = false; previous = nil; continue }
                if let previous, hypot(p.x-previous.x, p.y-previous.y) > radius * 0.75 { open = false }
                if open { path.addLine(to: p) } else { path.move(to: p); open = true }
                previous = p
            }
            color.setStroke(); path.lineWidth = width; path.stroke()
        }

        func drawBaseMap(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage()
            let cg = context.cgContext
            drawTitle("\(satellite.name) — OSCARLOCATOR Base Map",
                      subtitle: "\(south ? "South" : "North") polar azimuthal-equidistant sheet · QTH \(observer.name)  \(String(format: "%.3f", observer.latitude))°, \(String(format: "%.3f", observer.longitude))°")
            drawFrame(cg)
            for coast in WorldMapData.coastlines {
                strokeGeo(coast.map { ($0.1, $0.0) }, color: .black, width: 0.75)
            }
            if let q = point(lat: observer.latitude, lon: observer.longitude) {
                UIColor.systemOrange.setFill(); cg.fillEllipse(in:CGRect(x:q.x-4,y:q.y-4,width:8,height:8))
                ("QTH" as NSString).draw(at: CGPoint(x:q.x+6,y:q.y-5), withAttributes:[.font:UIFont.boldSystemFont(ofSize:7),.foregroundColor:UIColor.systemOrange])
            }
            drawFooter("BASE MAP — Print on paper/card. Overlays are same-scale transparencies. Longitude spokes and latitude-distance rings use the same polar convention as the on-screen simulator.")
        }

        func drawRangeCircle(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage()
            let cg = context.cgContext
            let meanAltitude = max(0, satellite.semiMajorAxisKm - 6378.135)
            let footprintDeg = FeatureEngine.footprintRadiusDegrees(altitudeKm: meanAltitude)
            // Enlarge the drawn circle by the population-weighted polar-projection
            // correction (1.065) so a single generic circle best fits the polar
            // sheet's distortion for most stations. Matches desktop OSCARLOCATOR.
            let drawnDeg = min(90, max(0, footprintDeg * 1.065))
            let footprintR = radius * CGFloat(drawnDeg / 90)
            drawTitle("\(satellite.name) — OSCARLOCATOR Range Circle Overlay",
                      subtitle: String(format: "Mean altitude %.0f km · range-circle angular radius %.1f° (~%.0f km along Earth)", meanAltitude, footprintDeg, footprintDeg * .pi / 180 * 6378.135))
            drawFrame(cg, rings: false, spokes: false)
            cg.setStrokeColor(UIColor.systemGray2.cgColor); cg.setLineWidth(0.55)
            for az in stride(from: 0.0, to: 360.0, by: 15.0) {
                let t = CGFloat(az * .pi / 180), sign: CGFloat = south ? -1 : 1
                cg.move(to:center); cg.addLine(to:CGPoint(x:center.x+sign*footprintR*sin(t),y:center.y+footprintR*cos(t))); cg.strokePath()
            }
            cg.setStrokeColor(UIColor.systemRed.cgColor); cg.setLineWidth(3.0)
            cg.strokeEllipse(in:CGRect(x:center.x-footprintR,y:center.y-footprintR,width:2*footprintR,height:2*footprintR))
            cg.setStrokeColor(UIColor.black.cgColor); cg.setLineWidth(2.0)
            cg.move(to:CGPoint(x:center.x-8,y:center.y)); cg.addLine(to:CGPoint(x:center.x+8,y:center.y))
            cg.move(to:CGPoint(x:center.x,y:center.y-8)); cg.addLine(to:CGPoint(x:center.x,y:center.y+8)); cg.strokePath()
            if !cleanTransparencies {
                drawFooter("RANGE CIRCLE — Print on transparency at 100%. Pin the center cross over the map center. The satellite is geometrically in range while the path-arc overlay lies inside the red circle; AOS/LOS occur where the arc crosses it.")
            }
        }

        func drawPathArc(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage()
            let cg = context.cgContext
            let periodSeconds = max(1, satellite.periodMinutes * 60)
            let asc = !south
            let nodeSearchStart = date.addingTimeInterval(-periodSeconds)
            let nodeSearchEnd = date.addingTimeInterval(periodSeconds)
            let nodes = (try? OrbitPredictor.equatorCrossings(satellite, from: nodeSearchStart, to: nodeSearchEnd, ascending: asc, step: 120)) ?? []
            let node = nodes.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) }
            let nodeDate = node?.0 ?? date
            let nodeLon = node?.1 ?? 0
            let centered = nodeDate.addingTimeInterval(periodSeconds / 2)
            let rawTrack = (try? OrbitPredictor.groundTrack(satellite, centeredAt: centered, durationMinutes: satellite.periodMinutes, step: 30)) ?? []
            let canonical = rawTrack.map { ($0.1, wrappedLon($0.2 - nodeLon)) }
            let rates = LearnMath.j2Rates(meanMotionRevDay: satellite.meanMotionRevPerDay, inclinationDeg: satellite.inclinationDeg, eccentricity: satellite.eccentricity)
            let shift = -360 * periodSeconds / siderealDay + rates.nodeDegDay * periodSeconds / 86400
            drawTitle("\(satellite.name) — OSCARLOCATOR Path Arc Overlay",
                      subtitle: String(format: "Inclination %.1f° · period %.1f min · successive node shift %.1f° %@ per orbit", satellite.inclinationDeg, satellite.periodMinutes, abs(shift), shift < 0 ? "W" : "E"))
            drawFrame(cg, rings: true, spokes: false)
            strokeGeo(canonical, color: .systemBlue, width: 2.6)
            // Minute marks after the ascending node: a small perpendicular tick each
            // whole minute, a labelled dot every `labelStep` minutes. The label step
            // scales with the period (≤14 labels), matching desktop OSCARLOCATOR.
            var labelStep = 10
            for cand in [10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300] where satellite.periodMinutes / Double(cand) <= 14 { labelStep = cand; break }
            var lastMinute = Int.min
            let periodMinPA = max(1, periodSeconds / 60)
            for i in canonical.indices where i < rawTrack.count {
                // Minutes since the node, wrapped to [0, period) so the whole
                // visible arc (including across the equator) is tick-marked.
                let rawMin = rawTrack[i].0.timeIntervalSince(nodeDate) / 60.0
                let minutes = (rawMin.truncatingRemainder(dividingBy: periodMinPA) + periodMinPA).truncatingRemainder(dividingBy: periodMinPA)
                let minute = Int(minutes.rounded())
                guard minute != lastMinute, abs(minutes - Double(minute)) <= 0.26 else { continue }
                lastMinute = minute
                guard let p = point(lat: canonical[i].0, lon: canonical[i].1) else { continue }
                let j = i + 1 < canonical.count ? i + 1 : max(0, i - 1)
                guard let q = point(lat: canonical[j].0, lon: canonical[j].1) else { continue }
                var dx = q.x - p.x, dy = q.y - p.y
                let len = hypot(dx, dy)
                guard len > 0.001 else { continue }
                dx /= len; dy /= len
                let nx = -dy, ny = dx
                if minute % labelStep == 0 {
                    UIColor.systemBlue.setFill(); cg.fillEllipse(in: CGRect(x: p.x-2.2, y: p.y-2.2, width: 4.4, height: 4.4))
                    if minute != 0 {
                        ("\(minute)" as NSString).draw(at: CGPoint(x: p.x + nx*6 - 3, y: p.y + ny*6 - 3),
                            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 6), .foregroundColor: UIColor.systemBlue])
                    }
                } else {
                    let tick = UIBezierPath()
                    tick.move(to: CGPoint(x: p.x - nx*3, y: p.y - ny*3))
                    tick.addLine(to: CGPoint(x: p.x + nx*3, y: p.y + ny*3))
                    UIColor.systemBlue.setStroke(); tick.lineWidth = 0.6; tick.stroke()
                }
            }
            // EQX (minute 0) alignment marker: a red arrowed radial line from the
            // centre out through the node to the rim, matching desktop OSCARLOCATOR.
            let eqSign: CGFloat = south ? -1 : 1
            let eqTip = CGPoint(x: center.x, y: center.y + eqSign * radius)   // node at sheet-lon 0
            cg.setStrokeColor(UIColor.systemRed.cgColor); cg.setLineWidth(2.4)
            cg.move(to: center); cg.addLine(to: eqTip); cg.strokePath()
            let ah: CGFloat = 7
            let arrow = UIBezierPath()
            arrow.move(to: eqTip)
            arrow.addLine(to: CGPoint(x: eqTip.x - ah*0.6, y: eqTip.y - eqSign*ah))
            arrow.addLine(to: CGPoint(x: eqTip.x + ah*0.6, y: eqTip.y - eqSign*ah))
            arrow.close(); UIColor.systemRed.setFill(); arrow.fill()
            (south ? "EQX · 0 min (descending node)" : "EQX · 0 min (ascending node)" as NSString)
                .draw(at: CGPoint(x: eqTip.x + 6, y: eqTip.y - eqSign*14),
                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 7), .foregroundColor: UIColor.systemRed])

            // Per-pass rotation indicator: which way and how far to turn the overlay
            // between successive passes (node drift = Earth rotation + J2 regression).
            let west = shift < 0
            let ccw = south ? west : !west
            let sense = ccw ? "counter-clockwise" : "clockwise"
            let geo = west ? "west" : "east"
            if !cleanTransparencies {
                let rotText = String(format: "Rotate sheet %.1f° %@ (node moves %@) each pass", abs(shift), sense, geo)
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.systemRed]
                let sz = (rotText as NSString).size(withAttributes: attrs)
                (rotText as NSString).draw(at: CGPoint(x: center.x - sz.width/2, y: center.y - radius - 22), withAttributes: attrs)
                // A short curved arrow above the top rim indicating the sense.
                let arcR = radius + 12
                let a0 = CGFloat(-0.18) - .pi/2, a1 = CGFloat(0.18) - .pi/2
                cg.setStrokeColor(UIColor.systemRed.cgColor); cg.setLineWidth(2.0)
                cg.addArc(center: center, radius: arcR, startAngle: a0, endAngle: a1, clockwise: false); cg.strokePath()
                let headAngle = ccw ? a0 : a1
                let hx = center.x + arcR*cos(headAngle), hy = center.y + arcR*sin(headAngle)
                let head = UIBezierPath()
                head.move(to: CGPoint(x: hx, y: hy))
                head.addLine(to: CGPoint(x: hx + (ccw ? 5 : -5), y: hy - 4))
                head.addLine(to: CGPoint(x: hx + (ccw ? 2 : -2), y: hy + 5))
                head.close(); UIColor.systemRed.setFill(); head.fill()
            }
            if !cleanTransparencies {
                drawFooter(String(format: "PATH ARC — Print on transparency at 100%%. Lay over the base map with centres aligned and the EQX arrow at the node longitude from Reference Orbits, then rotate the sheet %.1f° %@ about the centre for each successive pass. Ticks count minutes after the EQX; labelled marks every %d min.", abs(shift), sense, labelStep))
            }
        }

        // ---- QTH-centered azimuthal-equidistant sheets ----
        let d2r = Double.pi / 180
        let qthReach = max(50.0, min(80.0, abs(observer.latitude) + 25.0))
        let kmPerDeg = Double.pi / 180 * 6378.135
        func centralAngleBearing(_ qlat: Double, _ qlon: Double, _ lat: Double, _ lon: Double) -> (Double, Double) {
            let p1 = qlat*d2r, p2 = lat*d2r, dl = (lon - qlon)*d2r
            let ca = acos(max(-1, min(1, sin(p1)*sin(p2) + cos(p1)*cos(p2)*cos(dl))))
            let y = sin(dl)*cos(p2), x = cos(p1)*sin(p2) - sin(p1)*cos(p2)*cos(dl)
            let br = (atan2(y, x)/d2r + 360).truncatingRemainder(dividingBy: 360)
            return (ca/d2r, br)
        }
        func qpoint(_ qlat: Double, _ qlon: Double, _ lat: Double, _ lon: Double) -> CGPoint? {
            let (rho, br) = centralAngleBearing(qlat, qlon, lat, lon)
            guard rho <= qthReach else { return nil }
            let r = radius * CGFloat(rho / qthReach), b = CGFloat(br * d2r)
            return CGPoint(x: center.x + r * sin(b), y: center.y - r * cos(b))
        }
        func qStrokeGeo(_ pts: [(Double, Double)], qlat: Double, qlon: Double, color: UIColor, width: CGFloat) {
            let path = UIBezierPath(); var open = false; var prev: CGPoint?
            for ll in pts {
                guard let p = qpoint(qlat, qlon, ll.0, ll.1) else { open = false; prev = nil; continue }
                if let prev, hypot(p.x-prev.x, p.y-prev.y) > radius*0.75 { open = false }
                if open { path.addLine(to: p) } else { path.move(to: p); open = true }
                prev = p
            }
            color.setStroke(); path.lineWidth = width; path.stroke()
        }
        func elevRingDeg(_ elDeg: Double, _ altKm: Double) -> Double {
            let re = 6378.135, r = re + max(1, altKm), e = elDeg*d2r
            return (acos(max(-1, min(1, re/r*cos(e)))) - e)/d2r
        }
        func drawQTHFrame(_ cg: CGContext, altKm: Double, elevationRings: Bool, kmRings: Bool) {
            cg.setStrokeColor(UIColor.black.cgColor); cg.setLineWidth(1.3)
            cg.strokeEllipse(in: CGRect(x:center.x-radius, y:center.y-radius, width:2*radius, height:2*radius))
            for deg in 0..<360 {   // rim ticks by azimuth
                let b = CGFloat(Double(deg)*d2r), ux = sin(b), uy = -cos(b)
                let rim = CGPoint(x: center.x+radius*ux, y: center.y+radius*uy)
                let cardinal = deg % 90 == 0
                let len: CGFloat = deg % 10 == 0 ? 7.6 : (deg % 5 == 0 ? 4.8 : 2.4)
                cg.setLineWidth(cardinal ? 2.2 : (deg % 10 == 0 ? 1.1 : (deg % 5 == 0 ? 0.8 : 0.5)))
                cg.setStrokeColor((cardinal ? UIColor.black : UIColor.darkGray).cgColor)
                cg.move(to: rim); cg.addLine(to: CGPoint(x: rim.x+len*ux, y: rim.y+len*uy)); cg.strokePath()
            }
            cg.setStrokeColor(UIColor.lightGray.cgColor); cg.setLineWidth(0.55)
            for az in stride(from: 0.0, to: 360.0, by: 30.0) {
                let b = CGFloat(az*d2r)
                cg.move(to: center); cg.addLine(to: CGPoint(x: center.x+radius*sin(b), y: center.y-radius*cos(b))); cg.strokePath()
            }
            for az in stride(from: 0, through: 330, by: 30) {
                let b = Double(az)*d2r
                let p = CGPoint(x: center.x+(radius+14)*CGFloat(sin(b)), y: center.y-(radius+14)*CGFloat(cos(b)))
                let card = ["0":"N","90":"E","180":"S","270":"W"]["\(az)"]
                let font = card != nil ? UIFont.boldSystemFont(ofSize: 11) : UIFont.systemFont(ofSize: 8)
                ((card ?? "\(az)°") as NSString).draw(at: CGPoint(x:p.x-6, y:p.y-6), withAttributes:[.font:font,.foregroundColor:UIColor.darkGray])
            }
            if kmRings {
                var km = 1000.0
                while km/kmPerDeg <= qthReach {
                    let rr = radius*CGFloat((km/kmPerDeg)/qthReach)
                    cg.setStrokeColor(UIColor(white:0.82,alpha:1).cgColor); cg.setLineWidth(0.5)
                    cg.strokeEllipse(in: CGRect(x:center.x-rr,y:center.y-rr,width:2*rr,height:2*rr))
                    ("\(Int(km)) km" as NSString).draw(at: CGPoint(x:center.x+rr*0.7,y:center.y+rr*0.7),
                        withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:6,weight:.regular),.foregroundColor:UIColor.gray])
                    km += 1000
                }
            }
            if elevationRings {
                for el in [0.0, 10.0, 30.0, 60.0] {
                    let rho = elevRingDeg(el, altKm)
                    guard rho > 0, rho <= qthReach else { continue }
                    let rr = radius*CGFloat(rho/qthReach)
                    cg.setStrokeColor((el == 0 ? UIColor.darkGray : UIColor(white:0.6,alpha:1)).cgColor); cg.setLineWidth(el == 0 ? 1.2 : 0.7)
                    cg.strokeEllipse(in: CGRect(x:center.x-rr,y:center.y-rr,width:2*rr,height:2*rr))
                    ("\(Int(el))° el" as NSString).draw(at: CGPoint(x:center.x-9,y:center.y-rr-9),
                        withAttributes:[.font:UIFont.boldSystemFont(ofSize:6.5),.foregroundColor:UIColor.darkGray])
                }
            }
        }
        func centerCross(_ cg: CGContext, color: UIColor) {
            cg.setStrokeColor(color.cgColor); cg.setLineWidth(2.0)
            cg.move(to:CGPoint(x:center.x-8,y:center.y)); cg.addLine(to:CGPoint(x:center.x+8,y:center.y))
            cg.move(to:CGPoint(x:center.x,y:center.y-8)); cg.addLine(to:CGPoint(x:center.x,y:center.y+8)); cg.strokePath()
        }
        let meanAlt = max(0, satellite.semiMajorAxisKm - 6378.135)

        func drawQTHBaseMap(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage(); let cg = context.cgContext
            drawTitle("\(satellite.name) — OSCARLOCATOR Base Map",
                      subtitle: String(format: "Azimuthal-equidistant map centred on %@ (%.3f°, %.3f°) — rings are elevation at %.0f km", observer.name, observer.latitude, observer.longitude, meanAlt))
            drawQTHFrame(cg, altKm: meanAlt, elevationRings: true, kmRings: false)
            for coast in WorldMapData.coastlines {
                qStrokeGeo(coast.map { ($0.1, $0.0) }, qlat: observer.latitude, qlon: observer.longitude, color: .black, width: 0.6)
            }
            centerCross(cg, color: .systemOrange)
            ("QTH" as NSString).draw(at: CGPoint(x:center.x+8,y:center.y+4), withAttributes:[.font:UIFont.boldSystemFont(ofSize:7),.foregroundColor:UIColor.systemOrange])
            drawFooter("QTH BASE MAP — Print on paper/card at 100%. Centre is your station; rings are the satellite's elevation angle (0° ring is its range-circle edge), spokes are azimuth (N up). Register overlays on the centre cross and rim ticks.")
        }
        func drawQTHRange(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage(); let cg = context.cgContext
            let footDeg = FeatureEngine.footprintRadiusDegrees(altitudeKm: meanAlt)
            drawTitle("\(satellite.name) — OSCARLOCATOR Range Circle Overlay",
                      subtitle: String(format: "Range-circle radius %.1f° (~%.0f km) at %.0f km — concentric on the QTH-centred sheet", footDeg, footDeg*kmPerDeg, meanAlt))
            drawQTHFrame(cg, altKm: meanAlt, elevationRings: false, kmRings: true)
            let fr = radius*CGFloat(min(footDeg, qthReach)/qthReach)
            cg.setStrokeColor(UIColor.systemRed.cgColor); cg.setLineWidth(3.0)
            cg.strokeEllipse(in: CGRect(x:center.x-fr,y:center.y-fr,width:2*fr,height:2*fr))
            centerCross(cg, color: .black)
            if !cleanTransparencies {
                drawFooter("QTH RANGE CIRCLE — Print on transparency at 100%. Pin the centre cross over the QTH at the base-map centre. The satellite is in range while the path-arc lies inside the red circle; inner rings are ground distance, spokes are azimuth.")
            }
        }
        func drawQTHPathArc(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage(); let cg = context.cgContext
            let periodSeconds = max(1, satellite.periodMinutes * 60)
            let asc = observer.latitude >= 0
            let nodes = (try? OrbitPredictor.equatorCrossings(satellite, from: date.addingTimeInterval(-periodSeconds), to: date.addingTimeInterval(periodSeconds), ascending: asc, step: 120)) ?? []
            let node = nodes.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) }
            let nodeDate = node?.0 ?? date, nodeLon = node?.1 ?? 0
            let centered = nodeDate.addingTimeInterval(periodSeconds / 2)
            let rawTrack = (try? OrbitPredictor.groundTrack(satellite, centeredAt: centered, durationMinutes: satellite.periodMinutes, step: 30)) ?? []
            let canonical = rawTrack.map { ($0.1, wrappedLon($0.2 - nodeLon)) }
            let rates = LearnMath.j2Rates(meanMotionRevDay: satellite.meanMotionRevPerDay, inclinationDeg: satellite.inclinationDeg, eccentricity: satellite.eccentricity)
            let shift = -360 * periodSeconds / siderealDay + rates.nodeDegDay * periodSeconds / 86400
            drawTitle("\(satellite.name) — OSCARLOCATOR Path Arc Overlay",
                      subtitle: String(format: "Ground track projected for a QTH at %.1f° latitude · period %.1f min · advance %.1f° %@ per pass", observer.latitude, satellite.periodMinutes, abs(shift), shift < 0 ? "W" : "E"))
            drawQTHFrame(cg, altKm: meanAlt, elevationRings: false, kmRings: false)
            // canonical track as seen from a QTH at (observer.lat, 0)
            let trackPath = UIBezierPath(); var open = false; var prev: CGPoint?
            for c in canonical {
                guard let p = qpoint(observer.latitude, 0, c.0, c.1) else { open = false; prev = nil; continue }
                if let prev, hypot(p.x-prev.x, p.y-prev.y) > radius*0.75 { open = false }
                if open { trackPath.addLine(to: p) } else { trackPath.move(to: p); open = true }
                prev = p
            }
            UIColor.systemBlue.setStroke(); trackPath.lineWidth = 2.6; trackPath.stroke()
            var labelStep = 10
            for cand in [10,15,20,30,45,60,90,120,180,240,300] where satellite.periodMinutes/Double(cand) <= 14 { labelStep = cand; break }
            var lastMinute = Int.min
            let periodMinQA = max(1, periodSeconds / 60)
            for i in canonical.indices where i < rawTrack.count {
                // Wrap minutes-since-node to [0, period) so the QTH disc is
                // fully tick-marked on both sides of the equator.
                let rawMin = rawTrack[i].0.timeIntervalSince(nodeDate)/60.0
                let minutes = (rawMin.truncatingRemainder(dividingBy: periodMinQA) + periodMinQA).truncatingRemainder(dividingBy: periodMinQA)
                let minute = Int(minutes.rounded())
                guard minute != lastMinute, abs(minutes - Double(minute)) <= 0.26 else { continue }
                lastMinute = minute
                guard let p = qpoint(observer.latitude, 0, canonical[i].0, canonical[i].1) else { continue }
                let j = i + 1 < canonical.count ? i + 1 : max(0, i - 1)
                guard let q = qpoint(observer.latitude, 0, canonical[j].0, canonical[j].1) else { continue }
                var dx = q.x-p.x, dy = q.y-p.y; let len = hypot(dx, dy); guard len > 0.001 else { continue }
                dx /= len; dy /= len; let nx = -dy, ny = dx
                if minute % labelStep == 0 {
                    UIColor.systemBlue.setFill(); cg.fillEllipse(in: CGRect(x:p.x-2.2,y:p.y-2.2,width:4.4,height:4.4))
                    if minute != 0 {
                        ("\(minute)" as NSString).draw(at: CGPoint(x:p.x+nx*6-3,y:p.y+ny*6-3), withAttributes:[.font:UIFont.boldSystemFont(ofSize:6),.foregroundColor:UIColor.systemBlue])
                    }
                } else {
                    let tick = UIBezierPath()
                    tick.move(to: CGPoint(x:p.x-nx*3,y:p.y-ny*3)); tick.addLine(to: CGPoint(x:p.x+nx*3,y:p.y+ny*3))
                    UIColor.systemBlue.setStroke(); tick.lineWidth = 0.6; tick.stroke()
                }
            }
            if let eqp = qpoint(observer.latitude, 0, 0, 0) {
                UIColor.systemRed.setFill(); cg.fillEllipse(in: CGRect(x:eqp.x-4,y:eqp.y-4,width:8,height:8))
                (asc ? "EQX · 0 min (asc)" : "EQX · 0 min (desc)" as NSString).draw(at: CGPoint(x:eqp.x+6,y:eqp.y-6), withAttributes:[.font:UIFont.boldSystemFont(ofSize:7),.foregroundColor:UIColor.systemRed])
            }
            if !cleanTransparencies {
                let west = shift < 0
                let sense = west ? "counter-clockwise" : "clockwise"
                drawFooter(String(format: "QTH PATH ARC — Print on transparency at 100%%. Pin the centre cross over the QTH, align the EQX to the node longitude from Reference Orbits, then rotate the arc %.1f° %@ about the centre for each successive pass. Ticks are minutes after the EQX; labels every %d min.", abs(shift), sense, labelStep))
            }
        }

        func drawQTHCombined(_ context: UIGraphicsPDFRendererContext) {
            context.beginPage(); let cg = context.cgContext
            let footDeg = FeatureEngine.footprintRadiusDegrees(altitudeKm: meanAlt)
            drawTitle("\(satellite.name) — OSCARLOCATOR — Map + Range Circle at QTH",
                      subtitle: String(format: "Range circle over %@ (%.3f°, %.3f°) — radius %.1f° (~%.0f km) at %.0f km", observer.name, observer.latitude, observer.longitude, footDeg, footDeg*kmPerDeg, meanAlt))
            drawQTHFrame(cg, altKm: meanAlt, elevationRings: true, kmRings: false)
            for coast in WorldMapData.coastlines {
                qStrokeGeo(coast.map { ($0.1, $0.0) }, qlat: observer.latitude, qlon: observer.longitude, color: .black, width: 0.6)
            }
            let fr = radius*CGFloat(min(footDeg, qthReach)/qthReach)
            cg.setStrokeColor(UIColor.systemRed.cgColor); cg.setLineWidth(3.0)
            cg.strokeEllipse(in: CGRect(x:center.x-fr,y:center.y-fr,width:2*fr,height:2*fr))
            centerCross(cg, color: .systemOrange)
            ("QTH" as NSString).draw(at: CGPoint(x:center.x+8,y:center.y+4), withAttributes:[.font:UIFont.boldSystemFont(ofSize:7),.foregroundColor:UIColor.systemOrange])
            drawFooter("QTH MAP + RANGE — Print on paper/card at 100%. The red circle is the satellite's range circle centred on your station; rings are elevation, spokes are azimuth. Use the path-arc overlay to see when the satellite enters this circle.")
        }

        return renderer.pdfData { context in
            if kind == .qthCombined {
                drawQTHCombined(context); drawQTHPathArc(context)
            } else if kind.isQTHCentered {
                drawQTHBaseMap(context); drawQTHRange(context); drawQTHPathArc(context)
            } else {
                if kind.includesBaseMap { drawBaseMap(context) }
                if kind.includesRangeCircle { drawRangeCircle(context) }
                if kind.includesPathArc { drawPathArc(context) }
            }
        }
#else
        let meanAltitude = max(0, satellite.semiMajorAxisKm - 6378.135)
        let footprintDeg = FeatureEngine.footprintRadiusDegrees(altitudeKm: meanAltitude)
        return Data("OrbitDeck OSCARLOCATOR three-sheet printable\n1 Base map\n2 Range circle overlay (\(String(format: "%.1f", footprintDeg)) deg)\n3 Path arc overlay\nSatellite: \(satellite.name)\n".utf8)
#endif
    }

    static func learnHandoutPDF(observer: ObserverSite, labOrbit: LabOrbitDefinition? = nil) -> Data {
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let pages: [(String, String, [(String, String)])] = [
            ("1. Orbits", "The geometry behind satellite motion", [
                ("Kepler", "Equal areas are swept in equal times. A spacecraft moves fastest near perigee and slowest near apogee."),
                ("Period", "T = 2*pi*sqrt(a^3/mu). Higher circular orbits have longer periods and lower speed."),
                ("Elements", "Inclination sets latitude reach; RAAN rotates the plane; argument of perigee rotates the ellipse; mean anomaly sets position at epoch."),
                ("Shared lab orbit", labOrbit.map { String(format: "OSCARLOCATOR lab: altitude %.0f km, e %.3f, inclination %.1f deg, RAAN %.1f deg, arg. perigee %.1f deg, mean anomaly %.1f deg.", $0.altitudeKm, $0.eccentricity, $0.inclinationDeg, $0.raanDeg, $0.argumentOfPerigeeDeg, $0.meanAnomalyDeg) } ?? "No shared OSCARLOCATOR lab orbit was saved when this handout was generated."),
                ("J2", "Earth's equatorial bulge causes nodal and apsidal precession. Near 98 degrees in LEO, nodal drift can be Sun-synchronous."),
                ("Decay", "Low-orbit lifetime depends strongly on perigee, atmospheric density, drag and solar activity. OrbitDeck uses n-dot when usable, then B* as fallback.")
            ]),
            ("2. Passes", "From ground track to what the operator sees", [
                ("Footprint", "At altitude h, the horizon footprint half-angle is acos(Re/(Re+h)). Higher satellites cover more Earth at once."),
                ("Elevation", "A high pass means the ground track comes close to your station. Low passes are longer paths through clutter and atmosphere."),
                ("Pointing", "Azimuth and elevation change continuously from AOS through TCA to LOS. A horizon mask can represent trees, buildings or terrain."),
                ("Sunlight", "A satellite is optically visible when it is sunlit while the observer is sufficiently dark and the satellite is above the local horizon."),
                ("Mutual coverage", "A two-way satellite contact is geometrically possible only while both stations lie inside the satellite footprint at the same time.")
            ]),
            ("3. Radio", "Doppler, transponders and link margin", [
                ("Doppler", "Delta-f ~= -f*v_r/c. Approaching signals are heard high; receding signals are heard low."),
                ("Linear birds", "Full-duplex operation keeps your own signal in the passband. Inverting transponders reverse the passband offset direction."),
                ("Path loss", "FSPL grows with both distance and frequency. A pass generally improves toward TCA as slant range falls."),
                ("Link budget", "Received power = EIRP - path loss - losses + receive gain. Margin above receiver sensitivity is the practical verdict."),
                ("Polarization", "Faraday rotation can strongly rotate linear polarization at VHF. Circular polarization avoids orientation nulls but wrong-hand loss is severe.")
            ]),
            ("4. Operating", "A compact satellite-operating checklist", [
                ("Before", "Refresh elements, verify mode/transponder, find the pass, inspect max elevation and AOS/LOS azimuth, and check local obstructions."),
                ("At AOS", "Start listening early, use full duplex when possible, identify Doppler direction, and avoid transmitting until you can hear the satellite."),
                ("During", "Track antenna pointing, tune smoothly through Doppler, use minimum power needed, and leave room for other stations."),
                ("After", "Log UTC, satellite, grid, mode and stations worked. Submit public status only when you intend to publish your callsign/grid."),
                ("Station", "QTH: \(observer.name)  \(String(format: "%.4f", observer.latitude)), \(String(format: "%.4f", observer.longitude)). Generated by OrbitDeck iOS.")
            ])
        ]
        return renderer.pdfData { context in
            for (index, item) in pages.enumerated() {
                context.beginPage()
                var y: CGFloat = 44
                let margin: CGFloat = 44
                func draw(_ text: String, font: UIFont, color: UIColor = .label, height: CGFloat = 80) {
                    let style = NSMutableParagraphStyle(); style.lineSpacing = 3
                    (text as NSString).draw(in: CGRect(x: margin, y: y, width: page.width - 2*margin, height: height), withAttributes: [.font:font,.foregroundColor:color,.paragraphStyle:style])
                }
                draw("OrbitDeck Satellite Classroom Handout", font: .boldSystemFont(ofSize: 18), height: 28); y += 30
                draw(item.0, font: .boldSystemFont(ofSize: 24), height: 34); y += 38
                draw(item.1, font: .systemFont(ofSize: 11), color: .secondaryLabel, height: 34); y += 44
                for (title, body) in item.2 {
                    draw(title, font: .boldSystemFont(ofSize: 13), height: 20); y += 21
                    draw(body, font: .systemFont(ofSize: 10), height: 62); y += 68
                }
                draw("Page \(index + 1) of \(pages.count) - educational planning material, not a substitute for authoritative orbital or safety data.", font: .systemFont(ofSize: 8), color: .secondaryLabel, height: 20)
            }
        }
#else
        return Data("OrbitDeck Satellite Classroom Handout\nOrbits - Passes - Radio - Operating\n".utf8)
#endif
    }

    static func orbitalHistorySamplesCSV(_ samples: [OrbitalHistorySample]) -> String {
        var rows = [["epoch_utc", "semi_major_axis_km", "eccentricity", "inclination_deg",
                     "period_min", "apogee_km", "perigee_km", "bstar"]]
        for sample in samples {
            func f(_ value: Double?) -> String { value.map { String(format: "%.12g", $0) } ?? "" }
            rows.append([iso(sample.epoch), f(sample.semiMajorAxis), f(sample.eccentricity),
                         f(sample.inclination), f(sample.period), f(sample.apogee),
                         f(sample.perigee), f(sample.bstar)])
        }
        return csv(rows)
    }

    static func orbitalHistorySummaryCSV(_ samples: [OrbitalHistorySample]) -> String {
        var rows = [["Element", "First", "Last", "Change", "Per year", "Min", "Max", "Samples"]]
        for summary in FeatureEngine.summarizeHistory(samples) {
            let label = summary.column.unit.isEmpty ? summary.column.label : "\(summary.column.label) (\(summary.column.unit))"
            rows.append([label, String(format: "%.8g", summary.first),
                         String(format: "%.8g", summary.last), String(format: "%+.8g", summary.delta),
                         String(format: "%+.8g", summary.ratePerYear), String(format: "%.8g", summary.minimum),
                         String(format: "%.8g", summary.maximum), String(summary.samples)])
        }
        return csv(rows)
    }

    static func orbitalHistoryReportPDF(_ samples: [OrbitalHistorySample], satellite: SatelliteRecord,
                                        lower: Double = 0, upper: Double = 1) -> Data {
        let visible = FeatureEngine.historyWindow(samples, lower: lower, upper: upper)
        let subtitle: String
        if let first = visible.first?.epoch, let last = visible.last?.epoch {
            subtitle = "Space-Track gp_history · \(human(first)) through \(human(last)) UTC · \(visible.count) archived element sets"
        } else {
            subtitle = "Space-Track gp_history · no samples in the selected window"
        }
        return planningReportPDF(title: "\(satellite.name) — orbital history",
                                 subtitle: subtitle, csvText: orbitalHistorySummaryCSV(visible))
    }

    static func comparisonCSV(_ entries: [PassComparisonEntry], observer: ObserverSite, days: Int) -> String {
        var rows = [["satellite", "norad", "station", "window_days", "passes", "best_aos_utc", "best_max_el_deg", "best_duration_min"]]
        for entry in entries {
            let best = entry.bestPass
            rows.append([
                entry.satellite.name, String(entry.satellite.id), observer.name, String(days), String(entry.passCount),
                best.map { iso($0.aos) } ?? "",
                best.map { String(format: "%.1f", $0.maxElevation) } ?? "",
                best.map { String(format: "%.1f", $0.duration / 60) } ?? ""
            ])
        }
        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func passCardPNG(pass: PredictedPass, satellite: SatelliteRecord, observer: ObserverSite) -> Data {
#if canImport(UIKit)
        let size = CGSize(width: 1200, height: 630)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { image in
            let cg = image.cgContext
            UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            let white = UIColor(white: 0.94, alpha: 1), muted = UIColor(white: 0.65, alpha: 1)
            let accent = UIColor.systemBlue, green = UIColor.systemGreen
            func draw(_ text: String, rect: CGRect, font: UIFont, color: UIColor? = nil) {
                (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color ?? white])
            }
            draw("OrbitDeck Pass Card", rect: CGRect(x: 52, y: 40, width: 700, height: 42), font: .boldSystemFont(ofSize: 30))
            draw("\(satellite.name) · NORAD \(satellite.id)", rect: CGRect(x: 52, y: 88, width: 700, height: 40), font: .boldSystemFont(ofSize: 25))
            draw("\(observer.name) · AOS \(human(pass.aos)) UTC · LOS \(human(pass.los)) UTC", rect: CGRect(x: 52, y: 133, width: 800, height: 28), font: .systemFont(ofSize: 17), color: muted)

            let skyCenter = CGPoint(x: 310, y: 370), skyR: CGFloat = 180
            cg.setStrokeColor(UIColor(white: 0.25, alpha: 1).cgColor); cg.setLineWidth(2)
            let skyFractions: [CGFloat] = [1.0, 2.0/3.0, 1.0/3.0]
            for f in skyFractions { let r = skyR * f; cg.strokeEllipse(in: CGRect(x: skyCenter.x-r, y: skyCenter.y-r, width: 2*r, height: 2*r)) }
            cg.move(to: CGPoint(x: skyCenter.x-skyR, y: skyCenter.y)); cg.addLine(to: CGPoint(x: skyCenter.x+skyR, y: skyCenter.y)); cg.strokePath()
            cg.move(to: CGPoint(x: skyCenter.x, y: skyCenter.y-skyR)); cg.addLine(to: CGPoint(x: skyCenter.x, y: skyCenter.y+skyR)); cg.strokePath()
            draw("N", rect: CGRect(x: skyCenter.x-8, y: skyCenter.y-skyR-28, width: 30, height: 24), font: .boldSystemFont(ofSize: 16), color: muted)
            draw("Sky track", rect: CGRect(x: 230, y: 574, width: 180, height: 24), font: .systemFont(ofSize: 15), color: muted)
            if let path = try? OrbitPredictor.skyPath(satellite, observer: observer, pass: pass, step: 15), path.count > 1 {
                let p = UIBezierPath()
                for (i, sp) in path.enumerated() {
                    let rr = skyR * CGFloat((90 - max(0, min(90, sp.elevation))) / 90)
                    let a = CGFloat(sp.azimuth * .pi / 180)
                    let q = CGPoint(x: skyCenter.x + rr * sin(a), y: skyCenter.y - rr * cos(a))
                    i == 0 ? p.move(to: q) : p.addLine(to: q)
                }
                accent.setStroke(); p.lineWidth = 5; p.stroke()
            }

            let chart = CGRect(x: 565, y: 255, width: 570, height: 230)
            cg.setStrokeColor(UIColor(white: 0.25, alpha: 1).cgColor); cg.stroke(chart)
            var samples: [(Double, Double)] = []
            let span = max(pass.duration, 1)
            for i in 0...80 {
                let t = pass.aos.addingTimeInterval(span * Double(i) / 80)
                if let look = try? OrbitPredictor.look(satellite, observer: observer, at: t) {
                    samples.append((Double(i)/80, -145.8e6 * look.rangeRateKmS / 299_792.458))
                }
            }
            if let lo = samples.map({$0.1}).min(), let hi = samples.map({$0.1}).max(), hi > lo {
                let p = UIBezierPath()
                for (i, sample) in samples.enumerated() {
                    let x = chart.minX + CGFloat(sample.0) * chart.width
                    let y = chart.maxY - CGFloat((sample.1-lo)/(hi-lo)) * chart.height
                    i == 0 ? p.move(to: CGPoint(x:x,y:y)) : p.addLine(to: CGPoint(x:x,y:y))
                }
                green.setStroke(); p.lineWidth = 4; p.stroke()
                draw(String(format:"145.8 MHz Doppler  %+.0f to %+.0f Hz", lo, hi), rect: CGRect(x: chart.minX, y: chart.maxY+12, width: chart.width, height: 25), font: .systemFont(ofSize: 15), color: muted)
            }
            draw(String(format:"MAX EL\n%.0f°", pass.maxElevation), rect: CGRect(x: 585, y: 175, width: 150, height: 68), font: .boldSystemFont(ofSize: 23))
            draw(String(format:"DURATION\n%.1f min", pass.duration/60), rect: CGRect(x: 780, y: 175, width: 175, height: 68), font: .boldSystemFont(ofSize: 23))
            draw(String(format:"AOS / LOS AZ\n%.0f° / %.0f°", pass.aosAzimuth, pass.losAzimuth), rect: CGRect(x: 980, y: 175, width: 180, height: 68), font: .boldSystemFont(ofSize: 20))
            draw("Generated by OrbitDeck iOS", rect: CGRect(x: 565, y: 570, width: 400, height: 24), font: .systemFont(ofSize: 14), color: muted)
        }
#else
        return Data("OrbitDeck pass card\n\(satellite.name)\nAOS \(iso(pass.aos))\n".utf8)
#endif
    }


    static func planningReportPDF(title: String, subtitle: String, csvText: String) -> Data {
#if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 792, height: 612) // US Letter landscape
        let rows = parseCSV(csvText)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            let margin: CGFloat = 38
            let usableWidth = page.width - margin * 2
            let headerFont = UIFont.boldSystemFont(ofSize: 8)
            let bodyFont = UIFont.monospacedSystemFont(ofSize: 7.2, weight: .regular)
            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let subFont = UIFont.systemFont(ofSize: 9)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let header = rows.first ?? []
            let body = Array(rows.dropFirst())
            let colCount = max(1, header.count)
            let colWidth = usableWidth / CGFloat(colCount)
            let rowHeight: CGFloat = 18
            let tableTop: CGFloat = 100
            let tableBottom: CGFloat = page.height - 42
            let rowsPerPage = max(1, Int((tableBottom - tableTop - rowHeight) / rowHeight))
            let pageCount = max(1, Int(ceil(Double(max(1, body.count)) / Double(rowsPerPage))))

            func drawPageHeader(_ pageIndex: Int) {
                (title as NSString).draw(in: CGRect(x: margin, y: 28, width: usableWidth, height: 28), withAttributes: [.font: titleFont, .foregroundColor: UIColor.label])
                (subtitle as NSString).draw(in: CGRect(x: margin, y: 60, width: usableWidth, height: 25), withAttributes: [.font: subFont, .foregroundColor: UIColor.secondaryLabel])
                let footer = "OrbitDeck iOS planning report · page \(pageIndex + 1) of \(pageCount)"
                (footer as NSString).draw(in: CGRect(x: margin, y: page.height - 28, width: usableWidth, height: 14), withAttributes: [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: UIColor.secondaryLabel])
            }
            func drawRow(_ cells: [String], y: CGFloat, headerRow: Bool) {
                if headerRow {
                    UIColor.secondarySystemBackground.setFill()
                    UIBezierPath(rect: CGRect(x: margin, y: y, width: usableWidth, height: rowHeight)).fill()
                }
                for col in 0..<colCount {
                    let cell = col < cells.count ? cells[col] : ""
                    let rect = CGRect(x: margin + CGFloat(col) * colWidth + 3, y: y + 3, width: colWidth - 6, height: rowHeight - 5)
                    (cell as NSString).draw(in: rect, withAttributes: [.font: headerRow ? headerFont : bodyFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
                }
                UIColor.separator.setStroke()
                let line = UIBezierPath(); line.move(to: CGPoint(x: margin, y: y + rowHeight)); line.addLine(to: CGPoint(x: margin + usableWidth, y: y + rowHeight)); line.lineWidth = 0.35; line.stroke()
            }

            for pageIndex in 0..<pageCount {
                context.beginPage()
                drawPageHeader(pageIndex)
                drawRow(header, y: tableTop, headerRow: true)
                let first = pageIndex * rowsPerPage
                let last = min(body.count, first + rowsPerPage)
                if first < last {
                    for (offset, row) in body[first..<last].enumerated() {
                        drawRow(row, y: tableTop + rowHeight * CGFloat(offset + 1), headerRow: false)
                    }
                } else {
                    ("No rows." as NSString).draw(at: CGPoint(x: margin, y: tableTop + 28), withAttributes: [.font: subFont, .foregroundColor: UIColor.secondaryLabel])
                }
            }
        }
#else
        return Data((title + "\n" + subtitle + "\n\n" + csvText).utf8)
#endif
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if quoted {
                if c == "\"" {
                    let n = text.index(after: i)
                    if n < text.endIndex, text[n] == "\"" { field.append("\""); i = n }
                    else { quoted = false }
                } else { field.append(c) }
            } else {
                if c == "\"" { quoted = true }
                else if c == "," { row.append(field); field = "" }
                else if c == "\n" {
                    if field.last == "\r" { field.removeLast() }
                    row.append(field); field = ""
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                } else { field.append(c) }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func targetWindowsCSV(_ windows: [TargetWindowRecord], satellite: SatelliteRecord, target: String) -> String {
        var rows = [["satellite","norad","target","start_utc","end_utc","duration_min","footprint_margin_deg"]]
        rows += windows.map { w in [satellite.name,String(satellite.id),target,human(w.start),human(w.end),String(format:"%.1f",w.duration/60),String(format:"%.1f",w.marginDegrees)] }
        return csv(rows)
    }

    static func workableHorizonCSV(_ snapshot: WorkableHorizonSnapshot, days: Int) -> String {
        var rows = [["type","workable","days","satellites_sampled","passes_sampled"]]
        rows += snapshot.states.map { ["state",$0,String(days),String(snapshot.satelliteCount),String(snapshot.passCount)] }
        rows += snapshot.dxcc.map { ["DXCC",$0,String(days),String(snapshot.satelliteCount),String(snapshot.passCount)] }
        rows += snapshot.grids.map { ["grid",$0,String(days),String(snapshot.satelliteCount),String(snapshot.passCount)] }
        return csv(rows)
    }

    static func planningSearchCSV(_ hits: [PlanningSearchHit], target: String, days: Int) -> String {
        var rows = [["target","satellite","norad","start_utc","end_utc","duration_min","max_el_deg","days_searched"]]
        rows += hits.map { h in [target,h.satelliteName,String(h.norad),human(h.start),human(h.end),String(format:"%.1f",h.duration/60),String(format:"%.1f",h.maxElevation),String(days)] }
        return csv(rows)
    }

    static func visiblePassesCSV(_ rowsIn: [VisiblePassRecord], satellite: SatelliteRecord) -> String {
        var rows = [["satellite","norad","aos_utc","los_utc","max_el_deg","best_est_mag","best_sun_el_deg","best_sat_el_deg"]]
        rows += rowsIn.map { r in [satellite.name,String(satellite.id),human(r.pass.aos),human(r.pass.los),String(format:"%.1f",r.pass.maxElevation),String(format:"%.2f",r.bestEstimatedMagnitude),String(format:"%.1f",r.bestSunElevation),String(format:"%.1f",r.bestSatelliteElevation)] }
        return csv(rows)
    }

    static func satelliteLOSCSV(_ windows: [SatelliteLOSWindow], first: SatelliteRecord, second: SatelliteRecord) -> String {
        var rows = [["satellite_a","norad_a","satellite_b","norad_b","start_utc","end_utc","duration_min"]]
        rows += windows.map { w in [first.name,String(first.id),second.name,String(second.id),human(w.start),human(w.end),String(format:"%.1f",w.duration/60)] }
        return csv(rows)
    }

    static func rovePassesCSV(_ entries: [RovePassRecord], stop: String) -> String {
        var rows = [["stop","satellite","norad","aos_utc","los_utc","max_el_deg","grids","states","dxcc"]]
        rows += entries.map { r in [stop,r.satelliteName,String(r.norad),human(r.aos),human(r.los),String(format:"%.1f",r.maxElevation),r.grids.joined(separator:" "),r.states.joined(separator:" "),r.dxcc.joined(separator:" | ")] }
        return csv(rows)
    }

    static func horizonMaskedPassesCSV(_ entries: [(PredictedPass, Date, Date)], satellite: SatelliteRecord, mask: HorizonMask) -> String {
        var rows = [["satellite","norad","raw_aos_utc","effective_aos_utc","effective_los_utc","raw_los_utc","raw_max_el_deg","mask_n","mask_e","mask_s","mask_w"]]
        rows += entries.map { p,effectiveAOS,effectiveLOS in [satellite.name,String(satellite.id),human(p.aos),human(effectiveAOS),human(effectiveLOS),human(p.los),String(format:"%.1f",p.maxElevation),String(format:"%.1f",mask.north),String(format:"%.1f",mask.east),String(format:"%.1f",mask.south),String(format:"%.1f",mask.west)] }
        return csv(rows)
    }

    private static func durationHMS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func mhz(_ hz: Int64) -> String {
        hz == 0 ? "—" : String(format: "%.6f", Double(hz) / 1_000_000)
    }

#if canImport(UIKit)
    private static func drawSkyPlot(_ cg: CGContext, rect: CGRect, title: String, points: [SkyPoint]) {
        let r = min(rect.width, rect.height) / 2 - 22
        let center = CGPoint(x: rect.midX, y: rect.midY + 8)
        (title as NSString).draw(in: CGRect(x: rect.minX, y: rect.minY - 20, width: rect.width, height: 18), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.label])
        cg.setStrokeColor(UIColor.systemGray3.cgColor); cg.setLineWidth(0.7)
        for elevation in [0.0, 30.0, 60.0] {
            let rr = r * CGFloat((90 - elevation) / 90)
            cg.strokeEllipse(in: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2))
        }
        for az in stride(from: 0.0, to: 360.0, by: 45.0) {
            let a = CGFloat(az * .pi / 180)
            cg.move(to: center); cg.addLine(to: CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))); cg.strokePath()
        }
        let path = UIBezierPath()
        var plotted: [CGPoint] = []
        for point in points {
            let rr = r * CGFloat((90 - max(0, min(90, point.elevation))) / 90)
            let a = CGFloat(point.azimuth * .pi / 180)
            let p = CGPoint(x: center.x + rr * sin(a), y: center.y - rr * cos(a))
            plotted.append(p)
            plotted.count == 1 ? path.move(to: p) : path.addLine(to: p)
        }
        UIColor.systemBlue.setStroke(); path.lineWidth = 2.2; path.stroke()
        if let first = plotted.first {
            UIColor.systemGreen.setFill(); UIBezierPath(ovalIn: CGRect(x: first.x-4, y: first.y-4, width: 8, height: 8)).fill()
        }
        if let last = plotted.last {
            UIColor.systemOrange.setFill(); UIBezierPath(ovalIn: CGRect(x: last.x-4, y: last.y-4, width: 8, height: 8)).fill()
        }
        for (label, p) in [("N", CGPoint(x:center.x-5,y:center.y-r-18)), ("E", CGPoint(x:center.x+r+5,y:center.y-6)), ("S", CGPoint(x:center.x-5,y:center.y+r+4)), ("W", CGPoint(x:center.x-r-17,y:center.y-6))] {
            (label as NSString).draw(at: p, withAttributes: [.font: UIFont.boldSystemFont(ofSize: 8), .foregroundColor: UIColor.secondaryLabel])
        }
    }

    private static func drawIlluminationPage(
        context: UIGraphicsPDFRendererContext,
        page: CGRect,
        satellite: SatelliteRecord,
        raster: IlluminationRasterSnapshot,
        generatedAt: Date
    ) {
        context.beginPage()
        let margin: CGFloat = 42
        let usable = page.width - margin * 2
        let muted = UIColor.secondaryLabel
        ("\(satellite.name) — illumination" as NSString).draw(in: CGRect(x: margin, y: 38, width: usable, height: 28), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.label])
        ("Bright = sunlit, dark = Earth shadow. Day vs minutes into one orbit over \(raster.days) days from \(human(generatedAt)) UTC. \(raster.rowsPerOrbit) samples/orbit." as NSString).draw(in: CGRect(x: margin, y: 72, width: usable, height: 32), withAttributes: [.font: UIFont.systemFont(ofSize: 9.2), .foregroundColor: muted])

        let chart = CGRect(x: 68, y: 126, width: 500, height: 420)
        let cg = context.cgContext
        cg.setFillColor(UIColor.black.cgColor); cg.fill(chart)
        let cw = chart.width / CGFloat(raster.days)
        let ch = chart.height / CGFloat(raster.rowsPerOrbit)
        for day in 0..<raster.days {
            for row in 0..<raster.rowsPerOrbit where raster.isSunlit(day: day, row: row) {
                let x = chart.minX + CGFloat(day) * cw
                let y = chart.maxY - CGFloat(row + 1) * ch
                cg.setFillColor(UIColor(red: 0.95, green: 0.84, blue: 0.20, alpha: 1).cgColor)
                cg.fill(CGRect(x: x, y: y, width: max(0.7, cw + 0.15), height: max(0.7, ch + 0.15)))
            }
        }
        cg.setStrokeColor(UIColor.systemGray.cgColor); cg.setLineWidth(0.7); cg.stroke(chart)
        ("0" as NSString).draw(at: CGPoint(x: chart.minX-18, y: chart.maxY-8), withAttributes: [.font:UIFont.systemFont(ofSize:7),.foregroundColor:muted])
        (String(format:"%.0f", raster.periodMinutes) as NSString).draw(at: CGPoint(x: chart.minX-29, y: chart.minY-5), withAttributes: [.font:UIFont.systemFont(ofSize:7),.foregroundColor:muted])
        ("minutes into orbit" as NSString).draw(in:CGRect(x:8,y:chart.midY-45,width:55,height:90),withAttributes:[.font:UIFont.systemFont(ofSize:7),.foregroundColor:muted])
        ("days from start" as NSString).draw(in:CGRect(x:chart.midX-60,y:chart.maxY+8,width:120,height:14),withAttributes:[.font:UIFont.systemFont(ofSize:8),.foregroundColor:muted])

        let bars = CGRect(x: 68, y: 596, width: 500, height: 82)
        cg.setStrokeColor(UIColor.systemGray4.cgColor); cg.stroke(bars)
        for day in 0..<raster.days {
            let eclipse = CGFloat(1 - raster.daySunlitFractions[day])
            let h = bars.height * eclipse
            cg.setFillColor(UIColor.systemBlue.cgColor)
            cg.fill(CGRect(x: bars.minX + CGFloat(day) * bars.width / CGFloat(raster.days), y: bars.maxY - h, width: max(0.7, bars.width / CGFloat(raster.days) - 0.2), height: h))
        }
        ("Eclipse % / orbit" as NSString).draw(in:CGRect(x:margin,y:570,width:120,height:15),withAttributes:[.font:UIFont.boldSystemFont(ofSize:8),.foregroundColor:UIColor.label])
        let mean = raster.meanSunlitFraction * 100
        (String(format:"Mean sunlit fraction %.1f%% · mean eclipse fraction %.1f%% per orbit",mean,100-mean) as NSString).draw(in:CGRect(x:margin,y:704,width:usable,height:18),withAttributes:[.font:UIFont.boldSystemFont(ofSize:10),.foregroundColor:UIColor.label])
        ("Solid bright bands are full-Sun seasons; repeating dark bands show eclipse duration and are useful for spacecraft power-budget planning." as NSString).draw(in:CGRect(x:margin,y:727,width:usable,height:28),withAttributes:[.font:UIFont.systemFont(ofSize:8.5),.foregroundColor:muted])
    }

    private static func drawProgressionPages(
        context: UIGraphicsPDFRendererContext,
        page: CGRect,
        satellite: SatelliteRecord,
        observer: ObserverSite,
        minElevation: Double,
        days: Int,
        passes: [PredictedPass],
        generatedAt: Date,
        includeTable: Bool
    ) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = calendar.startOfDay(for: generatedAt)
        var byDay: [Int: [PredictedPass]] = [:]
        for pass in passes {
            let d = calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: pass.aos)).day ?? 0
            if d >= 0 && d < days { byDay[d, default: []].append(pass) }
        }
        let rowsPerPage = 16
        let dayLabel = DateFormatter(); dayLabel.locale = Locale(identifier:"en_US_POSIX"); dayLabel.timeZone = TimeZone(secondsFromGMT:0); dayLabel.dateFormat = "EEE MM-dd"
        for d0 in stride(from: 0, to: days, by: rowsPerPage) {
            let d1 = min(days, d0 + rowsPerPage)
            context.beginPage()
            let margin: CGFloat = 42, usable = page.width - 84
            let title = d0 == 0 ? "\(satellite.name) — pass progression" : "\(satellite.name) — pass progression (continued)"
            (title as NSString).draw(in:CGRect(x:margin,y:38,width:usable,height:26),withAttributes:[.font:UIFont.boldSystemFont(ofSize:d0 == 0 ? 20 : 14),.foregroundColor:UIColor.label])
            if d0 == 0 {
                ("\(days)-day progression from \(human(generatedAt)) UTC · station \(observer.name) · minimum elevation \(String(format:"%.0f",minElevation))° · \(passes.count) passes. Each lane is one UTC day; bars are positioned by AOS→LOS and colored by max elevation." as NSString).draw(in:CGRect(x:margin,y:70,width:usable,height:38),withAttributes:[.font:UIFont.systemFont(ofSize:9),.foregroundColor:UIColor.secondaryLabel])
            }
            let chart = CGRect(x: 104, y: d0 == 0 ? 126 : 90, width: 450, height: 590)
            let laneH = chart.height / CGFloat(d1-d0)
            let cg = context.cgContext
            for (local, day) in (d0..<d1).enumerated() {
                let y = chart.minY + CGFloat(local) * laneH
                if local % 2 == 1 { cg.setFillColor(UIColor.secondarySystemBackground.cgColor); cg.fill(CGRect(x:chart.minX,y:y,width:chart.width,height:laneH)) }
                for hour in stride(from: 0, through: 24, by: 6) {
                    let x = chart.minX + CGFloat(hour) / 24 * chart.width
                    cg.setStrokeColor(UIColor.systemGray5.cgColor); cg.setLineWidth(0.5); cg.move(to:CGPoint(x:x,y:y)); cg.addLine(to:CGPoint(x:x,y:y+laneH)); cg.strokePath()
                }
                let date = calendar.date(byAdding:.day,value:day,to:startDay)!
                (dayLabel.string(from:date) as NSString).draw(in:CGRect(x:42,y:y+laneH/2-6,width:58,height:13),withAttributes:[.font:UIFont.systemFont(ofSize:7.5),.foregroundColor:UIColor.label])
                for pass in byDay[day] ?? [] {
                    let c = calendar.dateComponents([.hour,.minute,.second], from: pass.aos)
                    let e = calendar.dateComponents([.hour,.minute,.second], from: pass.los)
                    let h0 = Double(c.hour ?? 0) + Double(c.minute ?? 0)/60 + Double(c.second ?? 0)/3600
                    var h1 = Double(e.hour ?? 0) + Double(e.minute ?? 0)/60 + Double(e.second ?? 0)/3600
                    if calendar.startOfDay(for:pass.los) > calendar.startOfDay(for:pass.aos) { h1 = 24 }
                    let x0 = chart.minX + CGFloat(h0/24) * chart.width
                    let w = max(3, CGFloat(max(0.15,h1-h0)/24) * chart.width)
                    let color: UIColor = pass.maxElevation >= 45 ? .systemGreen : (pass.maxElevation >= 20 ? .systemBlue : UIColor(red:0.23,green:0.36,blue:0.65,alpha:1))
                    color.setFill(); UIBezierPath(roundedRect:CGRect(x:x0,y:y+laneH*0.2,width:w,height:laneH*0.6),cornerRadius:2).fill()
                    if w > 28 { (String(format:"%.0f°",pass.maxElevation) as NSString).draw(in:CGRect(x:x0+2,y:y+laneH*0.28,width:w-4,height:10),withAttributes:[.font:UIFont.boldSystemFont(ofSize:6),.foregroundColor:UIColor.label]) }
                }
            }
            for hour in stride(from:0,through:24,by:6) {
                let x=chart.minX+CGFloat(hour)/24*chart.width
                (String(format:"%02d",hour) as NSString).draw(at:CGPoint(x:x-6,y:chart.maxY+5),withAttributes:[.font:UIFont.systemFont(ofSize:7),.foregroundColor:UIColor.secondaryLabel])
            }
            ("UTC time of day" as NSString).draw(in:CGRect(x:chart.midX-50,y:chart.maxY+20,width:100,height:14),withAttributes:[.font:UIFont.systemFont(ofSize:8),.foregroundColor:UIColor.secondaryLabel])
        }
        guard includeTable, !passes.isEmpty else { return }
        context.beginPage()
        let margin: CGFloat=42, usable=page.width-84
        ("\(satellite.name) — progression pass table" as NSString).draw(in:CGRect(x:margin,y:38,width:usable,height:26),withAttributes:[.font:UIFont.boldSystemFont(ofSize:17),.foregroundColor:UIColor.label])
        var y: CGFloat=78
        let widths:[CGFloat]=[90,90,55,55,70,55,55]
        let heads=["AOS UTC","LOS UTC","Dur","Max","TCA UTC","AOS az","LOS az"]
        var x=margin
        for (h,w) in zip(heads,widths){(h as NSString).draw(in:CGRect(x:x,y:y,width:w,height:15),withAttributes:[.font:UIFont.boldSystemFont(ofSize:7.5),.foregroundColor:UIColor.label]);x+=w}
        y+=17
        for pass in passes {
            if y>744 { context.beginPage(); y=50 }
            let vals=[human(pass.aos),human(pass.los),String(format:"%.1fm",pass.duration/60),String(format:"%.0f°",pass.maxElevation),human(pass.tca),String(format:"%.0f°",pass.aosAzimuth),String(format:"%.0f°",pass.losAzimuth)]
            x=margin
            for(v,w) in zip(vals,widths){(v as NSString).draw(in:CGRect(x:x,y:y,width:w,height:13),withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:6.8,weight:.regular),.foregroundColor:UIColor.label]);x+=w}
            y+=13
        }
    }
#endif

    private static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func temporaryFile(name: String, data: Data) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitDeckExports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func temporaryTextFile(name: String, text: String) throws -> URL {
        try temporaryFile(name: name, data: Data(text.utf8))
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func human(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func icsDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private static func icsEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Final feature-parity exports

    static func celestialBodiesCSV(
        _ points: [CelestialPoint],
        observer: ObserverSite,
        at date: Date
    ) -> String {
        var rows = [["body", "category", "az_deg", "el_deg", "station", "time_utc"]]
        rows += points.map {
            [$0.name, $0.category, String(format: "%.3f", $0.azimuth),
             String(format: "%.3f", $0.elevation), observer.name, human(date)]
        }
        return csv(rows)
    }

    static func celestialBodiesPDF(
        _ points: [CelestialPoint],
        observer: ObserverSite,
        at date: Date
    ) -> Data {
        planningReportPDF(
            title: "Celestial radio sources",
            subtitle: "Station \(observer.name) · \(String(format: "%.3f", observer.latitude)), \(String(format: "%.3f", observer.longitude)) · \(human(date)) UTC",
            csvText: celestialBodiesCSV(points, observer: observer, at: date)
        )
    }

    static func emeBandAnalysisCSV(
        _ rowsIn: [EMEBandAnalysisRow],
        observer: ObserverSite,
        at date: Date
    ) -> String {
        var rows = [["band", "doppler_hz", "faraday_deg", "sky_temp_k", "libration_spread_hz", "path_loss_db", "station", "time_utc"]]
        rows += rowsIn.map {
            [$0.band, String(format: "%.1f", $0.dopplerHz),
             String(format: "%.2f", $0.faradayDegrees),
             String(format: "%.1f", $0.skyTemperatureK),
             String(format: "%.2f", $0.librationSpreadHz),
             String(format: "%.2f", $0.pathLossDb), observer.name, human(date)]
        }
        return csv(rows)
    }

    static func emeBandAnalysisPDF(
        _ rows: [EMEBandAnalysisRow],
        observer: ObserverSite,
        at date: Date
    ) -> Data {
        planningReportPDF(
            title: "EME — moonbounce analysis",
            subtitle: "Per-band analysis · station \(observer.name) · \(human(date)) UTC",
            csvText: emeBandAnalysisCSV(rows, observer: observer, at: date)
        )
    }

    static func emeWindowsCSV(
        _ windows: [EMEWindowRecord],
        home: ObserverSite,
        dx: ObserverSite
    ) -> String {
        var rows = [["home", "dx", "start_utc", "end_utc", "duration_min"]]
        rows += windows.map {
            [home.name, dx.name, human($0.start), human($0.end), String(format: "%.1f", $0.duration / 60)]
        }
        return csv(rows)
    }

    static func conjunctionsCSV(
        _ events: [ConjunctionRecord],
        primary: SatelliteRecord,
        secondary: SatelliteRecord,
        hours: Double,
        thresholdKm: Double
    ) -> String {
        var rows = [["primary", "secondary", "tca_utc", "miss_km", "relative_velocity_km_s", "screen_hours", "threshold_km"]]
        rows += events.map {
            [primary.name, secondary.name, human($0.date), String(format: "%.3f", $0.missDistanceKm),
             String(format: "%.5f", $0.relativeVelocityKmS), String(format: "%.1f", hours),
             String(format: "%.1f", thresholdKm)]
        }
        return csv(rows)
    }

    static func conjunctionsPDF(
        _ events: [ConjunctionRecord],
        primary: SatelliteRecord,
        secondary: SatelliteRecord,
        hours: Double,
        thresholdKm: Double
    ) -> Data {
        planningReportPDF(
            title: "Conjunction screening — \(primary.name) / \(secondary.name)",
            subtitle: "Public GP awareness screen · \(String(format: "%.0f", hours)) h · threshold \(String(format: "%.0f", thresholdKm)) km · not collision-avoidance data",
            csvText: conjunctionsCSV(events, primary: primary, secondary: secondary,
                                     hours: hours, thresholdKm: thresholdKm)
        )
    }

    static func orbitalNeighborhoodCSV(
        _ neighbors: [OrbitalNeighbor],
        primary: SatelliteRecord,
        at date: Date
    ) -> String {
        var rows = [["primary", "neighbor", "norad", "time_utc", "range_km", "relative_velocity_km_s"]]
        rows += neighbors.map {
            [primary.name, $0.name, String($0.id), human(date),
             String(format: "%.3f", $0.rangeKm), String(format: "%.5f", $0.relativeVelocityKmS)]
        }
        return csv(rows)
    }

    static func radioPlaybookCSV(
        _ rowsIn: [RadioPlaybookRow],
        satellite: SatelliteRecord,
        transponder: TransponderRecord,
        hold: String
    ) -> String {
        var rows = [["satellite", "transponder", "time_utc", "az_deg", "el_deg", "range_rate_km_s", "rx_hz", "tx_hz", "mode", "hold"]]
        rows += rowsIn.map {
            [satellite.name, transponder.description.isEmpty ? transponder.kind : transponder.description,
             human($0.date), String(format: "%.2f", $0.azimuthDegrees),
             String(format: "%.2f", $0.elevationDegrees), String(format: "%+.5f", $0.rangeRateKmS),
             String($0.receiveHz), $0.transmitHz > 0 ? String($0.transmitHz) : "", $0.mode, hold]
        }
        return csv(rows)
    }

    static func radioPlaybookPDF(
        _ rows: [RadioPlaybookRow],
        satellite: SatelliteRecord,
        transponder: TransponderRecord,
        hold: String,
        pass: PredictedPass
    ) -> Data {
        planningReportPDF(
            title: "\(satellite.name) — Doppler playbook",
            subtitle: "\(transponder.description.isEmpty ? transponder.kind : transponder.description) · \(hold == "uplink" ? "fixed uplink" : "fixed downlink") · pass AOS \(human(pass.aos)) UTC",
            csvText: radioPlaybookCSV(rows, satellite: satellite, transponder: transponder, hold: hold)
        )
    }

    static func satelliteEclipseCSV(
        periods: [SatelliteEclipsePeriod],
        daily: [SatelliteEclipseDailySummary],
        satellite: SatelliteRecord
    ) -> String {
        var rows = [["satellite", "enter_utc", "exit_utc", "duration_s", "interval_from_previous_s", "beta_deg"]]
        var previousExit: Date?
        for p in periods {
            let interval = previousExit.map { String(format: "%.1f", p.enter.timeIntervalSince($0)) } ?? ""
            rows.append([satellite.name, human(p.enter), human(p.exit),
                         String(format: "%.1f", p.durationSeconds), interval,
                         String(format: "%+.3f", p.betaAngleDegrees)])
            previousExit = p.exit
        }
        rows.append([])
        rows.append(["date_utc", "eclipses", "total_s", "longest_s", "percent_of_day", "beta_deg"])
        rows += daily.map {
            [String(human($0.date).prefix(10)), String($0.count),
             String(format: "%.1f", $0.totalSeconds), String(format: "%.1f", $0.longestSeconds),
             String(format: "%.3f", $0.percentOfDay), String(format: "%+.3f", $0.betaAngleDegrees)]
        }
        return csv(rows)
    }

    static func satelliteEclipsePDF(
        periods: [SatelliteEclipsePeriod],
        daily: [SatelliteEclipseDailySummary],
        satellite: SatelliteRecord,
        days: Int
    ) -> Data {
        planningReportPDF(
            title: "\(satellite.name) — eclipse ephemeris",
            subtitle: "Umbral Earth-shadow planning · next \(days) day\(days == 1 ? "" : "s") · beta angle is orbit-plane/Sun geometry",
            csvText: satelliteEclipseCSV(periods: periods, daily: daily, satellite: satellite)
        )
    }

    static func newLaunchesCSV(_ hits: [NewLaunchHit]) -> String {
        var rows = [["object", "norad", "downlink_hz", "mode", "transmitters", "already_in_catalog"]]
        rows += hits.map {
            [$0.name, String($0.id), $0.downlinkHz > 0 ? String($0.downlinkHz) : "",
             $0.mode, String($0.transmitterCount), $0.alreadyInCatalog ? "yes" : "no"]
        }
        return csv(rows)
    }

    static func newLaunchesPDF(_ hits: [NewLaunchHit]) -> Data {
        planningReportPDF(
            title: "New launches with documented transmitters",
            subtitle: "CelesTrak last-30-days × SatNOGS transmitter database · user-initiated discovery",
            csvText: newLaunchesCSV(hits)
        )
    }

}

