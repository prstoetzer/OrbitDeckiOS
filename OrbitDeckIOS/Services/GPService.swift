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
            if let o = preferences.amsatURLOverride, !o.isEmpty { return try httpsURL(o) }
            return amsatURL
        case .celestrak:
            if let o = preferences.celestrakURLOverride, !o.isEmpty { return try httpsURL(o) }
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

    /// The default URL for a source (what an override replaces).
    static func defaultURLString(_ preferences: StorePreferences) -> String {
        switch preferences.sourceKind {
        case .amsat: return amsatURL.absoluteString
        case .celestrak: return celestrakBase + preferences.celestrakGroup
        case .custom: return ""
        }
    }

    private static func httpsURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host != nil else { throw GPServiceError.invalidURL }
        return url
    }

    static func fetch(preferences: StorePreferences) async throws -> (records: [SatelliteRecord], rawData: Data, skipped: Int) {
        let url = try sourceURL(preferences: preferences)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GPServiceError.badResponse(http.statusCode)
        }
        let parsed = try parseCounting(data: data)
        return (parsed.records, data, parsed.skipped)
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

    /// Refresh extras that live under a SatNOGS placeholder NORAD number from
    /// SatNOGS's own TLE feed (one sat_id lookup each). Failures keep the cached
    /// snapshot.
    static func fetchSatNOGSExtras(_ definitions: [ManualSatelliteDefinition]) async -> [SatelliteRecord] {
        var output: [SatelliteRecord] = []
        for definition in definitions {
            guard let satID = definition.satnogsID,
                  let tle = try? await TransponderService.fetchTLE(satID: satID),
                  let record = satNOGSRecord(tle, name: definition.name) else { continue }
            output.append(record)
        }
        return output
    }

    /// Build a record from a SatNOGS TLE (the NORAD field holds SatNOGS's
    /// placeholder number for objects with six-digit catalog numbers).
    static func satNOGSRecord(_ tle: SatNOGSTLE, name: String) -> SatelliteRecord? {
        guard var record = parseTLEText("\(name)\n\(tle.line1)\n\(tle.line2)").first else { return nil }
        record.name = name
        return record
    }

    static func parse(data: Data) throws -> [SatelliteRecord] {
        try parseCounting(data: data).records
    }

    /// Like `parse(data:)`, but also reports how many rows were skipped as
    /// malformed (missing or non-finite elements, out-of-range IDs), so callers can
    /// surface the count instead of silently dropping them.
    static func parseCounting(data: Data) throws -> (records: [SatelliteRecord], skipped: Int) {
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
        return (records, rows.count - records.count)
    }

    static func parseTLEText(_ text: String) -> [SatelliteRecord] {
        parseTLETextCounting(text).records
    }

    static func parseTLETextCounting(_ text: String) -> (records: [SatelliteRecord], skipped: Int) {
        let tuples = preProcessTLEs(text)
        let records: [SatelliteRecord] = tuples.compactMap { tuple in
            // Reject lines that fail the TLE mod-10 checksum so corrupted rows
            // don't slip through as plausible-but-wrong elements.
            guard tleLineChecksumValid(tuple.1), tleLineChecksumValid(tuple.2) else { return nil }
            do {
                let parsed = try Elements(tuple.0, tuple.1, tuple.2)
                // SatelliteKit's TLE parser builds BSTAR's exponent from the raw byte
                // value ("4" → 52), so its drag term is effectively zero, and it keeps
                // the Kozai mean motion internal. Read both from the text and rebuild
                // the elements so SGP4 and the record both get the real values.
                let meanMotion = tleMeanMotion(tuple.2) ?? parsed.n₀ * 1440.0 / (2.0 * .pi)
                let bstar = tleBstar(tuple.1) ?? 0
                let elements = Elements(
                    commonName: parsed.commonName, noradIndex: parsed.noradIndex, launchName: parsed.launchName,
                    t₀: Date(ds1950: parsed.t₀), e₀: parsed.e₀,
                    i₀: parsed.i₀ * 180.0 / .pi, ω₀: parsed.ω₀ * 180.0 / .pi,
                    Ω₀: parsed.Ω₀ * 180.0 / .pi, M₀: parsed.M₀ * 180.0 / .pi, n₀: meanMotion,
                    ephemType: parsed.ephemType, tleClass: parsed.tleClass, tleNumber: parsed.tleNumber,
                    revNumber: parsed.revNumber, dragCoeff: bstar)
                return record(from: elements, meanMotion: meanMotion, bstar: bstar)
            } catch {
                return nil
            }
        }
        return (records, tuples.count - records.count)
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
        parseElementTextCounting(text).records
    }

    /// `parseElementText`, also reporting how many malformed entries were skipped.
    static func parseElementTextCounting(_ text: String) -> (records: [SatelliteRecord], skipped: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 0) }

        // OMM JSON (array of objects, or a single object).
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8), let parsed = try? parseCounting(data: data) {
                return parsed
            }
            return ([], 0)
        }

        // OMM XML (CCSDS). CelesTrak's FORMAT=xml emits a run of <omm> segments.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<?xml") || lower.contains("<omm") || lower.contains("<segment") || lower.contains("<ndm") {
            let parsed = parseOMMXMLCounting(text)
            if !parsed.records.isEmpty { return parsed }
        }

        // OMM CSV: a header row naming the standard OMM fields.
        if let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) {
            let upper = firstLine.uppercased()
            if firstLine.contains(","),
               upper.contains("MEAN_MOTION") || upper.contains("NORAD_CAT_ID") || upper.contains("OBJECT_NAME") {
                let parsed = parseOMMCSVCounting(text)
                if !parsed.records.isEmpty { return parsed }
            }
        }

        // Fall back to classic TLE.
        return parseTLETextCounting(text)
    }

    static func parseOMMXML(_ text: String) -> [SatelliteRecord] {
        parseOMMXMLCounting(text).records
    }

    static func parseOMMXMLCounting(_ text: String) -> (records: [SatelliteRecord], skipped: Int) {
        var body = text
        // XML declarations can't sit inside our synthetic wrapper element, and a
        // CelesTrak XML dump has many <omm> roots, so strip declarations and wrap.
        if let regex = try? NSRegularExpression(pattern: "<\\?xml.*?\\?>", options: [.dotMatchesLineSeparators]) {
            body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        }
        let wrapped = "<gpimport>\(body)</gpimport>"
        guard let data = wrapped.data(using: .utf8) else { return ([], 0) }
        let delegate = OMMXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return ([], 0) }
        let records = delegate.rows.compactMap(parseOMM)
        return (records, delegate.rows.count - records.count)
    }

    static func parseOMMCSV(_ text: String) -> [SatelliteRecord] {
        parseOMMCSVCounting(text).records
    }

    static func parseOMMCSVCounting(_ text: String) -> (records: [SatelliteRecord], skipped: Int) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return ([], 0) }
        let headers = splitCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces) }
        var rows: [[String: Any]] = []
        var badLines = 0
        for line in lines.dropFirst() {
            let fields = splitCSVLine(line)
            guard fields.count == headers.count else { badLines += 1; continue }
            var row: [String: Any] = [:]
            for (header, value) in zip(headers, fields) {
                let trimmedValue = value.trimmingCharacters(in: .whitespaces)
                if !trimmedValue.isEmpty { row[header] = trimmedValue }
            }
            rows.append(row)
        }
        let records = rows.compactMap(parseOMM)
        return (records, badLines + rows.count - records.count)
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

    /// Line 2 columns 53–63: mean motion (rev/day, Kozai), when finite and positive.
    static func tleMeanMotion(_ line2: String) -> Double? {
        let c = Array(line2)
        guard c.count >= 63, let v = Double(String(c[52..<63]).trimmingCharacters(in: .whitespaces)),
              v.isFinite, v > 0 else { return nil }
        return v
    }

    /// Line 1 columns 54–61: BSTAR in TLE notation (±mmmmm±e, i.e. ±0.mmmmm × 10^±e).
    static func tleBstar(_ line1: String) -> Double? {
        let c = Array(line1)
        guard c.count >= 61 else { return nil }
        let mantissa = String(c[54..<59]).trimmingCharacters(in: .whitespaces)
        guard !mantissa.isEmpty, let digits = Double("0." + mantissa.replacingOccurrences(of: " ", with: "0")),
              let exponent = Int(String(c[60])) else { return nil }
        let sign: Double = c[53] == "-" ? -1 : 1
        let expSign: Double = c[59] == "-" ? -1 : 1
        let v = sign * digits * pow(10, expSign * Double(exponent))
        return v.isFinite ? v : nil
    }

    private static func record(from elements: Elements, meanMotion: Double, bstar: Double) -> SatelliteRecord {
        let epoch = Date(ds1950: elements.t₀)
        let mm = meanMotion
        let drag = bstar
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
            bstar: drag,
            elements: elements
        )
    }

    /// Valid NORAD catalog numbers (OMM allows up to nine digits).
    static let noradRange: ClosedRange<Int> = 1...999_999_999

    /// Parse one OMM row. Returns nil (the row is skipped and counted by the
    /// callers) when a required element is missing, any numeric field is
    /// non-finite ("nan", "inf") or out of range ("1e30"), so a malformed row
    /// can never trap in an integer conversion or feed garbage to SGP4.
    static func parseOMM(_ row: [String: Any]) -> SatelliteRecord? {
        do {
            return try parseOMMChecked(row)
        } catch {
            return nil
        }
    }

    private struct MalformedField: Error {}

    private static func parseOMMChecked(_ row: [String: Any]) throws -> SatelliteRecord? {
        guard let noradInt = try int(row, "NORAD_CAT_ID", "NORAD_CATID", "CATNR", range: noradRange),
              let norad = UInt(exactly: noradInt),
              let epoch = date(row, "EPOCH"), epoch.timeIntervalSince1970.isFinite,
              let meanMotion = try finite(row, "MEAN_MOTION"), meanMotion > 0,
              let eccentricity = try finite(row, "ECCENTRICITY"), (0..<1).contains(eccentricity),
              let inclination = try finite(row, "INCLINATION"),
              let raan = try finite(row, "RA_OF_ASC_NODE", "RAAN"),
              let argp = try finite(row, "ARG_OF_PERICENTER", "ARG_OF_PERIGEE"),
              let meanAnomaly = try finite(row, "MEAN_ANOMALY") else {
            return nil
        }

        // Prefer AMSAT's amateur designation (e.g. "AO-07") when present in the
        // AMSAT daily bulletin; fall back to the generic catalog name otherwise.
        let name = string(row, "AMSAT_NAME", "OBJECT_NAME", "OBJECT") ?? "NORAD \(norad)"
        let intl = string(row, "OBJECT_ID", "INTLDES") ?? ""
        let bstar = try finite(row, "BSTAR") ?? 0
        let ephemeris = try int(row, "EPHEMERIS_TYPE", range: 0...99) ?? 0
        let classification = string(row, "CLASSIFICATION_TYPE", "CLASSIFICATION") ?? "U"
        let elementSet = try int(row, "ELEMENT_SET_NO", "ELSET_NO", range: 0...999_999_999) ?? 0
        let rev = try int(row, "REV_AT_EPOCH", range: 0...999_999_999) ?? 0

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

    /// A numeric field that must be finite when present: nil when absent (or not
    /// a number, as before), throws for "nan"/"inf" and overflowing values.
    private static func finite(_ row: [String: Any], _ keys: String...) throws -> Double? {
        try finite(row, keys: keys)
    }

    /// An integer field: nil when absent; throws when non-finite, non-integral
    /// after rounding to a representable value, or outside `range`.
    private static func int(_ row: [String: Any], _ keys: String..., range: ClosedRange<Int>) throws -> Int? {
        guard let value = try finite(row, keys: keys) else { return nil }
        let rounded = value.rounded()
        guard rounded >= Double(range.lowerBound), rounded <= Double(range.upperBound),
              let result = Int(exactly: rounded), range.contains(result) else { throw MalformedField() }
        return result
    }

    private static func finite(_ row: [String: Any], keys: [String]) throws -> Double? {
        guard let value = double(row, keys: keys) else { return nil }
        guard value.isFinite else { throw MalformedField() }
        return value
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

/// An element set the operator imported (OMM or TLE), persisted in an on-disk
/// overlay next to the GP cache so it survives relaunches and refreshes. It wins
/// over the downloaded feed only while its epoch is newer than the feed's for the
/// same NORAD ID; once the feed catches up the entry is pruned.
struct ImportedElementSet: Identifiable, Codable, Equatable, Sendable {
    var definition: ManualSatelliteDefinition
    var importedAt: Date

    var id: UInt { definition.norad }
    var norad: UInt { definition.norad }
    var epoch: Date { definition.epoch }
    var name: String { definition.name }

    init(record: SatelliteRecord, importedAt: Date = .now) {
        self.definition = ManualSatelliteDefinition(record: record)
        self.importedAt = importedAt
    }

    /// A catalog record (not flagged manual) built from the stored elements.
    var record: SatelliteRecord { GPService.makeExtraRecord(definition) }

    /// Split the overlay against the epochs of the downloaded feed: an entry stays
    /// active when the feed lacks that NORAD ID or carries an OLDER epoch; it is
    /// superseded (and can be pruned) once the feed's epoch is the same or newer.
    static func resolve(_ overlay: [ImportedElementSet], feedEpochs: [UInt: Date])
        -> (active: [ImportedElementSet], superseded: [ImportedElementSet]) {
        var active: [ImportedElementSet] = []
        var superseded: [ImportedElementSet] = []
        for entry in overlay {
            if let feedEpoch = feedEpochs[entry.norad], feedEpoch >= entry.epoch {
                superseded.append(entry)
            } else {
                active.append(entry)
            }
        }
        return (active, superseded)
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
