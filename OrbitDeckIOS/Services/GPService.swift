import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SatelliteKit

/// App-wide metadata read from the bundle so version strings never drift out of
/// sync with the project's marketing version.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// User-Agent for requests to external feeds (some reject non-browser agents,
    /// but our own services identify with this).
    static var userAgent: String { "OrbitDeck-iOS/\(version)" }
}

enum GPServiceError: LocalizedError {
    case invalidURL
    case badResponse(Int)
    case invalidJSON
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The GP source URL is invalid."
        case .badResponse(let code): "The GP server returned HTTP \(code)."
        case .invalidJSON: "The GP source did not contain recognizable OMM/GP JSON."
        case .emptyCatalog: "No usable orbital elements were found in the GP data."
        }
    }
}

struct CelesTrakGroup: Identifiable, Sendable {
    let name: String
    let id: String
}

struct GPService {
    static let amsatURL = URL(string: "https://newark192.amsat.org/gpdata/current/daily-bulletin.json")!
    static let celestrakBase = "https://celestrak.org/NORAD/elements/gp.php?FORMAT=json&GROUP="

    static let celestrakGroups: [CelesTrakGroup] = [
        .init(name: "Amateur Radio", id: "amateur"),
        .init(name: "CubeSats", id: "cubesat"),
        .init(name: "Space Stations", id: "stations"),
        .init(name: "Last 30 Days' Launches", id: "last-30-days"),
        .init(name: "Active Satellites", id: "active"),
        .init(name: "Weather", id: "weather"),
        .init(name: "NOAA", id: "noaa"),
        .init(name: "GOES", id: "goes"),
        .init(name: "Earth Resources", id: "resource"),
        .init(name: "Galileo", id: "galileo"),
        .init(name: "GPS Operational", id: "gps-ops"),
        .init(name: "Science", id: "science"),
        .init(name: "Geostationary", id: "geo"),
        .init(name: "Debris: Fengyun-1C", id: "1999-025"),
        .init(name: "Debris: Iridium-33", id: "iridium-33-debris"),
        .init(name: "Debris: Cosmos-2251", id: "cosmos-2251-debris"),
        .init(name: "Debris: Cosmos-1408", id: "cosmos-1408-debris"),
        .init(name: "Analyst Satellites", id: "analyst")
    ]

    static func sourceURL(preferences: StorePreferences) throws -> URL {
        switch preferences.sourceKind {
        case .amsat:
            return amsatURL
        case .celestrak:
            guard let url = URL(string: celestrakBase + preferences.celestrakGroup) else {
                throw GPServiceError.invalidURL
            }
            return url
        case .custom:
            guard let url = URL(string: preferences.customURL),
                  let scheme = url.scheme,
                  scheme.lowercased() == "https" else {
                throw GPServiceError.invalidURL
            }
            return url
        }
    }

    static func fetch(preferences: StorePreferences) async throws -> (records: [SatelliteRecord], rawData: Data) {
        let url = try sourceURL(preferences: preferences)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GPServiceError.badResponse(http.statusCode)
        }
        let records = try parse(data: data)
        return (records, data)
    }


    static func makeManualRecord(_ definition: ManualSatelliteDefinition) -> SatelliteRecord {
        let elements = Elements(
            commonName: definition.name,
            noradIndex: definition.norad,
            launchName: definition.internationalDesignator,
            t₀: definition.epoch,
            e₀: definition.eccentricity,
            i₀: definition.inclinationDeg,
            ω₀: definition.argumentOfPerigeeDeg,
            Ω₀: definition.raanDeg,
            M₀: definition.meanAnomalyDeg,
            n₀: definition.meanMotionRevPerDay,
            ephemType: 0,
            tleClass: "U",
            tleNumber: 0,
            revNumber: 0,
            dragCoeff: definition.bstar
        )
        return SatelliteRecord(
            id: definition.norad,
            name: definition.name,
            internationalDesignator: definition.internationalDesignator,
            epoch: definition.epoch,
            meanMotionRevPerDay: definition.meanMotionRevPerDay,
            eccentricity: definition.eccentricity,
            inclinationDeg: definition.inclinationDeg,
            raanDeg: definition.raanDeg,
            argumentOfPerigeeDeg: definition.argumentOfPerigeeDeg,
            meanAnomalyDeg: definition.meanAnomalyDeg,
            bstar: definition.bstar,
            elements: elements,
            isManual: true
        )
    }


    static func makeExtraRecord(_ definition: ManualSatelliteDefinition) -> SatelliteRecord {
        var record = makeManualRecord(definition)
        record.isManual = false
        return record
    }

    static func fetchExtraNorads(_ norads: [UInt]) async -> [SatelliteRecord] {
        var output: [SatelliteRecord] = []
        for norad in norads.sorted() {
            guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(norad)&FORMAT=json") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let records = try? parse(data: data), let first = records.first else { continue }
                output.append(first)
            } catch {
                continue
            }
        }
        return output
    }

    static func parse(data: Data) throws -> [SatelliteRecord] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dict = object as? [String: Any] {
            rows = [dict]
        } else {
            throw GPServiceError.invalidJSON
        }

        let records = rows.compactMap(parseOMM)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !records.isEmpty else { throw GPServiceError.emptyCatalog }
        return records
    }

    static func parseTLEText(_ text: String) -> [SatelliteRecord] {
        preProcessTLEs(text).compactMap { tuple in
            // Reject lines that fail the TLE mod-10 checksum so corrupted rows
            // don't slip through as plausible-but-wrong elements.
            guard tleLineChecksumValid(tuple.1), tleLineChecksumValid(tuple.2) else { return nil }
            do {
                let elements = try Elements(tuple.0, tuple.1, tuple.2)
                return record(from: elements)
            } catch {
                return nil
            }
        }
    }

    /// Standard TLE checksum: digits in columns 1–68 sum (with '-' counting as 1)
    /// modulo 10 must equal the column-69 check digit. Non-standard-length lines
    /// are left for the element parser to accept or reject.
    private static func tleLineChecksumValid(_ line: String) -> Bool {
        let chars = Array(line)
        guard chars.count >= 69, let expected = chars[68].wholeNumberValue else { return true }
        var sum = 0
        for c in chars[0..<68] {
            if let d = c.wholeNumberValue { sum += d }
            else if c == "-" { sum += 1 }
        }
        return sum % 10 == expected
    }

    /// Auto-detects the element format of an imported file and returns the
    /// parsed satellites. Modern GP data is distributed as OMM in JSON, XML
    /// (CCSDS), or CSV; classic two/three-line TLE text is still accepted for
    /// backward compatibility.
    static func parseElementText(_ text: String) -> [SatelliteRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // OMM JSON (array of objects, or a single object).
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8), let records = try? parse(data: data) {
                return records
            }
            return []
        }

        // OMM XML (CCSDS). CelesTrak's FORMAT=xml emits a run of <omm> segments.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<?xml") || lower.contains("<omm") || lower.contains("<segment") || lower.contains("<ndm") {
            let records = parseOMMXML(text)
            if !records.isEmpty { return records }
        }

        // OMM CSV: a header row naming the standard OMM fields.
        if let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) {
            let upper = firstLine.uppercased()
            if firstLine.contains(","),
               upper.contains("MEAN_MOTION") || upper.contains("NORAD_CAT_ID") || upper.contains("OBJECT_NAME") {
                let records = parseOMMCSV(text)
                if !records.isEmpty { return records }
            }
        }

        // Fall back to classic TLE.
        return parseTLEText(text)
    }

    static func parseOMMXML(_ text: String) -> [SatelliteRecord] {
        var body = text
        // XML declarations can't sit inside our synthetic wrapper element, and a
        // CelesTrak XML dump has many <omm> roots, so strip declarations and wrap.
        if let regex = try? NSRegularExpression(pattern: "<\\?xml.*?\\?>", options: [.dotMatchesLineSeparators]) {
            body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        }
        let wrapped = "<gpimport>\(body)</gpimport>"
        guard let data = wrapped.data(using: .utf8) else { return [] }
        let delegate = OMMXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.rows.compactMap(parseOMM)
    }

    static func parseOMMCSV(_ text: String) -> [SatelliteRecord] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return [] }
        let headers = splitCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces) }
        var rows: [[String: Any]] = []
        for line in lines.dropFirst() {
            let fields = splitCSVLine(line)
            guard fields.count == headers.count else { continue }
            var row: [String: Any] = [:]
            for (header, value) in zip(headers, fields) {
                let trimmedValue = value.trimmingCharacters(in: .whitespaces)
                if !trimmedValue.isEmpty { row[header] = trimmedValue }
            }
            rows.append(row)
        }
        return rows.compactMap(parseOMM)
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = next
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        result.append(current)
        return result
    }

    private static func record(from elements: Elements) -> SatelliteRecord {
        let epoch = Date(ds1950: elements.t₀)
        let mm = elements.n₀ * 1440.0 / (2.0 * .pi)
        return SatelliteRecord(
            id: elements.noradIndex,
            name: elements.commonName,
            internationalDesignator: elements.launchName,
            epoch: epoch,
            meanMotionRevPerDay: mm,
            eccentricity: elements.e₀,
            inclinationDeg: elements.i₀ * 180.0 / .pi,
            raanDeg: elements.Ω₀ * 180.0 / .pi,
            argumentOfPerigeeDeg: elements.ω₀ * 180.0 / .pi,
            meanAnomalyDeg: elements.M₀ * 180.0 / .pi,
            bstar: 0,
            elements: elements
        )
    }

    static func parseOMM(_ row: [String: Any]) -> SatelliteRecord? {
        guard let norad = uint(row, "NORAD_CAT_ID", "NORAD_CATID", "CATNR"),
              let epoch = date(row, "EPOCH"),
              let meanMotion = double(row, "MEAN_MOTION"),
              let eccentricity = double(row, "ECCENTRICITY"),
              let inclination = double(row, "INCLINATION"),
              let raan = double(row, "RA_OF_ASC_NODE", "RAAN"),
              let argp = double(row, "ARG_OF_PERICENTER", "ARG_OF_PERIGEE"),
              let meanAnomaly = double(row, "MEAN_ANOMALY") else {
            return nil
        }

        // Prefer AMSAT's amateur designation (e.g. "AO-07") when present in the
        // AMSAT daily bulletin; fall back to the generic catalog name otherwise.
        let name = string(row, "AMSAT_NAME", "OBJECT_NAME", "OBJECT") ?? "NORAD \(norad)"
        let intl = string(row, "OBJECT_ID", "INTLDES") ?? ""
        let bstar = double(row, "BSTAR") ?? 0
        let ephemeris = int(row, "EPHEMERIS_TYPE") ?? 0
        let classification = string(row, "CLASSIFICATION_TYPE", "CLASSIFICATION") ?? "U"
        let elementSet = int(row, "ELEMENT_SET_NO", "ELSET_NO") ?? 0
        let rev = int(row, "REV_AT_EPOCH") ?? 0

        let elements = Elements(
            commonName: name,
            noradIndex: norad,
            launchName: intl,
            t₀: epoch,
            e₀: eccentricity,
            i₀: inclination,
            ω₀: argp,
            Ω₀: raan,
            M₀: meanAnomaly,
            n₀: meanMotion,
            ephemType: ephemeris,
            tleClass: classification,
            tleNumber: elementSet,
            revNumber: rev,
            dragCoeff: bstar
        )

        return SatelliteRecord(
            id: norad,
            name: name,
            internationalDesignator: intl,
            epoch: epoch,
            meanMotionRevPerDay: meanMotion,
            eccentricity: eccentricity,
            inclinationDeg: inclination,
            raanDeg: raan,
            argumentOfPerigeeDeg: argp,
            meanAnomalyDeg: meanAnomaly,
            bstar: bstar,
            elements: elements
        )
    }

    private static func string(_ row: [String: Any], _ keys: String...) -> String? {
        string(row, keys: keys)
    }

    private static func string(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = row[key] as? String, !s.isEmpty { return s }
            if let n = row[key] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func double(_ row: [String: Any], _ keys: String...) -> Double? {
        double(row, keys: keys)
    }

    private static func double(_ row: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let n = row[key] as? NSNumber { return n.doubleValue }
            if let s = row[key] as? String,
               let value = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    private static func int(_ row: [String: Any], _ keys: String...) -> Int? {
        guard let value = double(row, keys: keys) else { return nil }
        return Int(value.rounded())
    }

    private static func uint(_ row: [String: Any], _ keys: String...) -> UInt? {
        guard let value = double(row, keys: keys), value >= 0 else { return nil }
        return UInt(value.rounded())
    }

    private static func date(_ row: [String: Any], _ keys: String...) -> Date? {
        guard let raw = string(row, keys: keys) else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: normalized) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: normalized) { return date }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }
}

/// Flattens each CCSDS OMM `<segment>` (one satellite) into a leaf-name → value
/// dictionary compatible with `GPService.parseOMM`.
private final class OMMXMLCollector: NSObject, XMLParserDelegate {
    private(set) var rows: [[String: Any]] = []
    private var current: [String: Any] = [:]
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { current[elementName] = text }
        buffer = ""
        // A <segment> bounds one OMM; some feeds omit it, so <omm> also finalizes.
        if elementName == "segment" || elementName == "omm" {
            if !current.isEmpty {
                rows.append(current)
                current = [:]
            }
        }
    }
}
