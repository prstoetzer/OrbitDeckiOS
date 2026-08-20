import Foundation

// MARK: - CardSat / OrbitDeck Tiny BASIC deep-parity engine

/// Immutable live-data bridge used by Tiny BASIC.  The interpreter itself has
/// no dependency on SwiftUI or OrbitStore, matching the desktop separation
/// between tinybasic.py and basichost.py.
struct TinyBasicHostContext: Sendable {
    var observer: ObserverSite
    var satellites: [SatelliteRecord]
    var selectedNorad: UInt?
    var favorites: Set<UInt>
    var weather: SpaceWeatherSnapshot?
    var minimumElevation: Double
    var now: Date

    static let systemNames: [String] = (
        "SATAZ SATEL SATRNG SATRR SATLAT SATLON SATALT SATSUN SATINC SATECC " +
        "SATRAAN SATMM SATNOR AOSIN LOSIN PASSEL PASSVIS SUNAZ SUNEL MOONAZ " +
        "MOONEL MYLAT MYLON MYALT UTCH UTCM UTCS UTCDAY UTCMON UTCYR SFI KP " +
        "AINDEX NFAV SATOK TIMEOK POSOK WXOK SPWXOK PASSOK NSAT NTX PASSN " +
        "TXDL TXUL TXBW TXINV TXLIN TXOK SSN FLARE BZ SWSPEED MUF FCKP1 FCKP2 FCKP3 MAGDECL " +
        "WXTEMP WXWIND WXDIR WXHUM LSTHR GPSOK GPSSATS GPSSPD GPSLAT GPSLON GPSALT " +
        "BATT BATTMV CHARGING HEAPFREE HEAPBLK GPAGE LSHELL BRATIO BFIELD INBELT INSAA " +
        "DOPPRX DOPPTX DECAYD DECAYSRC UPTIME"
    ).split(separator: " ").map(String.init)

    func snapshot() -> [String: Double] {
        var out = Dictionary(uniqueKeysWithValues: Self.systemNames.map { ($0, 0.0) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute, .second, .day, .month, .year], from: now)
        out["UTCH"] = Double(components.hour ?? 0)
        out["UTCM"] = Double(components.minute ?? 0)
        out["UTCS"] = Double(components.second ?? 0)
        out["UTCDAY"] = Double(components.day ?? 0)
        out["UTCMON"] = Double(components.month ?? 0)
        out["UTCYR"] = Double(components.year ?? 0)
        out["TIMEOK"] = 1
        out["LSTHR"] = localSiderealHours(at: now, longitudeDeg: observer.longitude)
        out["UPTIME"] = 0
        out["MYLAT"] = observer.latitude
        out["MYLON"] = observer.longitude
        out["MYALT"] = observer.altitudeMeters
        out["POSOK"] = 1
        out["NSAT"] = Double(satellites.count)
        out["NFAV"] = Double(favorites.count)

        if let weather {
            var got = false
            if let v = weather.flux { out["SFI"] = v; got = true }
            if let v = weather.kp { out["KP"] = v; got = true }
            if let v = weather.aIndex { out["AINDEX"] = v; got = true }
            if let v = weather.sunspotNumber { out["SSN"] = v; got = true }
            if got {
                out["SPWXOK"] = 1
                out["MUF"] = PropagationEngine.outlook(weather: weather, date: now).dayMUF ?? 0
            }
        }

        let sky = FeatureEngine.sunMoon(site: observer, at: now)
        out["SUNAZ"] = sky.sunAzimuth
        out["SUNEL"] = sky.sunElevation
        out["MOONAZ"] = sky.moonAzimuth
        out["MOONEL"] = sky.moonElevation
        // CardSat obtains magnetic declination from its geomagnetic model.
        // Native OrbitDeck does not bundle IGRF-14, but the centered-dipole
        // geometry already used for the planning-grade belt fields gives a
        // useful compass correction: the initial true bearing toward the
        // modeled geomagnetic north pole, normalized east-positive.
        out["MAGDECL"] = magneticDeclinationApprox(latitude: observer.latitude, longitude: observer.longitude)

        if let selected = selectedSatellite,
           let values = satelliteValues(selected) {
            out.merge(values) { _, new in new }
        }
        return out
    }

    var selectedSatellite: SatelliteRecord? {
        if let selectedNorad, let hit = satellites.first(where: { $0.id == selectedNorad }) { return hit }
        return satellites.first
    }

    func selectSatellite(index: Int) -> (SatelliteRecord, [String: Double])? {
        guard satellites.indices.contains(index) else { return nil }
        let sat = satellites[index]
        guard let values = satelliteValues(sat) else {
            return (sat, ["SATOK": 0, "NTX": Double(sat.transponders.count)])
        }
        return (sat, values)
    }

    func satelliteValues(_ sat: SatelliteRecord) -> [String: Double]? {
        guard let look = try? OrbitPredictor.look(sat, observer: observer, at: now) else { return nil }
        let elementAge = max(0, now.timeIntervalSince(sat.epoch) / 86400.0)
        let geomagnetic = geomagneticSnapshot(latitude: look.subLatitude,
                                              longitude: look.subLongitude,
                                              altitudeKm: look.altitudeKm,
                                              at: now)
        var out: [String: Double] = [
            "SATAZ": look.azimuth,
            "SATEL": look.elevation,
            "SATRNG": look.rangeKm,
            "SATRR": look.rangeRateKmS,
            "SATLAT": look.subLatitude,
            "SATLON": look.subLongitude,
            "SATALT": look.altitudeKm,
            "SATSUN": look.sunlit ? 1 : 0,
            "SATINC": sat.inclinationDeg,
            "SATECC": sat.eccentricity,
            "SATRAAN": sat.raanDeg,
            "SATMM": sat.meanMotionRevPerDay,
            "SATNOR": Double(sat.id),
            "SATOK": 1,
            "NTX": Double(sat.transponders.count),
            "TXOK": 0,
            "GPAGE": elementAge,
            "LSHELL": geomagnetic.lShell,
            "BRATIO": geomagnetic.bRatio,
            "BFIELD": geomagnetic.fieldNT,
            "INBELT": geomagnetic.inBelt ? 1 : 0,
            "INSAA": geomagnetic.inSAA ? 1 : 0,
            // CardSat's DOPPRX/DOPPTX are full CAT dial frequencies, not shifts.
            // They stay zero until TXSEL chooses a transponder.
            "DOPPRX": 0,
            "DOPPTX": 0
        ]
        let decay = OrbitDecayModel.estimate(meanMotion: sat.meanMotionRevPerDay,
                                             ecc: sat.eccentricity,
                                             bstar: sat.bstar, ndot: 0, solar: 1)
        if decay.0 >= 0 {
            out["DECAYD"] = decay.0.isInfinite ? 1e8 : decay.0
            out["DECAYSRC"] = decay.1 == .bstar ? 2 : 1
        }
        if let passes = try? OrbitPredictor.predictPasses(
            sat, observer: observer, from: now,
            minElevation: minimumElevation, maxCount: 8, horizonDays: 10),
           let pass = passes.first {
            out["AOSIN"] = max(0, pass.aos.timeIntervalSince(now) / 60.0)
            out["LOSIN"] = max(0, pass.los.timeIntervalSince(now) / 60.0)
            out["PASSEL"] = pass.maxElevation
            out["PASSOK"] = 1
            out["PASSN"] = Double(passes.count)
            if let tcaLook = try? OrbitPredictor.look(sat, observer: observer, at: pass.tca) {
                let sun = FeatureEngine.sunMoon(site: observer, at: pass.tca)
                out["PASSVIS"] = (tcaLook.sunlit && sun.sunElevation <= -6) ? 1 : 0
            }
        }
        return out
    }

    private func localSiderealHours(at date: Date, longitudeDeg: Double) -> Double {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let t = (jd - 2451545.0) / 36525.0
        var gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t - t * t * t / 38710000.0
        gmst = gmst.truncatingRemainder(dividingBy: 360)
        if gmst < 0 { gmst += 360 }
        var local = (gmst + longitudeDeg).truncatingRemainder(dividingBy: 360)
        if local < 0 { local += 360 }
        return local / 15.0
    }

    private func magneticDeclinationApprox(latitude: Double, longitude: Double) -> Double {
        let d2r = Double.pi / 180
        let lat = latitude * d2r
        let poleLat = 80.7 * d2r
        let dlon = (-72.7 - longitude) * d2r
        let y = sin(dlon) * cos(poleLat)
        let x = cos(lat) * sin(poleLat) - sin(lat) * cos(poleLat) * cos(dlon)
        var bearing = atan2(y, x) * 180 / .pi
        while bearing > 180 { bearing -= 360 }
        while bearing <= -180 { bearing += 360 }
        return bearing
    }

    private func geomagneticSnapshot(latitude: Double, longitude: Double,
                                     altitudeKm: Double, at date: Date)
        -> (lShell: Double, bRatio: Double, fieldNT: Double, inBelt: Bool, inSAA: Bool) {
        let d2r = Double.pi / 180
        let poleLat = 80.7 * d2r, poleLon = -72.7 * d2r
        let lat = latitude * d2r, lon = longitude * d2r
        let c = sin(lat) * sin(poleLat) + cos(lat) * cos(poleLat) * cos(lon - poleLon)
        let mlat = asin(max(-1, min(1, c)))
        let cm = cos(mlat), sm = sin(mlat)
        let radiusRatio = (6371.0 + altitudeKm) / 6371.0
        let lShell = abs(cm) > 1e-6 ? radiusRatio / (cm * cm) : 999
        let bRatio = abs(cm) > 1e-6 ? sqrt(1 + 3 * sm * sm) / pow(cm, 6) : 1e6
        // Centered-dipole field magnitude. Native OrbitDeck does not carry IGRF-14,
        // so this is explicitly the same planning-grade magnetic geometry used by
        // Orbital Zones, not a claim of CardSat's IGRF precision.
        let fieldNT = 31_200.0 * sqrt(1 + 3 * sm * sm) / pow(max(radiusRatio, 1e-6), 3)
        let inBelt = altitudeKm >= 300 && bRatio <= 3 &&
            ((1.2...2.5).contains(lShell) || (3.0...7.0).contains(lShell))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: date)
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let years = Double(year - 2025) + Double(day) / 365.0
        let centerLon = -53.0 - 0.30 * years
        var dlon = longitude - centerLon
        while dlon > 180 { dlon -= 360 }
        while dlon < -180 { dlon += 360 }
        let u = (latitude + 27.0) / 25.0
        let v = dlon / 55.0
        let inSAA = u * u + v * v <= 1
        return (lShell, bRatio, fieldNT, inBelt, inSAA)
    }

    /// CardSat PASSAOS/PASSLOS values are minutes from the BASIC run snapshot;
    /// PASSMAX is degrees. Keep up to eight, matching the firmware host.
    func passSnapshot(_ sat: SatelliteRecord) -> [(aosMinutes: Double, losMinutes: Double, maxElevation: Double)] {
        guard let passes = try? OrbitPredictor.predictPasses(
            sat, observer: observer, from: now, minElevation: minimumElevation,
            maxCount: 8, horizonDays: 10) else { return [] }
        return passes.map { pass in
            (pass.aos.timeIntervalSince(now) / 60.0,
             pass.los.timeIntervalSince(now) / 60.0, pass.maxElevation)
        }
    }

    func transponderValues(_ sat: SatelliteRecord, index: Int) -> [String: Double]? {
        guard sat.transponders.indices.contains(index) else { return nil }
        let tp = sat.transponders[index]
        var out: [String: Double] = [
            "TXDL": Double(tp.downlinkCenter),
            "TXUL": Double(tp.uplinkCenter),
            "TXBW": Double(tp.bandwidth),
            "TXINV": tp.invert ? 1 : 0,
            "TXLIN": tp.isLinear ? 1 : 0,
            "TXOK": 1
        ]
        if let look = try? OrbitPredictor.look(sat, observer: observer, at: now) {
            let beta = (look.rangeRateKmS * 1000.0) / 299_792_458.0
            if tp.downlinkCenter > 0 { out["DOPPRX"] = Double(tp.downlinkCenter) * (1 - beta) }
            if tp.uplinkCenter > 0 { out["DOPPTX"] = Double(tp.uplinkCenter) / (1 - beta) }
        }
        return out
    }
}

private struct BasicLCG: Sendable {
    var state: UInt64
    init(seed: UInt64?) {
        state = seed ?? UInt64(Date().timeIntervalSince1970.bitPattern) ^ 0x9E3779B97F4A7C15
        if state == 0 { state = 0xD1B54A32D192ED03 }
    }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

struct BasicInputPrompt: Sendable, Equatable {
    let label: String
    let variable: String
    let isString: Bool
}

private struct CardSatBasicProgram: Sendable {
    var lines: [(Int, String)] = []
    var immediate: [String] = []

    init(_ source: String) {
        for raw in source.components(separatedBy: .newlines) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            var digits = ""
            var idx = s.startIndex
            while idx < s.endIndex, s[idx].isNumber { digits.append(s[idx]); idx = s.index(after: idx) }
            if !digits.isEmpty, let n = Int(digits) {
                lines.append((n, String(s[idx...]).trimmingCharacters(in: .whitespaces)))
            } else {
                immediate.append(s)
            }
        }
        lines.sort { $0.0 < $1.0 }
    }

    func index(of line: Int) -> Int? { lines.firstIndex { $0.0 == line } }

    func inputPrompts() -> [BasicInputPrompt] {
        var result: [BasicInputPrompt] = []
        for (_, source) in lines {
            for statement in CardSatTinyBasicEngine.splitStatements(source) {
                let trimmed = statement.trimmingCharacters(in: .whitespaces)
                guard trimmed.uppercased().hasPrefix("INPUT") else { continue }
                let body = String(trimmed.dropFirst(5))
                let parts = CardSatTinyBasicEngine.splitArguments(body, separators: [",", ";"])
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                var label = ""
                for part in parts {
                    if part.hasPrefix("\"") { label = CardSatTinyBasicEngine.unquotedLiteral(part) ?? label; continue }
                    let v = part.uppercased()
                    let isString = v.hasSuffix("$")
                    let base = isString ? String(v.dropLast()) : v
                    guard base.count == 1, base.first?.isLetter == true else { continue }
                    result.append(.init(label: label.isEmpty ? v : label, variable: v, isString: isString))
                    label = ""
                }
            }
        }
        return result
    }}

private enum BasicControl {
    case next
    case jump(Int)
    case sameLine(Int)
    case resume(lineIndex: Int, statementIndex: Int)
    case stop
}

private struct BasicReturnRecord {
    let lineIndex: Int
    let statementIndex: Int
}

private struct BasicForRecord {
    let variable: String
    let limit: Double
    let step: Double
    let lineIndex: Int
    let statementIndex: Int
}

/// Source-compatible interpreter for the CardSat/desktop OrbitDeck Tiny BASIC
/// dialect.  File operations are limited to one caller-provided directory.
struct CardSatTinyBasicEngine: Sendable {
    static let width = 240
    static let height = 135
    static let palette = TinyBasicEngine.palette
    static let maxAnonymousArray = 256
    static let maxNamedArray = 1024
    static let maxArrayElements = 2048
    static let maxForDepth = 8
    static let maxGosubDepth = 16

    static func inputPrompts(in source: String) -> [BasicInputPrompt] { CardSatBasicProgram(source).inputPrompts() }

    func run(
        _ source: String,
        inputs: [Double] = [],
        stringInputs: [String] = [],
        host: TinyBasicHostContext? = nil,
        fileDirectory: URL? = nil,
        seed: UInt64? = nil,
        maxSteps: Int = 2_000_000,
        maxSeconds: TimeInterval = 10
    ) throws -> BasicRunResult {
        var vm = BasicVM(program: CardSatBasicProgram(source), inputs: inputs, stringInputs: stringInputs, host: host,
                         fileDirectory: fileDirectory, seed: seed,
                         maxSteps: maxSteps, maxSeconds: maxSeconds)
        return try vm.run()
    }

    // CardSat BASIC addresses DXCC entities by the ARRL numerical entity code,
    // not by the prefix-keyed native Workable table.  Keep the full 340-current-
    // entity roster in DXCCNumericData; deleted entities intentionally return
    // no name/location rather than a plausible-looking 0,0 coordinate.
    fileprivate static func basicDXCCName(code: Int) -> String? {
        DXCCNumericData.nameByCode[code]
    }

    fileprivate static func basicDXCCCoordinate(code: Int) -> DXCCNumericEntity? {
        DXCCNumericData.byCode[code]
    }

    fileprivate static func unquotedLiteral(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\"") else { return nil }
        let rest = t.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return String(rest) }
        return String(rest[..<end])
    }

    fileprivate static func splitStatements(_ source: String) -> [String] {
        var out: [String] = [], current = ""
        var quoted = false, i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            if c == "\"" { quoted.toggle(); current.append(c); i = source.index(after: i); continue }
            if !quoted {
                let remain = source[i...]
                if remain.count >= 3, remain.prefix(3).uppercased() == "REM" {
                    let before = i == source.startIndex ? nil : source[source.index(before: i)]
                    let afterIndex = source.index(i, offsetBy: 3, limitedBy: source.endIndex) ?? source.endIndex
                    let after: Character? = afterIndex < source.endIndex ? source[afterIndex] : nil
                    let beforeOK = before == nil || !(before!.isLetter || before!.isNumber || before! == "_")
                    let afterOK = after == nil || !(after!.isLetter || after!.isNumber || after! == "_")
                    if beforeOK && afterOK { current += String(remain); break }
                }
                if c == ":" { out.append(current); current = ""; i = source.index(after: i); continue }
            }
            current.append(c); i = source.index(after: i)
        }
        out.append(current)
        return out
    }

    fileprivate static func splitArguments(_ text: String, separators: Set<Character> = [","]) -> [String] {
        var out: [String] = [], current = "", depth = 0, quoted = false
        for c in text {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if quoted { current.append(c) }
            else if c == "(" { depth += 1; current.append(c) }
            else if c == ")" { depth -= 1; current.append(c) }
            else if separators.contains(c), depth == 0 { out.append(current); current = "" }
            else { current.append(c) }
        }
        out.append(current)
        return out
    }
}

private struct BasicVM {
    let program: CardSatBasicProgram
    var variables = Dictionary(uniqueKeysWithValues: (0..<26).map { (String(Character(UnicodeScalar(65 + $0)!)), 0.0) })
    var stringVariables = Dictionary(uniqueKeysWithValues: (0..<26).map { (String(Character(UnicodeScalar(65 + $0)!)) + "$", "") })
    var anonymousArray: [Double]?
    var namedArrays: [String: [Double]] = [:]
    var gosubStack: [BasicReturnRecord] = []
    var forStack: [BasicForRecord] = []
    var data: [Double] = []
    var dataPosition = 0
    var inputs: [Double]
    var inputPosition = 0
    var stringInputs: [String]
    var stringInputPosition = 0
    var host: TinyBasicHostContext?
    var selectedHostSatellite: SatelliteRecord?
    var system: [String: Double]
    let fileDirectory: URL?
    var openFileURL: URL?
    var rng: BasicLCG
    let maxSteps: Int
    let maxSeconds: TimeInterval
    var startedAt = Date()
    var result = BasicRunResult()
    var printBuffer = ""
    var passAos: [Double] = []
    var passLos: [Double] = []
    var passMax: [Double] = []
    var currentLineIndex = 0

    init(program: CardSatBasicProgram, inputs: [Double], stringInputs: [String], host: TinyBasicHostContext?, fileDirectory: URL?, seed: UInt64?, maxSteps: Int, maxSeconds: TimeInterval) {
        self.program = program
        self.inputs = inputs
        self.stringInputs = stringInputs
        self.host = host
        self.system = host?.snapshot() ?? Dictionary(uniqueKeysWithValues: TinyBasicHostContext.systemNames.map { ($0, 0.0) })
        self.fileDirectory = fileDirectory
        self.rng = BasicLCG(seed: seed)
        self.maxSteps = maxSteps
        self.maxSeconds = maxSeconds
        if let host, let sat = host.selectedSatellite {
            let passes = host.passSnapshot(sat)
            self.passAos = passes.map(\.aosMinutes)
            self.passLos = passes.map(\.losMinutes)
            self.passMax = passes.map(\.maxElevation)
            self.system["PASSN"] = Double(passes.count)
            self.system["PASSOK"] = passes.isEmpty ? 0 : 1
        }
        for (_, source) in program.lines {
            for statement in CardSatTinyBasicEngine.splitStatements(source) {
                let s = statement.trimmingCharacters(in: .whitespaces)
                guard s.uppercased().hasPrefix("DATA") else { continue }
                for item in CardSatTinyBasicEngine.splitArguments(String(s.dropFirst(4))) {
                    if let value = Double(item.trimmingCharacters(in: .whitespaces)) { self.data.append(value) }
                }
            }
        }
    }

    mutating func run() throws -> BasicRunResult {
        startedAt = .now
        for source in program.immediate {
            if let banned = firstImmediateBanned(source) { throw TinyBasicError.message("\(banned) needs a numbered program", nil) }
        }
        if !program.immediate.isEmpty && program.lines.isEmpty {
            for source in program.immediate {
                let statements = CardSatTinyBasicEngine.splitStatements(source)
                var si = 0
                while si < statements.count {
                    try tick(line: nil)
                    let ctl = try execute(statements[si], lineNumber: nil, lineIndex: 0, statementIndex: si)
                    switch ctl {
                    case .next: si += 1
                    case .stop: return finishResult()
                    default: throw TinyBasicError.message("statement needs a numbered program", nil)
                    }
                }
            }
            return finishResult()
        }

        var lineIndex = 0
        var statementIndex = 0
        while program.lines.indices.contains(lineIndex) {
            currentLineIndex = lineIndex
            let (lineNumber, sourceLine) = program.lines[lineIndex]
            let statements = CardSatTinyBasicEngine.splitStatements(sourceLine)
            if statementIndex >= statements.count { lineIndex += 1; statementIndex = 0; continue }
            try tick(line: lineNumber)
            let control = try execute(statements[statementIndex], lineNumber: lineNumber, lineIndex: lineIndex, statementIndex: statementIndex)
            switch control {
            case .next: statementIndex += 1
            case .jump(let target): lineIndex = target; statementIndex = 0
            case .sameLine(let targetStatement): statementIndex = targetStatement
            case .resume(let targetLine, let targetStatement): lineIndex = targetLine; statementIndex = targetStatement
            case .stop: return finishResult()
            }
        }
        return finishResult()
    }

    mutating func finishResult() -> BasicRunResult {
        if !printBuffer.isEmpty { result.output.append(printBuffer); printBuffer = "" }
        return result
    }

    mutating func tick(line: Int?) throws {
        result.steps += 1
        if result.steps > maxSteps { throw TinyBasicError.message("too many statements (runaway program?)", line) }
        if result.steps & 0x3ff == 0, Date().timeIntervalSince(startedAt) > maxSeconds {
            throw TinyBasicError.message("program ran too long", line)
        }
    }

    mutating func execute(_ statement: String, lineNumber: Int?, lineIndex: Int, statementIndex: Int) throws -> BasicControl {
        let s = statement.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return .next }
        let upper = s.uppercased()
        func keyword(_ word: String) -> Bool {
            guard upper.hasPrefix(word) else { return false }
            guard upper.count > word.count else { return true }
            let i = upper.index(upper.startIndex, offsetBy: word.count)
            return !upper[i].isLetter && !upper[i].isNumber
        }
        if keyword("REM") || keyword("DATA") { return .next }
        if keyword("END") || keyword("STOP") { return .stop }
        if keyword("PRINT") || s.hasPrefix("?") {
            let body = s.hasPrefix("?") ? String(s.dropFirst()) : String(s.dropFirst(5))
            try executePrint(body, line: lineNumber); return .next
        }
        if keyword("LPRINT") { result.output.append("[LPRINT] " + (try render(String(s.dropFirst(6)), line: lineNumber))); return .next }
        if keyword("CLS") { result.graphics.append(.init(kind: .cls, values: [], color: 0, text: "")); return .next }
        if keyword("SHOW") { result.graphics.append(.init(kind: .show, values: [], color: 0, text: "")); return .next }
        if keyword("PSET") {
            let a = try arguments(String(s.dropFirst(4)), line: lineNumber)
            guard (2...3).contains(a.count) else { throw TinyBasicError.message("wrong number of arguments", lineNumber) }
            result.graphics.append(.init(kind: .pset, values: Array(a.prefix(2)), color: a.count > 2 ? Int(a[2]) : 1, text: "")); return .next
        }
        if keyword("LINE") {
            let a = try arguments(String(s.dropFirst(4)), line: lineNumber)
            guard (4...5).contains(a.count) else { throw TinyBasicError.message("wrong number of arguments", lineNumber) }
            result.graphics.append(.init(kind: .line, values: Array(a.prefix(4)), color: a.count > 4 ? Int(a[4]) : 1, text: "")); return .next
        }
        if keyword("CIRCLE") {
            let a = try arguments(String(s.dropFirst(6)), line: lineNumber)
            guard (3...4).contains(a.count) else { throw TinyBasicError.message("wrong number of arguments", lineNumber) }
            result.graphics.append(.init(kind: .circle, values: Array(a.prefix(3)), color: a.count > 3 ? Int(a[3]) : 1, text: "")); return .next
        }
        if keyword("TEXT") { try executeText(String(s.dropFirst(4)), line: lineNumber); return .next }
        if keyword("INPUT") { try executeInput(String(s.dropFirst(5)), line: lineNumber); return .next }
        if keyword("LET") { try assign(String(s.dropFirst(3)), line: lineNumber); return .next }
        if keyword("IF") { return try executeIf(String(s.dropFirst(2)), line: lineNumber, lineIndex: lineIndex, statementIndex: statementIndex) }
        if keyword("GOTO") { return .jump(try jumpTarget(String(s.dropFirst(4)), line: lineNumber)) }
        if keyword("GOSUB") {
            guard gosubStack.count < CardSatTinyBasicEngine.maxGosubDepth else { throw TinyBasicError.message("GOSUB too deep", lineNumber) }
            let statements = CardSatTinyBasicEngine.splitStatements(program.lines[lineIndex].1)
            let nextStatement = statementIndex + 1
            if nextStatement < statements.count {
                gosubStack.append(.init(lineIndex: lineIndex, statementIndex: nextStatement))
            } else {
                gosubStack.append(.init(lineIndex: lineIndex + 1, statementIndex: 0))
            }
            return .jump(try jumpTarget(String(s.dropFirst(5)), line: lineNumber))
        }
        if keyword("RETURN") {
            guard let target = gosubStack.popLast() else { throw TinyBasicError.message("RETURN without GOSUB", lineNumber) }
            return .resume(lineIndex: target.lineIndex, statementIndex: target.statementIndex)
        }
        if keyword("FOR") { try executeFor(String(s.dropFirst(3)), line: lineNumber, lineIndex: lineIndex, statementIndex: statementIndex); return .next }
        if keyword("NEXT") { return try executeNext(line: lineNumber) }
        if keyword("DIM") { try executeDim(String(s.dropFirst(3)), line: lineNumber); return .next }
        if keyword("ERASE") { namedArrays.removeValue(forKey: String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces).prefix(1).uppercased()); return .next }
        if keyword("RESTORE") { dataPosition = 0; return .next }
        if keyword("READ") { try executeRead(String(s.dropFirst(4)), line: lineNumber); return .next }
        if keyword("ON") { return try executeOn(String(s.dropFirst(2)), line: lineNumber) }
        if keyword("FOPEN") { try executeFOpen(String(s.dropFirst(5)), line: lineNumber); return .next }
        if keyword("FPRINT") { try executeFPrint(String(s.dropFirst(6)), line: lineNumber); return .next }
        if keyword("FCLOSE") { openFileURL = nil; return .next }
        if keyword("FILES") { result.output.append(fileList()); return .next }
        if keyword("SATSEL") { try executeSatSel(String(s.dropFirst(6)), line: lineNumber); return .next }
        if keyword("TXSEL") { try executeTxSel(String(s.dropFirst(5)), line: lineNumber); return .next }
        try assign(s, line: lineNumber)
        return .next
    }

    mutating func evaluate(_ text: String, line: Int?) throws -> Double {
        var parser = BasicExpressionParser(text: text, variables: variables, stringVariables: stringVariables,
                                           anonymousArray: anonymousArray, namedArrays: namedArrays, system: system,
                                           passAos: passAos, passLos: passLos, passMax: passMax, rng: rng, line: line)
        let value = try parser.parse()
        rng = parser.rng
        return value
    }

    mutating func evaluateString(_ text: String, line: Int?) throws -> String {
        var parser = BasicExpressionParser(text: text, variables: variables, stringVariables: stringVariables,
                                           anonymousArray: anonymousArray, namedArrays: namedArrays, system: system,
                                           passAos: passAos, passLos: passLos, passMax: passMax, rng: rng, line: line)
        let value = try parser.parseString()
        rng = parser.rng
        return value
    }

    mutating func evaluateCondition(_ text: String, line: Int?) throws -> Double {
        // Current CardSat programs use string relations directly in IF. Locate a
        // top-level relation first so H$ >= "0" does not enter the numeric parser.
        var quoted = false, depth = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { quoted.toggle(); i += 1; continue }
            if !quoted {
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                if depth == 0, "<=>".contains(c) {
                    var op = String(c), width = 1
                    if i + 1 < chars.count {
                        let pair = String([c, chars[i + 1]])
                        if ["<=", ">=", "<>"].contains(pair) { op = pair; width = 2 }
                    }
                    let lhs = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                    let rhs = String(chars[(i + width)...]).trimmingCharacters(in: .whitespaces)
                    if BasicExpressionParser.looksLikeString(lhs) || BasicExpressionParser.looksLikeString(rhs) {
                        let l = try evaluateString(lhs, line: line), r = try evaluateString(rhs, line: line)
                        switch op {
                        case "=": return l == r ? 1 : 0
                        case "<>": return l != r ? 1 : 0
                        case "<": return l < r ? 1 : 0
                        case ">": return l > r ? 1 : 0
                        case "<=": return l <= r ? 1 : 0
                        default: return l >= r ? 1 : 0
                        }
                    }
                    break
                }
            }
            i += 1
        }
        return try evaluate(text, line: line)
    }

    mutating func arguments(_ text: String, line: Int?) throws -> [Double] {
        try CardSatTinyBasicEngine.splitArguments(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try evaluate($0, line: line) }
    }

    mutating func executeText(_ text: String, line: Int?) throws {
        let parts = CardSatTinyBasicEngine.splitArguments(text)
        guard parts.count >= 3 else { throw TinyBasicError.message("TEXT x,y,value", line) }
        let x = try evaluate(parts[0], line: line), y = try evaluate(parts[1], line: line)
        let tail = parts.dropFirst(2).joined(separator: ",").trimmingCharacters(in: .whitespaces)
        let body: String
        if BasicExpressionParser.looksLikeString(tail) {
            body = try evaluateString(tail, line: line)
        } else {
            body = formatNumber(try evaluate(tail, line: line))
        }
        result.graphics.append(.init(kind: .text, values: [x, y], color: 1, text: body))
    }

    mutating func executeInput(_ text: String, line: Int?) throws {
        let parts = CardSatTinyBasicEngine.splitArguments(text, separators: [",", ";"])
        for raw in parts {
            let target = raw.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.hasPrefix("\"") else { continue }
            let upper = target.uppercased()
            if upper.hasSuffix("$") {
                let base = String(upper.dropLast())
                guard base.count == 1, base.first?.isLetter == true else { throw TinyBasicError.message("INPUT variable", line) }
                stringVariables[upper] = stringInputPosition < stringInputs.count ? stringInputs[stringInputPosition] : ""
                stringInputPosition += 1
            } else {
                guard upper.count == 1, upper.first?.isLetter == true else { throw TinyBasicError.message("INPUT variable", line) }
                variables[upper] = inputPosition < inputs.count ? inputs[inputPosition] : 0
                inputPosition += 1
            }
        }
    }

    mutating func assign(_ text: String, line: Int?) throws {
        guard let equals = text.firstIndex(of: "=") else { throw TinyBasicError.message("syntax", line) }
        let lhs = String(text[..<equals]).trimmingCharacters(in: .whitespaces)
        let rhs = String(text[text.index(after: equals)...])
        let upperLHS = lhs.uppercased()
        if upperLHS.hasSuffix("$") {
            let base = String(upperLHS.dropLast())
            guard base.count == 1, base.first?.isLetter == true else { throw TinyBasicError.message("string variable A$-Z$", line) }
            stringVariables[upperLHS] = try evaluateString(rhs, line: line)
            return
        }
        let value = try evaluate(rhs, line: line)
        if lhs.hasPrefix("@"), let inside = parenthesizedBody(String(lhs.dropFirst())) {
            let index = Int(try evaluate(inside, line: line))
            guard var a = anonymousArray, a.indices.contains(index) else { throw TinyBasicError.message("@ index", line) }
            a[index] = value; anonymousArray = a; return
        }
        if lhs.count >= 3, let first = lhs.first, first.isLetter, let inside = parenthesizedBody(String(lhs.dropFirst())) {
            let name = String(first).uppercased(), index = Int(try evaluate(inside, line: line))
            guard var a = namedArrays[name], a.indices.contains(index) else { throw TinyBasicError.message("\(name) index", line) }
            a[index] = value; namedArrays[name] = a; return
        }
        guard lhs.count == 1, lhs.first?.isLetter == true else { throw TinyBasicError.message("unknown name \(lhs)", line) }
        variables[lhs.uppercased()] = value
    }

    mutating func executeIf(_ text: String, line: Int?, lineIndex: Int, statementIndex: Int) throws -> BasicControl {
        guard let r = text.range(of: "THEN", options: [.caseInsensitive]) else { throw TinyBasicError.message("IF without THEN", line) }
        let condition = try evaluateCondition(String(text[..<r.lowerBound]), line: line)
        guard condition != 0 else { return .next }
        let consequent = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let lineNumber = Int(consequent) { return .jump(try jumpTarget(String(lineNumber), line: line)) }
        return try execute(consequent, lineNumber: line, lineIndex: lineIndex, statementIndex: statementIndex)
    }

    mutating func jumpTarget(_ text: String, line: Int?) throws -> Int {
        let first = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard let n = Double(first).map(Int.init), let idx = program.index(of: n) else { throw TinyBasicError.message("line number expected", line) }
        return idx
    }

    mutating func executeFor(_ text: String, line: Int?, lineIndex: Int, statementIndex: Int) throws {
        guard let equals = text.firstIndex(of: "=") else { throw TinyBasicError.message("FOR var A-Z", line) }
        let variable = String(text[..<equals]).trimmingCharacters(in: .whitespaces).uppercased()
        guard variable.count == 1, variable.first?.isLetter == true else { throw TinyBasicError.message("FOR var A-Z", line) }
        let body = String(text[text.index(after: equals)...])
        guard let toRange = body.range(of: "TO", options: [.caseInsensitive]) else { throw TinyBasicError.message("FOR without TO", line) }
        let start = try evaluate(String(body[..<toRange.lowerBound]), line: line)
        let after = String(body[toRange.upperBound...])
        let stepRange = after.range(of: "STEP", options: [.caseInsensitive])
        let limit = try evaluate(stepRange.map { String(after[..<$0.lowerBound]) } ?? after, line: line)
        let step = try evaluate(stepRange.map { String(after[$0.upperBound...]) } ?? "1", line: line)
        guard forStack.count < CardSatTinyBasicEngine.maxForDepth else { throw TinyBasicError.message("FOR too deep", line) }
        variables[variable] = start
        forStack.append(.init(variable: variable, limit: limit, step: step, lineIndex: lineIndex, statementIndex: statementIndex))
    }

    mutating func executeNext(line: Int?) throws -> BasicControl {
        guard let f = forStack.last else { throw TinyBasicError.message("NEXT without FOR", line) }
        variables[f.variable, default: 0] += f.step
        let value = variables[f.variable] ?? 0
        let going = f.step >= 0 ? value <= f.limit : value >= f.limit
        guard going else { _ = forStack.popLast(); return .next }
        let statements = CardSatTinyBasicEngine.splitStatements(program.lines[f.lineIndex].1)
        if f.statementIndex + 1 < statements.count {
            return f.lineIndex == currentLineIndex ? .sameLine(f.statementIndex + 1) : .jump(f.lineIndex)
        }
        return .jump(f.lineIndex + 1)
    }

    mutating func executeDim(_ text: String, line: Int?) throws {
        for part in CardSatTinyBasicEngine.splitArguments(text) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("@"), let body = parenthesizedBody(String(p.dropFirst())) {
                let n = Int(try evaluate(body, line: line))
                guard (1...CardSatTinyBasicEngine.maxAnonymousArray).contains(n) else { throw TinyBasicError.message("@ size 1..\(CardSatTinyBasicEngine.maxAnonymousArray)", line) }
                let namedTotal = namedArrays.values.reduce(0) { $0 + $1.count }
                guard namedTotal + n <= CardSatTinyBasicEngine.maxArrayElements else { throw TinyBasicError.message("arrays too big (2048 total)", line) }
                anonymousArray = Array(repeating: 0, count: n); continue
            }
            guard let name = p.first, name.isLetter, let body = parenthesizedBody(String(p.dropFirst())) else { throw TinyBasicError.message("DIM name", line) }
            let key = String(name).uppercased(), n = Int(try evaluate(body, line: line))
            guard (1...CardSatTinyBasicEngine.maxNamedArray).contains(n) else { throw TinyBasicError.message("array size 1..\(CardSatTinyBasicEngine.maxNamedArray)", line) }
            let other = namedArrays.reduce(0) { $0 + ($1.key == key ? 0 : $1.value.count) }
            let anon = anonymousArray?.count ?? 0
            guard other + anon + n <= CardSatTinyBasicEngine.maxArrayElements else { throw TinyBasicError.message("arrays too big (2048 total)", line) }
            namedArrays[key] = Array(repeating: 0, count: n)
        }
    }

    mutating func executeRead(_ text: String, line: Int?) throws {
        for target in CardSatTinyBasicEngine.splitArguments(text) {
            guard dataPosition < data.count else { throw TinyBasicError.message("out of DATA", line) }
            let value = data[dataPosition]; dataPosition += 1
            try assign("\(target)=\(formatNumber(value))", line: line)
        }
    }

    mutating func executeOn(_ text: String, line: Int?) throws -> BasicControl {
        guard let r = text.range(of: "GOTO", options: [.caseInsensitive]) else { throw TinyBasicError.message("ON..GOTO", line) }
        let selection = Int(try evaluate(String(text[..<r.lowerBound]), line: line))
        let targets = CardSatTinyBasicEngine.splitArguments(String(text[r.upperBound...])).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard selection >= 1, selection <= targets.count else { return .next }
        return .jump(try jumpTarget(targets[selection - 1], line: line))
    }

    mutating func executeSatSel(_ text: String, line: Int?) throws {
        guard let host else { throw TinyBasicError.message("SATSEL needs satellite data", line) }
        let index = Int(try evaluate(text, line: line))
        guard let (sat, values) = host.selectSatellite(index: index) else { throw TinyBasicError.message("bad sat index", line) }
        selectedHostSatellite = sat
        system.merge(values) { _, new in new }
        let passes = host.passSnapshot(sat)
        passAos = passes.map(\.aosMinutes); passLos = passes.map(\.losMinutes); passMax = passes.map(\.maxElevation)
        system["PASSN"] = Double(passes.count); system["PASSOK"] = passes.isEmpty ? 0 : 1
        for name in ["TXDL", "TXUL", "TXBW", "TXINV", "TXLIN", "DOPPRX", "DOPPTX"] { system[name] = 0 }
        system["TXOK"] = 0
    }

    mutating func executeTxSel(_ text: String, line: Int?) throws {
        guard let host else { throw TinyBasicError.message("TXSEL needs satellite data", line) }
        let sat = selectedHostSatellite ?? host.selectedSatellite
        guard let sat else { throw TinyBasicError.message("TXSEL needs satellite data", line) }
        let index = Int(try evaluate(text, line: line))
        guard let values = host.transponderValues(sat, index: index) else { throw TinyBasicError.message("bad tx index", line) }
        system.merge(values) { _, new in new }
    }

    mutating func executeFOpen(_ text: String, line: Int?) throws {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard raw.hasPrefix("\"") else { throw TinyBasicError.message("FOPEN \"name\"", line) }
        let name = unquote(raw)
        guard safeFilename(name), let fileDirectory else { throw TinyBasicError.message(fileDirectory == nil ? "file writing is off" : "bad file name", line) }
        try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        let url = fileDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        openFileURL = url
    }

    mutating func executeFPrint(_ text: String, line: Int?) throws {
        guard let openFileURL else { throw TinyBasicError.message("no file open (FOPEN)", line) }
        let lineText = try render(text, line: line) + "\n"
        guard let data = lineText.data(using: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: openFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    func fileList() -> String {
        guard let fileDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: fileDirectory.path), !names.isEmpty else { return "(no files)" }
        return names.sorted().joined(separator: "\n")
    }

    mutating func executePrint(_ text: String, line: Int?) throws {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { result.output.append(printBuffer); printBuffer = ""; return }
        var current = "", quoted = false, depth = 0
        var items: [(String, Character?)] = []
        for c in text {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if quoted { current.append(c) }
            else if c == "(" { depth += 1; current.append(c) }
            else if c == ")" { depth -= 1; current.append(c) }
            else if (c == "," || c == ";") && depth == 0 { items.append((current, c)); current = "" }
            else { current.append(c) }
        }
        items.append((current, nil))
        var trailingSeparator: Character?
        for (raw, separator) in items {
            let item = raw.trimmingCharacters(in: .whitespaces)
            if !item.isEmpty {
                printBuffer += try renderItem(item, line: line)
                trailingSeparator = nil
            }
            if let separator {
                if separator == "," { printBuffer += "  " }
                trailingSeparator = separator
            }
        }
        if trailingSeparator == nil { result.output.append(printBuffer); printBuffer = "" }
    }

    mutating func renderItem(_ text: String, line: Int?) throws -> String {
        if BasicExpressionParser.looksLikeString(text) {
            return try evaluateString(text, line: line)
        }
        return formatNumber(try evaluate(text, line: line))
    }

    mutating func render(_ text: String, line: Int?) throws -> String {
        var pieces: [String] = []
        for part in CardSatTinyBasicEngine.splitArguments(text, separators: [",", ";"]) {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            pieces.append(try renderItem(p, line: line))
        }
        return pieces.joined()
    }

    func safeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 40, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) }
    }

    func parenthesizedBody(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")") else { return nil }
        return String(t.dropFirst().dropLast())
    }

    func unquote(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\"") else { return t }
        let rest = t.dropFirst()
        if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        return String(rest)
    }

    func formatNumber(_ value: Double) -> String {
        if value.isFinite, abs(value.rounded() - value) < 1e-12, abs(value) < 1e15 { return String(Int64(value.rounded())) }
        return String(format: "%g", value)
    }

    func firstImmediateBanned(_ source: String) -> String? {
        let banned: Set<String> = ["GOTO", "GOSUB", "RETURN", "DATA", "READ", "RESTORE"]
        var token = "", quoted = false
        for c in source + " " {
            if c == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if c.isLetter { token.append(c.uppercased()) }
            else { if banned.contains(token) { return token }; token = "" }
        }
        return nil
    }
}

private struct BasicExpressionParser {
    let text: String
    var index: String.Index
    let variables: [String: Double]
    let stringVariables: [String: String]
    let anonymousArray: [Double]?
    let namedArrays: [String: [Double]]
    let system: [String: Double]
    let passAos: [Double]
    let passLos: [Double]
    let passMax: [Double]
    var rng: BasicLCG
    let line: Int?

    init(text: String, variables: [String: Double], stringVariables: [String: String], anonymousArray: [Double]?, namedArrays: [String: [Double]], system: [String: Double], passAos: [Double], passLos: [Double], passMax: [Double], rng: BasicLCG, line: Int?) {
        self.text = text
        self.index = text.startIndex
        self.variables = variables
        self.stringVariables = stringVariables
        self.anonymousArray = anonymousArray
        self.namedArrays = namedArrays
        self.system = system
        self.passAos = passAos
        self.passLos = passLos
        self.passMax = passMax
        self.rng = rng
        self.line = line
    }

    static func looksLikeString(_ source: String) -> Bool {
        let t = source.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.first == "\"" { return true }
        var name = ""
        for c in t {
            if c.isLetter { name.append(c) }
            else if c == "$" { return !name.isEmpty }
            else { break }
        }
        return false
    }

    mutating func parseString() throws -> String {
        let value = try stringExpression()
        skipWhitespace()
        if index != text.endIndex { throw TinyBasicError.message("unexpected \(text[index])", line) }
        return value
    }

    mutating func stringExpression() throws -> String {
        var value = try stringTerm()
        while true {
            skipWhitespace()
            if eat("+") { value += try stringTerm() } else { return value }
        }
    }

    mutating func stringTerm() throws -> String {
        skipWhitespace()
        guard index < text.endIndex else { throw TinyBasicError.message("string expected", line) }
        if text[index] == "\"" {
            advance(1)
            var out = ""
            while index < text.endIndex, text[index] != "\"" { out.append(text[index]); advance(1) }
            guard eat("\"") else { throw TinyBasicError.message("unterminated string", line) }
            return out
        }
        guard text[index].isLetter else { throw TinyBasicError.message("string expected", line) }
        let start = index
        while index < text.endIndex, text[index].isLetter { advance(1) }
        if index < text.endIndex, text[index] == "$" { advance(1) }
        let name = String(text[start..<index]).uppercased()

        func clipped(_ s: String, _ n: Int, right: Bool = false) -> String {
            let k = max(0, n)
            if k >= s.count { return s }
            return right ? String(s.suffix(k)) : String(s.prefix(k))
        }
        switch name {
        case "LEFT$", "RIGHT$":
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let s = try stringExpression(); guard eat(",") else { throw TinyBasicError.message("\(name) needs two arguments", line) }
            let n = Int(try logicalOr()); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            return clipped(s, n, right: name == "RIGHT$")
        case "MID$":
            guard eat("(") else { throw TinyBasicError.message("MID$ needs ()", line) }
            let s = try stringExpression(); guard eat(",") else { throw TinyBasicError.message("MID$ needs start", line) }
            let start1 = max(1, Int(try logicalOr())); var length: Int?
            if eat(",") { length = max(0, Int(try logicalOr())) }
            guard eat(")") else { throw TinyBasicError.message("MID$ needs )", line) }
            let i = min(s.count, start1 - 1), a = s.index(s.startIndex, offsetBy: i)
            if let length { let b = s.index(a, offsetBy: min(length, s.distance(from: a, to: s.endIndex))); return String(s[a..<b]) }
            return String(s[a...])
        case "CHR$":
            guard eat("(") else { throw TinyBasicError.message("CHR$ needs ()", line) }
            let v = Int(try logicalOr()) & 0xff; guard eat(")") else { throw TinyBasicError.message("CHR$ needs )", line) }
            return String(UnicodeScalar(v) ?? UnicodeScalar(0x20)!)
        case "STR$":
            guard eat("(") else { throw TinyBasicError.message("STR$ needs ()", line) }
            let v = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("STR$ needs )", line) }
            if v.isFinite, abs(v.rounded() - v) < 1e-12, abs(v) < 1e15 { return String(Int64(v.rounded())) }
            return String(format: "%g", v)
        case "UCASE$", "LCASE$", "TRIM$":
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let s = try stringExpression(); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            if name == "UCASE$" { return s.uppercased() }
            if name == "LCASE$" { return s.lowercased() }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case "GRID$":
            guard eat("(") else { throw TinyBasicError.message("GRID$ needs ()", line) }
            let lat = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("GRID$ needs lon", line) }
            let lon = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("GRID$ needs )", line) }
            return FeatureEngine.latLonToGrid4(latitude: lat, longitude: lon)
        case "DXCC$":
            guard eat("(") else { throw TinyBasicError.message("DXCC$ needs ()", line) }
            let code = Int(try logicalOr()); guard eat(")") else { throw TinyBasicError.message("DXCC$ needs )", line) }
            return CardSatTinyBasicEngine.basicDXCCName(code: code) ?? ""
        case "TIME$":
            guard (system["TIMEOK"] ?? 0) != 0 else { return "" }
            return String(format: "%02d:%02d:%02d", Int(system["UTCH"] ?? 0), Int(system["UTCM"] ?? 0), Int(system["UTCS"] ?? 0))
        case "DATE$":
            guard (system["TIMEOK"] ?? 0) != 0 else { return "" }
            return String(format: "%04d-%02d-%02d", Int(system["UTCYR"] ?? 0), Int(system["UTCMON"] ?? 0), Int(system["UTCDAY"] ?? 0))
        default:
            if name.count == 2, name.hasSuffix("$"), name.first?.isLetter == true { return stringVariables[name] ?? "" }
            throw TinyBasicError.message("unknown string name \(name)", line)
        }
    }

    mutating func parse() throws -> Double {
        let value = try logicalOr()
        skipWhitespace()
        if index != text.endIndex { throw TinyBasicError.message("unexpected \(text[index])", line) }
        return value
    }

    mutating func logicalOr() throws -> Double {
        var v = try logicalAnd()
        while eatWord("OR") {
            let rhs = try logicalAnd()
            v = (v != 0 || rhs != 0) ? 1 : 0
        }
        return v
    }

    mutating func logicalAnd() throws -> Double {
        var v = try comparison()
        while eatWord("AND") {
            let rhs = try comparison()
            v = (v != 0 && rhs != 0) ? 1 : 0
        }
        return v
    }

    mutating func comparison() throws -> Double {
        var v = try addition()
        while true {
            skipWhitespace()
            let ops = ["<=", ">=", "<>", "=", "<", ">"]
            guard let op = ops.first(where: { peek($0) }) else { return v }
            advance(op.count)
            let rhs = try addition()
            switch op {
            case "<=": v = v <= rhs ? 1 : 0
            case ">=": v = v >= rhs ? 1 : 0
            case "<>": v = v != rhs ? 1 : 0
            case "=": v = v == rhs ? 1 : 0
            case "<": v = v < rhs ? 1 : 0
            default: v = v > rhs ? 1 : 0
            }
        }
    }

    mutating func addition() throws -> Double {
        var v = try multiplication()
        while true {
            skipWhitespace()
            if eat("+") { v += try multiplication() }
            else if eat("-") { v -= try multiplication() }
            else { return v }
        }
    }

    mutating func multiplication() throws -> Double {
        var v = try power()
        while true {
            skipWhitespace()
            if eat("*") { v *= try power() }
            else if eat("/") { let d = try power(); guard d != 0 else { throw TinyBasicError.message("divide by zero", line) }; v /= d }
            else if eat("%") || eatWord("MOD") { let d = try power(); guard d != 0 else { throw TinyBasicError.message("divide by zero", line) }; v.formTruncatingRemainder(dividingBy: d) }
            else { return v }
        }
    }

    mutating func power() throws -> Double {
        let v = try unary()
        skipWhitespace()
        if eat("^") { return Foundation.pow(v, try power()) }
        return v
    }

    mutating func unary() throws -> Double {
        skipWhitespace()
        if eat("-") { return -(try unary()) }
        if eat("+") { return try unary() }
        if eatWord("NOT") { return try unary() == 0 ? 1 : 0 }
        return try atom()
    }

    mutating func atom() throws -> Double {
        skipWhitespace()
        guard index < text.endIndex else { throw TinyBasicError.message("unexpected end of expression", line) }
        let c = text[index]
        if c == "(" { advance(1); let v = try logicalOr(); _ = eat(")"); return v }
        if c == "@" {
            advance(1); skipWhitespace(); guard eat("(") else { throw TinyBasicError.message("@ needs ()", line) }
            let i = Int(try logicalOr()); _ = eat(")")
            guard let a = anonymousArray, a.indices.contains(i) else { throw TinyBasicError.message("@ index", line) }
            return a[i]
        }
        if c.isNumber || c == "." { return try parseNumber() }
        if c.isLetter { return try parseName() }
        throw TinyBasicError.message("unexpected \(c)", line)
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        var sawExponent = false
        while index < text.endIndex {
            let c = text[index]
            if c.isNumber || c == "." { index = text.index(after: index); continue }
            if (c == "e" || c == "E") && !sawExponent { sawExponent = true; index = text.index(after: index); if index < text.endIndex, text[index] == "+" || text[index] == "-" { index = text.index(after: index) }; continue }
            break
        }
        guard let v = Double(text[start..<index]) else { throw TinyBasicError.message("bad number", line) }
        return v
    }

    mutating func parseName() throws -> Double {
        let start = index
        while index < text.endIndex, text[index].isLetter { advance(1) }
        let name = String(text[start..<index]).uppercased()

        if name == "RND" {
            skipWhitespace()
            if eat("(") {
                let m = max(1, Int(try logicalOr())); guard eat(")") else { throw TinyBasicError.message("RND needs )", line) }
                return Double(Int(rng.next() * Double(m)) % m)
            }
            return rng.next()
        }

        let constants: [String: Double] = [
            "PI": .pi, "TWOPI": 2 * .pi, "DEG": 180 / .pi, "RAD": .pi / 180,
            "CLIGHT": 299_792_458, "KBOLT": 1.380649e-23, "REARTH": 6378.137
        ]
        if let constant = constants[name] { return constant }

        // Number-returning string functions.
        if ["LEN", "ASC", "VAL"].contains(name) {
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let s = try stringExpression(); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            switch name {
            case "LEN": return Double(s.count)
            case "ASC": return Double(s.utf8.first ?? 0)
            default: return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        if name == "INSTR" {
            guard eat("(") else { throw TinyBasicError.message("INSTR needs ()", line) }
            let hay = try stringExpression(); guard eat(",") else { throw TinyBasicError.message("INSTR needs two strings", line) }
            let needle = try stringExpression(); guard eat(")") else { throw TinyBasicError.message("INSTR needs )", line) }
            guard !needle.isEmpty, let r = hay.range(of: needle) else { return 0 }
            return Double(hay.distance(from: hay.startIndex, to: r.lowerBound) + 1)
        }

        let one: [String: (Double) -> Double] = [
            "ABS": abs, "INT": { floor($0) }, "SGN": { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) },
            "SQR": { sqrt(max(0, $0)) }, "SIN": { sin($0 * .pi / 180) }, "COS": { cos($0 * .pi / 180) },
            "TAN": { tan($0 * .pi / 180) }, "ASN": { asin(max(-1, min(1, $0))) * 180 / .pi },
            "ACS": { acos(max(-1, min(1, $0))) * 180 / .pi }, "ATN": { atan($0) * 180 / .pi },
            "LOG": { $0 > 0 ? log($0) : 0 }, "LOG10": { $0 > 0 ? log10($0) : 0 },
            "EXP": exp, "FRAC": { $0 - Double(Int64($0)) }, "ROUND": { $0.rounded() }
        ]
        let two: [String: (Double, Double) -> Double] = ["MIN": min, "MAX": max, "HYP": hypot]
        if let fn = one[name] {
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let a = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            return fn(a)
        }
        if let fn = two[name] {
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let a = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("\(name) needs two arguments", line) }
            let b = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            return fn(a, b)
        }
        if name == "ATN2" {
            guard eat("(") else { throw TinyBasicError.message("ATN2 needs ()", line) }
            let y = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("ATN2 needs y,x", line) }
            let x = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("ATN2 needs )", line) }
            return atan2(y, x) * 180 / .pi
        }
        if name == "GCDIST" || name == "GCAZ" {
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let lat1 = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("\(name) needs 4 args", line) }
            let lon1 = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("\(name) needs 4 args", line) }
            let lat2 = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("\(name) needs 4 args", line) }
            let lon2 = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
            if name == "GCDIST" {
                let c = sin(p1) * sin(p2) + cos(p1) * cos(p2) * cos(dl)
                return 6371.0 * acos(max(-1, min(1, c)))
            }
            let y = sin(dl) * cos(p2)
            let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
            return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
        if name == "FSPL" {
            guard eat("(") else { throw TinyBasicError.message("FSPL needs ()", line) }
            let fMHz = try logicalOr(); guard eat(",") else { throw TinyBasicError.message("FSPL needs freq,distance", line) }
            let dKm = try logicalOr(); guard eat(")") else { throw TinyBasicError.message("FSPL needs )", line) }
            guard fMHz > 0, dKm > 0 else { return 0 }
            return 20 * log10(dKm) + 20 * log10(fMHz) + 32.44
        }
        if name == "DXCCLAT" || name == "DXCCLON" {
            guard eat("(") else { throw TinyBasicError.message("\(name) needs ()", line) }
            let code = Int(try logicalOr()); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            guard let entity = CardSatTinyBasicEngine.basicDXCCCoordinate(code: code) else { return 0 }
            return name == "DXCCLAT" ? entity.latitude : entity.longitude
        }
        if name == "PASSAOS" || name == "PASSLOS" || name == "PASSMAX" {
            guard eat("(") else { throw TinyBasicError.message("\(name) needs (k)", line) }
            let raw = Int(try logicalOr()); guard eat(")") else { throw TinyBasicError.message("\(name) needs )", line) }
            // CardSat documents 1...PASSN. Accept 0 as a compatibility alias for
            // the first row because PASSTATS.BAS shipped briefly with 0-based indices.
            let i = raw == 0 ? 0 : raw - 1
            let values = name == "PASSAOS" ? passAos : (name == "PASSLOS" ? passLos : passMax)
            guard values.indices.contains(i) else { throw TinyBasicError.message("pass index", line) }
            return values[i]
        }
        if TinyBasicHostContext.systemNames.contains(name) {
            if index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" { throw TinyBasicError.message("unknown name \(name)", line) }
            return system[name] ?? 0
        }
        if name.count == 1 {
            skipWhitespace()
            if eat("(") {
                let i = Int(try logicalOr()); guard eat(")") else { throw TinyBasicError.message("paren", line) }
                guard let a = namedArrays[name], a.indices.contains(i) else { throw TinyBasicError.message("\(name) index", line) }
                return a[i]
            }
            return variables[name] ?? 0
        }
        throw TinyBasicError.message("unknown name \(name)", line)
    }

    mutating func skipWhitespace() { while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) } }
    func peek(_ token: String) -> Bool { text[index...].uppercased().hasPrefix(token.uppercased()) }
    mutating func eat(_ token: Character) -> Bool { skipWhitespace(); guard index < text.endIndex, text[index] == token else { return false }; index = text.index(after: index); return true }
    mutating func eat(_ token: String) -> Bool { skipWhitespace(); guard peek(token) else { return false }; advance(token.count); return true }
    mutating func eatWord(_ token: String) -> Bool {
        skipWhitespace(); guard peek(token) else { return false }
        let end = text.index(index, offsetBy: token.count, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" { return false }
        index = end; return true
    }
    mutating func advance(_ count: Int) { index = text.index(index, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex }
}

// MARK: - Expanded bench-tool parity

extension BenchTools {
    /// Calculators added in the first deep-parity pass. They use the same
    /// live numeric-field UI as the original 0.6 tools, so the port remains
    /// compact on iPhone while covering substantially more of the desktop hub.
    static let deepParityTools: [ToolDefinition] = [
        .init(id:"yagi",category:"Antennas & feedline",name:"Yagi elements",description:"Starting driven, reflector, director and spacing dimensions.",fields:[.init(id:"freq",label:"Frequency",defaultValue:144.2,unit:"MHz"),.init(id:"elements",label:"Elements",defaultValue:3,unit:"")]),
        .init(id:"quad",category:"Antennas & feedline",name:"Quad loop",description:"Full-wave driven and reflector loop starting dimensions.",fields:[.init(id:"freq",label:"Frequency",defaultValue:50.1,unit:"MHz"),.init(id:"elements",label:"Elements",defaultValue:2,unit:"")]),
        .init(id:"helix",category:"Antennas & feedline",name:"Helix antenna",description:"Kraus axial-mode helix dimensions, gain and beamwidth.",fields:[.init(id:"freq",label:"Frequency",defaultValue:435,unit:"MHz"),.init(id:"turns",label:"Turns",defaultValue:8,unit:""),.init(id:"circ",label:"Circumference",defaultValue:1.05,unit:"λ"),.init(id:"pitch",label:"Pitch",defaultValue:12.5,unit:"°")]),
        .init(id:"attenuator",category:"RF & measurement",name:"Attenuator pad",description:"Pi and T resistive pad values.",fields:[.init(id:"atten",label:"Attenuation",defaultValue:6,unit:"dB"),.init(id:"z0",label:"Impedance",defaultValue:50,unit:"Ω")]),
        .init(id:"dbchain",category:"RF & measurement",name:"dB chain sum",description:"Sum a four-stage gain/loss chain.",fields:[.init(id:"s1",label:"Stage 1",defaultValue:20,unit:"dB"),.init(id:"s2",label:"Stage 2",defaultValue:-3,unit:"dB"),.init(id:"s3",label:"Stage 3",defaultValue:-6,unit:"dB"),.init(id:"s4",label:"Stage 4",defaultValue:0,unit:"dB")]),
        .init(id:"complex",category:"Electronics & power",name:"Complex / polar",description:"Rectangular impedance to magnitude and phase.",fields:[.init(id:"real",label:"Real",defaultValue:50,unit:""),.init(id:"imag",label:"Imaginary",defaultValue:25,unit:"j")]),
        .init(id:"rctime",category:"Electronics & power",name:"RC time constant",description:"RC τ and 1–5τ charge percentages.",fields:[.init(id:"r",label:"Resistance",defaultValue:1000,unit:"Ω"),.init(id:"c",label:"Capacitance",defaultValue:1,unit:"µF")]),
        .init(id:"pll",category:"Electronics & power",name:"PLL / frequency plan",description:"Reference-divider/N-divider output and channel step.",fields:[.init(id:"ref",label:"Reference",defaultValue:10,unit:"MHz"),.init(id:"r",label:"R divider",defaultValue:1,unit:""),.init(id:"n",label:"N divider",defaultValue:40,unit:""),.init(id:"mult",label:"Multiplier",defaultValue:1,unit:"")]),
        .init(id:"tropo",category:"Terrestrial VHF/UHF",name:"Tropo ducting index",description:"Simple 0–6 watch index from temperature/dew point/inversion/wind.",fields:[.init(id:"temp",label:"Temperature",defaultValue:20,unit:"°C"),.init(id:"dew",label:"Dew point",defaultValue:15,unit:"°C"),.init(id:"inv",label:"Inversion ΔT",defaultValue:4,unit:"°C"),.init(id:"wind",label:"Wind",defaultValue:3,unit:"m/s")]),
        .init(id:"rainfade",category:"Terrestrial VHF/UHF",name:"Microwave rain fade",description:"Approximate specific attenuation for a rain path.",fields:[.init(id:"freq",label:"Frequency",defaultValue:10,unit:"GHz"),.init(id:"rain",label:"Rain rate",defaultValue:25,unit:"mm/h"),.init(id:"distance",label:"Path",defaultValue:10,unit:"km")]),
        .init(id:"slant",category:"Satellite",name:"Slant range",description:"Range to a circular-orbit satellite versus elevation.",fields:[.init(id:"alt",label:"Altitude",defaultValue:500,unit:"km"),.init(id:"el",label:"Elevation",defaultValue:20,unit:"°")]),
        .init(id:"kepler",category:"Satellite",name:"Kepler ellipse",description:"Perigee/apogee, period and speeds from semi-major axis/eccentricity.",fields:[.init(id:"a",label:"Semi-major axis",defaultValue:6878,unit:"km"),.init(id:"e",label:"Eccentricity",defaultValue:0.01,unit:"")]),
        .init(id:"footprint",category:"Satellite",name:"Footprint / horizon",description:"Ground visibility radius from orbital altitude.",fields:[.init(id:"alt",label:"Altitude",defaultValue:500,unit:"km")]),
        .init(id:"sunangle",category:"Satellite",name:"Eclipse beta threshold",description:"Approximate beta-angle threshold for eclipse at altitude.",fields:[.init(id:"alt",label:"Altitude",defaultValue:500,unit:"km")]),
        .init(id:"coax",category:"Antennas & feedline",name:"Coax loss / power",description:"Matched coax loss, SWR-adjusted loss and delivered power using a standard cable model.",fields:[.init(id:"cable",label:"Cable",defaultValue:4,unit:"",choices:["RG-58","RG-8X","RG-213","LMR-240","LMR-400","LMR-600","Hardline 1/2-inch"]),.init(id:"freq",label:"Frequency",defaultValue:146,unit:"MHz"),.init(id:"length",label:"Length",defaultValue:50,unit:"ft"),.init(id:"swr",label:"Load SWR",defaultValue:1.5,unit:"")]),
        .init(id:"phasing",category:"Antennas & feedline",name:"Phasing line / stub",description:"Physical coax length for an electrical quarter/half/etc. wavelength using cable velocity factor.",fields:[.init(id:"cable",label:"Cable",defaultValue:4,unit:"",choices:["RG-58","RG-8X","RG-213","LMR-240","LMR-400","LMR-600","Hardline 1/2-inch"]),.init(id:"freq",label:"Frequency",defaultValue:146,unit:"MHz"),.init(id:"fraction",label:"Electrical length",defaultValue:0,unit:"",choices:["1/4 wave","1/2 wave","3/4 wave","Full wave","1/8 wave"])]),
        .init(id:"cascade",category:"RF & measurement",name:"Cascade NF & G/T",description:"Friis receiver-chain noise figure, equivalent temperature and station G/T.",fields:[.init(id:"antgain",label:"Antenna gain",defaultValue:16,unit:"dBi"),.init(id:"sky",label:"Sky temp",defaultValue:150,unit:"K"),.init(id:"lnanf",label:"LNA NF",defaultValue:0.8,unit:"dB"),.init(id:"lnagain",label:"LNA gain",defaultValue:20,unit:"dB"),.init(id:"coaxloss",label:"Coax loss",defaultValue:3,unit:"dB"),.init(id:"rignf",label:"Rig NF",defaultValue:6,unit:"dB")]),
        .init(id:"sunnoise",category:"RF & measurement",name:"Sun-noise G/T",description:"Estimate station G/T from a measured Sun/noise Y-factor and solar flux.",fields:[.init(id:"y",label:"Y-factor",defaultValue:1,unit:"dB"),.init(id:"flux",label:"Solar flux",defaultValue:150,unit:"sfu"),.init(id:"freq",label:"Frequency",defaultValue:435,unit:"MHz"),.init(id:"gain",label:"Antenna gain",defaultValue:0,unit:"dBi")]),
        .init(id:"imd",category:"RF & measurement",name:"IMD products",description:"Third- and fifth-order two-tone intermodulation products with in-band flags.",fields:[.init(id:"f1",label:"Frequency 1",defaultValue:145.900,unit:"MHz"),.init(id:"f2",label:"Frequency 2",defaultValue:145.950,unit:"MHz"),.init(id:"low",label:"Band low",defaultValue:145.800,unit:"MHz"),.init(id:"high",label:"Band high",defaultValue:146.000,unit:"MHz")]),
        .init(id:"exposure",category:"RF & measurement",name:"RF exposure (MPE)",description:"FCC OET-65 far-field MPE limits and estimated controlled/uncontrolled compliance distances.",fields:[.init(id:"freq",label:"Frequency",defaultValue:146,unit:"MHz"),.init(id:"power",label:"Power",defaultValue:100,unit:"W"),.init(id:"duty",label:"Duty cycle",defaultValue:2,unit:"",choices:["100%","50%","40%","20%"]),.init(id:"gain",label:"Antenna gain",defaultValue:2.15,unit:"dBi")]),
        .init(id:"match",category:"Antennas & feedline",name:"L / Pi / T match",description:"Low-pass impedance-matching network component values.",fields:[.init(id:"topology",label:"Topology",defaultValue:0,unit:"",choices:["L network","Pi network","T network"]),.init(id:"source",label:"Source R",defaultValue:50,unit:"Ω"),.init(id:"load",label:"Load R",defaultValue:200,unit:"Ω"),.init(id:"freq",label:"Frequency",defaultValue:14.2,unit:"MHz"),.init(id:"q",label:"Loaded Q",defaultValue:5,unit:"")]),
        .init(id:"microstrip",category:"Antennas & feedline",name:"Microstrip / stripline Z0",description:"PCB transmission-line characteristic impedance and guided quarter wavelength.",fields:[.init(id:"mode",label:"Line",defaultValue:0,unit:"",choices:["Microstrip","Stripline"]),.init(id:"er",label:"Dielectric εr",defaultValue:4.4,unit:""),.init(id:"h",label:"Substrate/gap H",defaultValue:1.6,unit:"mm"),.init(id:"w",label:"Trace W",defaultValue:3,unit:"mm"),.init(id:"freq",label:"Frequency",defaultValue:435,unit:"MHz")]),
        .init(id:"thermal",category:"Electronics & power",name:"Thermal equilibrium",description:"First-order solar equilibrium temperature from absorptivity and emissivity.",fields:[.init(id:"material",label:"Surface",defaultValue:1,unit:"",choices:["Custom","Black anodized","Bare aluminum","White paint"]),.init(id:"alpha",label:"Custom α",defaultValue:0.25,unit:""),.init(id:"epsilon",label:"Custom ε",defaultValue:0.85,unit:"")]),
        .init(id:"crosssection",category:"Electronics & power",name:"Cross-section area",description:"Projected spacecraft body area for drag and thermal estimates.",fields:[.init(id:"form",label:"Form factor",defaultValue:2,unit:"",choices:["Custom","1U CubeSat","2U CubeSat","3U CubeSat"]),.init(id:"x",label:"Body X",defaultValue:10,unit:"cm"),.init(id:"y",label:"Body Y",defaultValue:10,unit:"cm"),.init(id:"z",label:"Body Z",defaultValue:30,unit:"cm"),.init(id:"panel",label:"Panel area",defaultValue:0,unit:"m²")])
    ]

    static var allTools: [ToolDefinition] { tools + deepParityTools + deepParity2Tools }

    /// Public forwarder so views can turn a State-vector→GP entry into an
    /// exportable/trackable orbit (DeepToolMath is file-private).
    static func stateVectorDefinition(rx: Double, ry: Double, rz: Double,
                                      vx: Double, vy: Double, vz: Double,
                                      frame: Int = 0, epoch: Date) -> ManualSatelliteDefinition? {
        DeepToolMath.stateVectorDefinition(rx: rx, ry: ry, rz: rz, vx: vx, vy: vy, vz: vz, frame: frame, epoch: epoch)
    }

    static func deepParityResults(for id: String, values: [String: Double]) -> [ToolResult]? {
        func v(_ key: String, _ fallback: Double = 0) -> Double { values[key] ?? fallback }
        func row(_ label:String,_ value:String,_ note:String="") -> ToolResult { .init(label:label,value:value,note:note) }
        switch id {
        case "yagi":
            let f=max(v("freq"),0.001), n=max(2,min(12,Int(v("elements")))), driven=468/f
            var rows=[row("Driven",String(format:"%.2f ft",driven)),row("Reflector",String(format:"%.2f ft",driven*1.05))]
            if n>2 { for d in 1..<(n-1) { rows.append(row("Director \(d)",String(format:"%.2f ft",driven*(0.95-0.01*Double(d-1))))) } }
            rows.append(row("Spacing 0.2λ",String(format:"%.2f ft",0.2*983.571/f),"starting point")); return rows
        case "quad":
            let f=max(v("freq"),0.001), loop=1005/f
            return [row("Driven loop",String(format:"%.2f ft",loop)),row("Each side",String(format:"%.2f ft",loop/4)),row("Reflector",String(format:"%.2f ft",1030/f))]
        case "helix":
            let f=max(v("freq"),0.001), turns=max(1,v("turns")), circ=v("circ"), pitch=v("pitch")*Double.pi/180, lambda=299.792458/f, C=circ*lambda, spacing=C*tan(pitch), sw=spacing/lambda, gain=12*circ*circ*turns*sw
            return [row("Wavelength",String(format:"%.3f m",lambda)),row("Diameter",String(format:"%.1f mm",C/Double.pi*1000)),row("Turn spacing",String(format:"%.1f mm",spacing*1000)),row("Axial length",String(format:"%.3f m",turns*spacing)),row("Gain",String(format:"%.1f dBi",10*log10(max(gain,1e-12)))),row("Beamwidth",String(format:"%.0f°",52/(circ*sqrt(max(turns*sw,1e-12)))))]
        case "attenuator":
            let a=max(v("atten"),0.001),z=max(v("z0"),0.001),k=pow(10,a/20)
            return [row("Pi shunt",String(format:"%.1f Ω ×2",z*(k+1)/(k-1))),row("Pi series",String(format:"%.1f Ω",z*(k*k-1)/(2*k))),row("T series",String(format:"%.1f Ω ×2",z*(k-1)/(k+1))),row("T shunt",String(format:"%.1f Ω",z*(2*k)/(k*k-1)))]
        case "dbchain":
            let total=v("s1")+v("s2")+v("s3")+v("s4")
            return [row("Net gain",String(format:"%.2f dB",total)),row("Power ratio",String(format:"%.4f×",pow(10,total/10))),row("Voltage ratio",String(format:"%.4f×",pow(10,total/20))),row("100 W in",String(format:"%.2f W",100*pow(10,total/10)))]
        case "complex":
            let a=v("real"),b=v("imag"),mag=hypot(a,b),phase=atan2(b,a)*180/Double.pi
            return [row("Magnitude",String(format:"%.4f",mag)),row("Phase",String(format:"%+.2f°",phase)),row("Polar",String(format:"%.3f ∠ %+.2f°",mag,phase))]
        case "rctime":
            let tau=max(v("r"),0)*max(v("c"),0)*1e-6
            var out=[row("τ",String(format:"%.6g s",tau))]; for n in 1...5 { out.append(row("\(n)τ",String(format:"%.1f%% charged",100*(1-exp(-Double(n)))))) }; return out
        case "pll":
            let ref=max(v("ref"),1e-12),r=max(v("r"),1),n=v("n"),m=v("mult")
            let pfd=ref/r,out=pfd*n*m
            return [row("PFD",String(format:"%.6f MHz",pfd)),row("Output",String(format:"%.6f MHz",out)),row("Step",String(format:"%.3f kHz",pfd*m*1000))]
        case "tropo":
            var index=0; let spread=v("temp")-v("dew"); if spread<5{index+=1}; if v("inv")>=2{index+=2}; if v("inv")>=5{index+=1}; if v("wind")<=5{index+=1}; if v("wind")<=2{index+=1}; index=min(index,6)
            let labels=["none","weak","possible","fair","good","strong","very strong"]
            return [row("Index","\(index) / 6",labels[index]),row("T−Td",String(format:"%.1f °C",spread)),row("Watch",index>=3 ? "yes":"no",index>=3 ? "conditions may support enhancement":"ordinary refraction more likely")]
        case "rainfade":
            let f=max(v("freq"),0.1),r=max(v("rain"),0),d=max(v("distance"),0); let k=0.0001*pow(f,1.65),gamma=k*pow(max(r,0.01),0.9),loss=gamma*d
            return [row("Specific loss",String(format:"%.3f dB/km",gamma)),row("Path fade",String(format:"%.2f dB",loss)),row("Note",f<5 ? "usually small below ~5 GHz":"planning approximation")]
        case "slant":
            let range=LearnMath.slantRangeKm(altitudeKm:v("alt"),elevationDeg:v("el")); return [row("Slant range",String(format:"%.0f km",range))]
        case "kepler":
            let mu=398600.4418,a=max(v("a"),6378.2),e=max(0,min(0.99,v("e"))),rp=a*(1-e),ra=a*(1+e),period=2*Double.pi*sqrt(pow(a,3)/mu),vp=sqrt(mu*(2/rp-1/a)),va=sqrt(mu*(2/ra-1/a))
            return [row("Perigee alt",String(format:"%.0f km",rp-6378.135)),row("Apogee alt",String(format:"%.0f km",ra-6378.135)),row("Period",String(format:"%.1f min",period/60)),row("Perigee speed",String(format:"%.3f km/s",vp)),row("Apogee speed",String(format:"%.3f km/s",va))]
        case "footprint":
            let alt=max(v("alt"),1),re=6378.135,psi=acos(re/(re+alt)); return [row("Angular radius",String(format:"%.1f°",psi*180/Double.pi)),row("Ground radius",String(format:"%.0f km",re*psi)),row("Diameter",String(format:"%.0f km",2*re*psi))]
        case "sunangle":
            let alt=max(v("alt"),1),threshold=asin(6378.135/(6378.135+alt))*180/Double.pi
            return [row("Eclipse threshold",String(format:"|β| < %.1f°",90-threshold)),row("Continuous sun",String(format:"|β| ≥ %.1f°",90-threshold))]
        case "coax":
            let cables:[(String,Double,Double,Double)] = [("RG-58",0.66,0.1400,0.00050),("RG-8X",0.82,0.0900,0.00035),("RG-213",0.66,0.0600,0.00022),("LMR-240",0.84,0.0630,0.00028),("LMR-400",0.85,0.0390,0.00015),("LMR-600",0.87,0.0240,0.00011),("Hardline 1/2-inch",0.88,0.0180,0.00007)]
            let ci=max(0,min(cables.count-1,Int(v("cable")))), c=cables[ci], f=max(v("freq"),0.001), length=max(v("length"),0), sw=max(1,v("swr"))
            let matched=(c.2*sqrt(f)+c.3*f)*(length/100), g=(sw-1)/(sw+1), a=pow(10,matched/10), num=a*a-g*g, den=a*(1-g*g), total=(num>0 && den>0) ? 10*log10(num/den) : matched, pout=pow(10,-total/10)
            return [row("Cable",c.0,String(format:"VF %.2f",c.1)),row("Matched loss",String(format:"%.2f dB",matched)),row("Loss at SWR",String(format:"%.2f dB",total)),row("Power out",String(format:"%.1f%%",pout*100)),row("100 W in",String(format:"%.1f W",100*pout))]
        case "phasing":
            let names=["RG-58","RG-8X","RG-213","LMR-240","LMR-400","LMR-600","Hardline 1/2-inch"], vf=[0.66,0.82,0.66,0.84,0.85,0.87,0.88], fracs=[0.25,0.5,0.75,1.0,0.125]
            let ci=max(0,min(vf.count-1,Int(v("cable")))), fi=max(0,min(fracs.count-1,Int(v("fraction")))), f=max(v("freq"),0.001), lambda=299.792458/f, meters=lambda*fracs[fi]*vf[ci]
            return [row("Cable",names[ci],String(format:"VF %.2f",vf[ci])),row("Free-space λ",String(format:"%.3f m",lambda)),row("Physical length",String(format:"%.3f m",meters)),row("Length",String(format:"%.1f cm",meters*100))]
        case "cascade":
            let fLNA=pow(10,v("lnanf")/10),gLNA=pow(10,v("lnagain")/10),loss=pow(10,v("coaxloss")/10),gCoax=1/loss,fRig=pow(10,v("rignf")/10)
            let fTotal=fLNA+(loss-1)/gLNA+(fRig-1)/(gLNA*gCoax), nf=10*log10(fTotal),te=290*(fTotal-1),ts=max(1,v("sky")+te),gt=v("antgain")-10*log10(ts)
            return [row("System NF",String(format:"%.2f dB",nf)),row("Noise temp",String(format:"%.0f K",te)),row("System temp",String(format:"%.0f K",ts)),row("G/T",String(format:"%.1f dB/K",gt))]
        case "sunnoise":
            let y=pow(10,v("y")/10), flux=max(v("flux"),0)*1e-22, freq=max(v("freq"),0.001), lambda=299.792458/freq, kb=1.380649e-23
            let gt=(y>1 && flux>0) ? 10*log10((y-1)*8*Double.pi*kb/(lambda*lambda*flux)) : -99
            var out=[row("G/T",String(format:"%.2f dB/K",gt))]
            if v("gain")>0 { out.append(row("Tsys @ gain",String(format:"%.0f K",pow(10,(v("gain")-gt)/10)))) }
            out.append(row("Sun size","0.53°","point-source approximation")); return out
        case "imd":
            let f1=v("f1"),f2=v("f2"),lo=min(v("low"),v("high")),hi=max(v("low"),v("high")); func flag(_ f:Double)->String{(lo...hi).contains(f) ? "IN" : "out"}
            let p3a=2*f1-f2,p3b=2*f2-f1,p5a=3*f1-2*f2,p5b=3*f2-2*f1
            return [row("Spacing",String(format:"%.1f kHz",abs(f2-f1)*1000)),row("3rd 2f1−f2",String(format:"%.4f MHz",p3a),flag(p3a)),row("3rd 2f2−f1",String(format:"%.4f MHz",p3b),flag(p3b)),row("5th 3f1−2f2",String(format:"%.4f MHz",p5a),flag(p5a)),row("5th 3f2−2f1",String(format:"%.4f MHz",p5b),flag(p5b))]
        case "exposure":
            let f=max(v("freq"),0.001),p=max(v("power"),0),gain=v("gain"),duties=[100.0,50.0,40.0,20.0],duty=duties[max(0,min(3,Int(v("duty"))))]
            func unc(_ f:Double)->Double{ if f<1.34{return 100}; if f<30{return 180/(f*f)}; if f<300{return 0.2}; if f<1500{return f/1500}; return 1 }
            func ctl(_ f:Double)->Double{ if f<3{return 100}; if f<30{return 900/(f*f)}; if f<300{return 1}; if f<1500{return f/300}; return 5 }
            func distance(_ lim:Double)->Double{ guard lim>0 else{return 0}; return sqrt(p*1000*(duty/100)*pow(10,gain/10)/(4*Double.pi*lim))/100 }
            let du=distance(unc(f)),dc=distance(ctl(f)); return [row("Uncontrolled MPE",String(format:"%.3f mW/cm²",unc(f))),row("Distance",String(format:"%.2f m",du)),row("Controlled MPE",String(format:"%.3f mW/cm²",ctl(f))),row("Distance (ctrl)",String(format:"%.2f m",dc)),row("Average power",String(format:"%.1f W",p*duty/100)),row("Reflection ×2",String(format:"%.2f m unc",du*2),"planning aid, not a station evaluation")]
        case "match":
            let topo=max(0,min(2,Int(v("topology")))),r1=max(v("source"),1e-9),r2=max(v("load"),1e-9),freq=max(v("freq"),1e-9)*1e6,q=v("q"),w=2*Double.pi*freq,rb=max(r1,r2),rs=min(r1,r2),qmin=rb>rs ? sqrt(rb/rs-1) : 0
            func lu(_ x:Double)->String{String(format:"%.3f µH",x/w*1e6)}; func cp(_ x:Double)->String{String(format:"%.1f pF",1/(w*max(x,1e-12))*1e12)}
            if topo==0 { if rb==rs{return [row("R1 == R2","No L network needed")]}; let xs=qmin*rs,xp=rb/max(qmin,1e-12); return [row("Network Q",String(format:"%.2f",qmin)),row("Series L",lu(xs)),row("Shunt C",cp(xp)),row("HP series C",cp(xs)),row("HP shunt L",lu(xp))] }
            guard q>qmin else{return [row("Q too low",String(format:"need > %.2f",qmin))]}
            if topo==1 { let rv=rb/(q*q+1),q2=sqrt(max(0,rs/rv-1)),xpB=rb/q,xsB=q*rv,xpS=rs/max(q2,1e-12),xsS=q2*rv,xl=xsB+xsS,xcSource=r1>=r2 ? xpB:xpS,xcLoad=r2>r1 ? xpB:xpS; return [row("C @ source",cp(xcSource)),row("Series L",lu(xl)),row("C @ load",cp(xcLoad)),row("Minimum Q",String(format:"%.2f",qmin))] }
            let xl1=q*r1,b=r1*(1+q*q); guard b/r2>1 else{return [row("Q too low","for this ratio")]}; let xl2=r2*sqrt(b/r2-1),xc=b/(q+xl2/r2); return [row("L @ source",lu(xl1)),row("Shunt C",cp(xc)),row("L @ load",lu(xl2)),row("Minimum Q",String(format:"%.2f",qmin))]
        case "microstrip":
            let mode=max(0,min(1,Int(v("mode")))),er=max(v("er"),1),h=max(v("h"),1e-9),width=max(v("w"),1e-9),u=width/h; var eeff=er,z0=0.0
            if mode==0 { eeff=(er+1)/2+(er-1)/2*pow(1+12/u,-0.5)+(u<1 ? 0.04*pow(1-u,2)*(er-1)/2:0); z0 = u<=1 ? 60/sqrt(eeff)*log(8/u+u/4) : 120*Double.pi/(sqrt(eeff)*(u+1.393+0.667*log(u+1.444))) } else { z0=60/sqrt(er)*log(1.9*h/(0.8*width)); eeff=er }
            var out=[row("Z0",String(format:"%.1f Ω",z0)),row("ε effective",String(format:"%.2f",eeff))]; if v("freq")>0 { let q=74948.1/(v("freq")*sqrt(eeff)); out.append(row("90° line",String(format:"%.1f mm",q))); out.append(row("Guided λ",String(format:"%.1f mm",4*q))) }; return out
        case "thermal":
            let materials:[(String,Double,Double)]=[("Custom",v("alpha"),v("epsilon")),("Black anodized",0.86,0.86),("Bare aluminum",0.15,0.05),("White paint",0.20,0.88)], m=materials[max(0,min(materials.count-1,Int(v("material"))))],alpha=max(m.1,1e-9),epsilon=max(m.2,1e-9),solar=1361.0,sigma=5.670374419e-8,t1=pow(alpha*solar/(epsilon*sigma),0.25),t2=pow(alpha*solar/(2*epsilon*sigma),0.25)
            return [row("Surface",m.0),row("α / ε",String(format:"%.2f / %.2f = %.2f",alpha,epsilon,alpha/epsilon)),row("1-side radiation",String(format:"%.0f °C (%.0f K)",t1-273.15,t1)),row("2-side radiation",String(format:"%.0f °C (%.0f K)",t2-273.15,t2)),row("Eclipse","roughly −60…−100 °C","first order; no albedo/internal heat")]
        case "crosssection":
            let forms:[(String,Double,Double,Double)]=[("Custom",v("x"),v("y"),v("z")),("1U CubeSat",10,10,10),("2U CubeSat",10,10,20),("3U CubeSat",10,10,30)],f=forms[max(0,min(forms.count-1,Int(v("form"))))],a=f.1/100,b=f.2/100,c=f.3/100,panel=max(v("panel"),0),ab=a*b,bc=b*c,ca=c*a,minf=min(ab,min(bc,ca)),maxf=max(ab,max(bc,ca)),maxproj=sqrt(ab*ab+bc*bc+ca*ca),tumble=(ab+bc+ca)/2
            return [row("Form",f.0),row("End-on minimum",String(format:"%.4f m²",minf)),row("Broadside",String(format:"%.4f m²",maxf+panel)),row("Max any angle",String(format:"%.4f m²",maxproj+panel)),row("Tumbling avg",String(format:"%.4f m²",tumble+panel/2))]
        default: return nil
        }
    }
}

// MARK: - Deeper Learn helpers

extension LearnMath {
    static func visVivaSpeed(radiusKm: Double, semiMajorAxisKm: Double) -> Double { sqrt(mu * (2/max(radiusKm,1) - 1/max(semiMajorAxisKm,1))) }
    static func hohmannTransfer(r1Km: Double, r2Km: Double) -> (dv1: Double, dv2: Double, total: Double, minutes: Double) {
        let r1=max(earthRadiusKm+1,r1Km),r2=max(earthRadiusKm+1,r2Km),a=(r1+r2)/2
        let v1=sqrt(mu/r1),v2=sqrt(mu/r2),vt1=sqrt(mu*(2/r1-1/a)),vt2=sqrt(mu*(2/r2-1/a))
        let d1=abs(vt1-v1),d2=abs(v2-vt2),time=Double.pi*sqrt(pow(a,3)/mu)/60
        return(d1,d2,d1+d2,time)
    }
    static func planeChangeDeltaV(speedKmS: Double, angleDeg: Double) -> Double { 2*speedKmS*sin(abs(angleDeg)*Double.pi/360) }
    static func meanAnomalyFromEccentric(_ eccentricAnomalyRad: Double, eccentricity: Double) -> Double { eccentricAnomalyRad - eccentricity*sin(eccentricAnomalyRad) }
    static func eccentricAnomaly(meanAnomalyRad: Double, eccentricity: Double) -> Double {
        var e=meanAnomalyRad; for _ in 0..<20 { let f=e-eccentricity*sin(e)-meanAnomalyRad,fp=1-eccentricity*cos(e); e-=f/max(fp,1e-12) }; return e
    }
    static func trueAnomaly(meanAnomalyDeg: Double, eccentricity: Double) -> Double {
        let m=meanAnomalyDeg*Double.pi/180,e=eccentricAnomaly(meanAnomalyRad:m,eccentricity:eccentricity); let t=2*atan2(sqrt(1+eccentricity)*sin(e/2),sqrt(1-eccentricity)*cos(e/2)); return (t*180/Double.pi+360).truncatingRemainder(dividingBy:360)
    }
    static func constellationSatellites(altitudeKm: Double, minimumElevationDeg: Double = 0) -> Int {
        let re=earthRadiusKm,r=re+max(1,altitudeKm),el=minimumElevationDeg*Double.pi/180
        let central=max(0,acos(re/r*cos(el))-el)
        guard central>0 else{return Int.max}; return max(2,Int(ceil(Double.pi/central)))
    }
    static func antennaBeamwidthApprox(gainDBi: Double) -> Double { max(1,70/pow(10,gainDBi/20)) * 2 }
    static func eclipseBetaThresholdDeg(altitudeKm: Double) -> Double { 90 - asin(earthRadiusKm/(earthRadiusKm+max(1,altitudeKm)))*180/Double.pi }
}


extension LearnMath {
    static func j2Rates(meanMotionRevDay: Double, inclinationDeg: Double, eccentricity: Double) -> (nodeDegDay: Double, perigeeDegDay: Double) {
        guard meanMotionRevDay > 0 else { return (0, 0) }
        let j2 = 1.08262668e-3
        let re = earthRadiusKm
        let n = meanMotionRevDay * 2 * Double.pi / 86400
        let a = pow(mu / (n*n), 1.0/3)
        let p = a * (1 - eccentricity*eccentricity)
        let i = inclinationDeg * Double.pi / 180
        let factor = 1.5 * j2 * n * pow(re/p, 2)
        let node = -factor * cos(i)
        let perigee = 0.5 * factor * (5*pow(cos(i), 2) - 1)
        return (node * 86400 * 180 / Double.pi, perigee * 86400 * 180 / Double.pi)
    }

    static func eclipseFraction(altitudeKm: Double, betaDeg: Double) -> Double {
        let ratio = earthRadiusKm / (earthRadiusKm + max(1, altitudeKm))
        // Critical beta angle above which the orbit is in continuous sunlight is
        // arcsin(Re/(Re+h)) — using arccos here made β★ far too small (~20° for LEO
        // instead of ~70°), so many still-eclipsing cases wrongly read 0%.
        let betaStar = asin(max(-1, min(1, ratio))) * 180 / Double.pi
        if abs(betaDeg) >= betaStar { return 0 }
        let cb = cos(betaDeg * Double.pi / 180)
        guard cb > 1e-6 else { return 0 }
        let numerator = sqrt(max(0, 1 - ratio*ratio)) / cb
        return acos(max(-1, min(1, numerator))) / Double.pi
    }

    static func decayEstimate(meanMotion: Double, eccentricity: Double, bstar: Double,
                              ndot: Double = 0, solarIndex: Int = 1) -> (days: Double, source: String) {
        let r = OrbitDecayModel.estimate(meanMotion: meanMotion, ecc: eccentricity,
                                         bstar: bstar, ndot: ndot, solar: solarIndex)
        return (r.0, r.1.label)
    }

    static func fixedDownlinkUplinkHz(downlinkCenterHz: Int64, uplinkCenterHz: Int64,
                                      downlinkOffsetHz: Double = 0,
                                      rangeRateKmS: Double, inverted: Bool) -> Int64 {
        guard uplinkCenterHz > 0, downlinkCenterHz > 0 else { return 0 }
        let beta = (rangeRateKmS * 1000) / 299_792_458.0
        let sign = inverted ? -1.0 : 1.0
        let uplinkSatelliteFrame = Double(uplinkCenterHz) + sign * downlinkOffsetHz
        return Int64((uplinkSatelliteFrame / (1 - beta)).rounded())
    }
}

// MARK: - 0.8 Tools registry completion

private enum DeepToolMath {
    static let muKm = 398600.4418
    static let earthKm = 6378.137
    static let cKmS = 299792.458

    static func row(_ label: String, _ value: String, _ note: String = "") -> ToolResult {
        .init(label: label, value: value, note: note)
    }

    static func ampacity(mode: Int, current: Double, rise: Double, copperOz: Double, awg: Double) -> [ToolResult] {
        if mode < 2 {
            guard current > 0, rise > 0, copperOz > 0 else { return [row("error", "need I, ΔT, oz > 0")] }
            let k = mode == 0 ? 0.048 : 0.024
            let areaMil2 = pow(current / (k * pow(rise, 0.44)), 1.0 / 0.725)
            let widthMil = areaMil2 / (1.378 * copperOz)
            return [
                row("Trace width", String(format: "%.2f mm", widthMil * 0.0254)),
                row("= mils", String(format: "%.0f mil", widthMil)),
                row("Cu / rise", String(format: "%.1f oz / %.0f °C", copperOz, rise)),
                row("IPC-2221", mode == 0 ? "external" : "internal")
            ]
        }
        let diameterMM = 0.127 * pow(92.0, (36.0 - awg) / 39.0)
        let areaM2 = .pi * diameterMM * diameterMM / 4 * 1e-6
        let resistanceMilliOhmM = 1.724e-8 / max(areaM2, 1e-18) * 1000
        let ampacity: [(Double, Double)] = [(10,55),(12,41),(14,32),(16,22),(18,16),(20,11),(22,7),(24,3.5),(26,2.2),(28,1.4)]
        let limit = ampacity.first(where: { $0.0 >= awg })?.1 ?? 1.4
        return [
            row("Diameter", String(format: "%.2f mm", diameterMM)),
            row("R", String(format: "%.1f mΩ/m", resistanceMilliOhmM)),
            row("Chassis max", String(format: "%.1f A", limit)),
            row("Your load", String(format: "%.1f A %@", current, current <= limit ? "OK" : "OVER"))
        ]
    }

    static let toroids: [(String, Double, Bool, Double)] = [
        ("T37-2",40,false,25),("T37-6",30,false,25),("T50-2",49,false,32),("T50-6",40,false,32),
        ("T68-2",57,false,41),("T68-6",47,false,41),("T106-2",135,false,62),("T130-2",110,false,73),
        ("T200-2",120,false,100),("FT37-43",350,true,25),("FT50-43",523,true,33),("FT82-43",557,true,52),
        ("FT114-43",603,true,70),("FT140-43",952,true,86),("FT37-61",55.3,true,25),("FT50-61",68,true,33)
    ]

    static func toroid(index: Int, targetUH: Double) -> [ToolResult] {
        let core = toroids[max(0, min(toroids.count - 1, index))]
        let turnsRaw = core.2 ? 1000 * sqrt((targetUH / 1000) / core.1) : 100 * sqrt(targetUH / core.1)
        let turns = max(1, Int(ceil(turnsRaw - 1e-9)))
        let actual = core.2 ? core.1 * pow(Double(turns) / 1000, 2) * 1000 : core.1 * pow(Double(turns) / 100, 2)
        return [
            row("Core", core.0, core.2 ? "ferrite" : "iron powder"),
            row("Turns", "\(turns)"),
            row("Actual L", String(format: "%.2f µH", actual)),
            row("AL", String(format: "%.1f %@", core.1, core.2 ? "mH/1k t" : "µH/100t")),
            row("Wire approx", String(format: "%.0f cm + lead", Double(turns) * core.3 / 10))
        ]
    }

    static func terrestrialBudget(txPowerW: Double, txGain: Double, rxGain: Double, lineLoss: Double, freqMHz: Double, distanceKm: Double) -> [ToolResult] {
        guard distanceKm > 0, freqMHz > 0, txPowerW > 0 else { return [row("error", "need power, distance and frequency > 0")] }
        let loss = 20 * log10(distanceKm) + 20 * log10(freqMHz) + 32.44
        let txDBm = 10 * log10(txPowerW * 1000)
        let eirp = txDBm + txGain - lineLoss
        let rxLevel = eirp - loss + rxGain - lineLoss
        let noise  = -174 + 10 * log10(12000.0) + 10
        let margin = rxLevel - noise
        return [
            row("FSPL", String(format: "%.1f dB", loss)),
            row("EIRP", String(format: "%.1f dBm", eirp)),
            row("RX level", String(format: "%.1f dBm", rxLevel)),
            row("Noise floor", String(format: "%.1f dBm", noise)),
            row("Margin", String(format: "%+.1f dB", margin)),
            row("Verdict", margin > 10 ? "workable" : margin > 0 ? "marginal" : "no path")
        ]
    }

    static func terrainLOS(pathKm: Double, obstructionM: Double, atKm: Double, txHAAT: Double, rxHAAT: Double, freqMHz: Double, txGround: Double, rxGround: Double) -> [ToolResult] {
        guard pathKm > 0, atKm > 0, atKm < pathKm else { return [row("error", "need 0 < obstruction at < path")] }
        let f = atKm / pathKm, d1 = atKm, d2 = pathKm - atKm
        let los = txGround + txHAAT + ((rxGround + rxHAAT) - (txGround + txHAAT)) * f
        let bulge = d1 * d2 / (2 * (4.0/3.0) * 6371.0) * 1000
        let terr = obstructionM + bulge
        let clearance = los - terr
        let fGHz = freqMHz / 1000
        let fresnel = fGHz > 0 ? 17.31 * sqrt((d1 * d2) / (fGHz * pathKm)) : 0
        let clear = clearance >= 0.6 * fresnel
        return [
            row("LOS height", String(format: "%.0f m", los), "at obstruction"),
            row("Obstruction", String(format: "%.0f m", terr), "incl Earth bulge"),
            row("Clearance", String(format: "%.0f m", clearance)),
            row("Fresnel F1", String(format: "%.0f m", fresnel), String(format: "need 60%%: %.0f m", 0.6*fresnel)),
            row("Earth bulge", String(format: "%.0f m", bulge), "4/3 Earth"),
            row("Verdict", clear ? "clear (60% Fresnel)" : clearance >= 0 ? "grazing" : "blocked")
        ]
    }

    static func dopplerBudget(apogeeKm: Double, perigeeKm: Double, freqMHz: Double) -> [ToolResult] {
        let ap = max(apogeeKm, perigeeKm), pe = min(apogeeKm, perigeeKm)
        let r = earthKm + 0.5 * (ap + pe), f = freqMHz * 1e6
        guard r > earthKm, f > 0 else { return [row("error", "altitude/frequency too low")] }
        let w = sqrt(muKm / pow(r, 3)), thetaH = acos(earthKm / r)
        var rrMax = 0.0
        for i in 1...200 {
            let theta = thetaH * Double(i) / 200
            let rho = sqrt(r*r + earthKm*earthKm - 2*r*earthKm*cos(theta))
            let rr = rho > 0 ? r*earthKm*sin(theta)*w/rho : 0
            rrMax = max(rrMax, rr)
        }
        let rateTCA = r*earthKm*w*w/(r-earthKm)
        let rhoH = sqrt(r*r + earthKm*earthKm - 2*r*earthKm*cos(thetaH))
        return [
            row("Max Doppler", String(format: "±%.2f kHz", f*rrMax/cKmS/1e3)),
            row("Rate at TCA", String(format: "%.1f Hz/s", f*rateTCA/cKmS)),
            row("per MHz", String(format: "±%.1f Hz", 1e6*rrMax/cKmS)),
            row("Max LOS vel", String(format: "%.3f km/s", rrMax)),
            row("Period", String(format: "%.1f min", 2*Double.pi/w/60)),
            row("Horizon range", String(format: "%.0f km", rhoH))
        ]
    }

    static func deltaV(alt1: Double, alt2: Double, planeDeg: Double) -> [ToolResult] {
        let r1 = earthKm + alt1, r2 = earthKm + alt2
        guard r1 > earthKm, r2 > earthKm else { return [row("error", "altitude > 0 km")] }
        let v1 = sqrt(muKm/r1), v2 = sqrt(muKm/r2), at = 0.5*(r1+r2)
        let dv1 = abs(sqrt(muKm*(2/r1-1/at))-v1), dv2 = abs(v2-sqrt(muKm*(2/r2-1/at)))
        let tt = Double.pi*sqrt(pow(at,3)/muKm)/60
        let plane = 2*v2*sin(abs(planeDeg)*Double.pi/360)
        let ad = 0.5*(r1 + earthKm + 60), deorbit = v1 - sqrt(muKm*(2/r1-1/ad))
        var out = [row("Hohmann Δv1", String(format:"%.1f m/s",dv1*1000)), row("Hohmann Δv2",String(format:"%.1f m/s",dv2*1000)), row("Total",String(format:"%.1f m/s",(dv1+dv2)*1000)), row("Transfer t",String(format:"%.1f min",tt))]
        if abs(planeDeg) > 0 { out.append(row("Plane change",String(format:"%.0f m/s @alt2",plane*1000))) }
        out.append(row("Deorbit",String(format:"%.1f m/s →60 km",deorbit*1000)))
        return out
    }

    static func pointingLoss(hpbw: Double, error: Double) -> [ToolResult] {
        let loss = hpbw > 0 ? 12 * pow(error/hpbw,2) : 0
        var out = [row("Loss",String(format:"%.2f dB",loss)),row("1 dB at",String(format:"±%.1f°",hpbw*0.2887)),row("3 dB at",String(format:"±%.1f°",hpbw*0.5))]
        if error > hpbw*0.5 { out.append(row("Note","approx past HPBW/2")) }
        return out
    }

    static func linkElevation(alt: Double, freq: Double, margin0: Double) -> [ToolResult] {
        guard alt > 0, freq > 0 else { return [row("error","need altitude & frequency > 0")] }
        func range(_ el: Double) -> Double { let e=el*Double.pi/180,se=sin(e); return sqrt(earthKm*earthKm*se*se+2*earthKm*alt+alt*alt)-earthKm*se }
        let r0=range(0); var out:[ToolResult]=[]
        for el in [0.0,10,20,30,45,60,90] { let m=margin0+20*log10(r0/range(el)); out.append(row(String(format:"%2.0f° el",el),String(format:"%+.1f dB",m),el==0 ? "horizon" : el==90 ? "overhead (TCA)" : "")) }
        out.append(row("AOS→TCA gain",String(format:"%.1f dB",20*log10(r0/range(90)))))
        return out
    }

    static func faraday(freqMHz: Double, condition: Int) -> [ToolResult] {
        let presets=[("Quiet (10 TECU)",10.0),("Moderate (30)",30.0),("Storm (80)",80.0)]
        let p=presets[max(0,min(presets.count-1,condition))],tec=p.1*1e16,b=4e-5
        func turns(_ hz:Double)->Double{2.36e4*b*tec/(hz*hz)/(2*Double.pi)}
        return [row("Condition",p.0),row("Rotations",String(format:"%.1f @ entered f",turns(freqMHz*1e6))),row("@ 146 MHz",String(format:"%.1f turns",turns(146e6))),row("@ 437 MHz",String(format:"%.2f turns",turns(437e6))),row("CP wrong hand","> 20 dB","use CP on linear sats")]
    }

    /// Rotate a 3-vector from J2000 (GCRF) to TEME at `epoch` using IAU76
    /// precession + a truncated (13-term) IAU80 nutation. Ported verbatim from
    /// CardSat so the State-vector→GP frame switch matches the firmware.
    static func j2000ToTeme(_ vin: (Double, Double, Double), epoch: Date) -> (Double, Double, Double) {
        let AS2R = 4.84813681109536e-6, D2R = 0.017453292519943295
        let jd = epoch.timeIntervalSince1970 / 86400.0 + 2440587.5
        let T = (jd - 2451545.0) / 36525.0
        let zeta  = (2306.2181*T + 0.30188*T*T + 0.017998*T*T*T) * AS2R
        let zang  = (2306.2181*T + 1.09468*T*T + 0.018203*T*T*T) * AS2R
        let theta = (2004.3109*T - 0.42665*T*T - 0.041833*T*T*T) * AS2R
        let eps0  = (84381.448 - 46.8150*T - 0.00059*T*T + 0.001813*T*T*T) * AS2R
        let rr = 360.0
        let l  = (134.96298139 + (1325*rr+198.8673981)*T + 0.0086972*T*T) * D2R
        let lp = (357.52772333 + (99*rr+359.0503400)*T - 0.0001603*T*T) * D2R
        let F  = (93.27191028 + (1342*rr+82.0175381)*T - 0.0036825*T*T) * D2R
        let D  = (297.85036306 + (1236*rr+307.1114800)*T - 0.0019142*T*T) * D2R
        let Om = (125.04452222 - (5*rr+134.1362608)*T + 0.0020708*T*T) * D2R
        let NT: [[Double]] = [
            [0,0,0,0,1,-171996,-174.2,92025,8.9], [0,0,2,-2,2,-13187,-1.6,5736,-3.1],
            [0,0,2,0,2,-2274,-0.2,977,-0.5], [0,0,0,0,2,2062,0.2,-895,0.5],
            [0,1,0,0,0,1426,-3.4,54,-0.1], [1,0,0,0,0,712,0.1,-7,0.0],
            [0,1,2,-2,2,-517,1.2,224,-0.6], [0,0,2,0,1,-386,-0.4,200,0.0],
            [1,0,2,0,2,-301,0.0,129,-0.1], [0,-1,2,-2,2,217,-0.5,-95,0.3],
            [1,0,0,-2,0,-158,0.0,0,0.0], [0,0,2,-2,1,129,0.1,-70,0.0],
            [-1,0,2,0,2,123,0.0,-53,0.0]
        ]
        var dpsi = 0.0, deps = 0.0
        for t in NT {
            let arg = t[0]*l + t[1]*lp + t[2]*F + t[3]*D + t[4]*Om
            dpsi += (t[5] + t[6]*T) * sin(arg)
            deps += (t[7] + t[8]*T) * cos(arg)
        }
        dpsi *= 0.0001 * AS2R; deps *= 0.0001 * AS2R
        let epsT = eps0 + deps, eqe = dpsi * cos(eps0)
        func rot1(_ a: Double, _ v: inout (Double, Double, Double)) { let c=cos(a),s=sin(a),y=v.1,z=v.2; v.1=c*y+s*z; v.2 = -s*y+c*z }
        func rot2(_ a: Double, _ v: inout (Double, Double, Double)) { let c=cos(a),s=sin(a),x=v.0,z=v.2; v.0=c*x-s*z; v.2=s*x+c*z }
        func rot3(_ a: Double, _ v: inout (Double, Double, Double)) { let c=cos(a),s=sin(a),x=v.0,y=v.1; v.0=c*x+s*y; v.1 = -s*x+c*y }
        var w = vin
        rot3(-zeta, &w); rot2(theta, &w); rot3(-zang, &w)
        rot1(eps0, &w); rot3(-dpsi, &w); rot1(-epsT, &w)
        rot3(eqe, &w)
        return w
    }

    static func stateVector(rx: Double, ry: Double, rz: Double,
                            vx: Double, vy: Double, vz: Double,
                            frame: Int = 0, epoch: Date = Date()) -> [ToolResult] {
        typealias V = (Double, Double, Double)
        func dot(_ a: V, _ b: V) -> Double { a.0*b.0 + a.1*b.1 + a.2*b.2 }
        func cross(_ a: V, _ b: V) -> V {
            (a.1*b.2-a.2*b.1, a.2*b.0-a.0*b.2, a.0*b.1-a.1*b.0)
        }
        func norm(_ a: V) -> Double { sqrt(dot(a, a)) }
        func ac(_ x: Double) -> Double { acos(max(-1, min(1, x))) }

        // Rotate J2000 input into TEME before recovering elements, matching CardSat.
        let r: V = frame == 1 ? j2000ToTeme((rx, ry, rz), epoch: epoch) : (rx, ry, rz)
        let v: V = frame == 1 ? j2000ToTeme((vx, vy, vz), epoch: epoch) : (vx, vy, vz)
        let radius = norm(r), speed2 = dot(v, v)
        guard radius > 0 else { return [row("error", "position vector is zero")] }
        let h = cross(r, v), hmag = norm(h)
        guard hmag > 1e-9 else { return [row("error", "degenerate orbit (zero angular momentum)")] }
        let node: V = (-h.1, h.0, 0)
        let nmag = hypot(node.0, node.1), rv = dot(r, v)
        let ev: V = (
            ((speed2 - muKm/radius)*r.0 - rv*v.0)/muKm,
            ((speed2 - muKm/radius)*r.1 - rv*v.1)/muKm,
            ((speed2 - muKm/radius)*r.2 - rv*v.2)/muKm
        )
        let ecc = norm(ev), energy = speed2/2 - muKm/radius
        guard energy < 0 else { return [row("error", "non-elliptical orbit")] }
        let a = -muKm/(2*energy)
        let incl = ac(h.2/hmag)*180/Double.pi
        var raan = nmag > 1e-9 ? ac(node.0/nmag)*180/Double.pi : 0
        if nmag > 1e-9 && node.1 < 0 { raan = 360-raan }
        var argp = nmag > 1e-9 && ecc > 1e-9 ? ac(dot(node,ev)/(nmag*ecc))*180/Double.pi : 0
        if nmag > 1e-9 && ecc > 1e-9 && ev.2 < 0 { argp = 360-argp }
        var nu = 0.0
        if ecc > 1e-9 {
            nu = ac(dot(ev,r)/(ecc*radius)); if rv < 0 { nu = 2*Double.pi-nu }
        } else if nmag > 1e-9 {
            nu = ac((node.0*r.0+node.1*r.1)/(nmag*radius)); if r.2 < 0 { nu = 2*Double.pi-nu }
        }
        let eccentricAnomaly = atan2(sqrt(max(0,1-ecc*ecc))*sin(nu), ecc+cos(nu))
        let meanAnomalyRad = eccentricAnomaly - ecc*sin(eccentricAnomaly)
        let meanAnomaly = (meanAnomalyRad*180/Double.pi+360).truncatingRemainder(dividingBy:360)
        let meanMotion = sqrt(muKm/pow(a,3))*86400/(2*Double.pi)
        return [
            row("Semi-major a",String(format:"%.1f km",a)),
            row("Eccentricity",String(format:"%.6f",ecc)),
            row("Inclination",String(format:"%.4f deg",incl)),
            row("RAAN",String(format:"%.4f deg",raan)),
            row("Arg perigee",String(format:"%.4f deg",argp)),
            row("Mean anomaly",String(format:"%.4f deg",meanAnomaly)),
            row("Mean motion",String(format:"%.8f rev/day",meanMotion)),
            row("Period",String(format:"%.2f min",1440/meanMotion)),
            row("Apogee",String(format:"%.1f km",a*(1+ecc)-earthKm),"altitude"),
            row("Perigee",String(format:"%.1f km",a*(1-ecc)-earthKm),"altitude"),
            row("note","osculating elements","SGP4 wants mean elements")
        ]
    }

    /// The same TEME state-vector → classical-elements recovery, returned as a
    /// ManualSatelliteDefinition (epoch = supplied time) so the derived orbit can
    /// be added to the catalog or exported. Returns nil for non-elliptical input.
    static func stateVectorDefinition(rx: Double, ry: Double, rz: Double,
                                      vx: Double, vy: Double, vz: Double,
                                      frame: Int = 0, epoch: Date) -> ManualSatelliteDefinition? {
        typealias V = (Double, Double, Double)
        func dot(_ a: V, _ b: V) -> Double { a.0*b.0 + a.1*b.1 + a.2*b.2 }
        func cross(_ a: V, _ b: V) -> V { (a.1*b.2-a.2*b.1, a.2*b.0-a.0*b.2, a.0*b.1-a.1*b.0) }
        func norm(_ a: V) -> Double { sqrt(dot(a, a)) }
        func ac(_ x: Double) -> Double { acos(max(-1, min(1, x))) }
        let r: V = frame == 1 ? j2000ToTeme((rx, ry, rz), epoch: epoch) : (rx, ry, rz)
        let v: V = frame == 1 ? j2000ToTeme((vx, vy, vz), epoch: epoch) : (vx, vy, vz)
        let radius = norm(r), speed2 = dot(v, v)
        guard radius > 0 else { return nil }
        let h = cross(r, v), hmag = norm(h)
        guard hmag > 1e-9 else { return nil }
        let node: V = (-h.1, h.0, 0), nmag = hypot(node.0, node.1), rv = dot(r, v)
        let ev: V = (((speed2 - muKm/radius)*r.0 - rv*v.0)/muKm,
                     ((speed2 - muKm/radius)*r.1 - rv*v.1)/muKm,
                     ((speed2 - muKm/radius)*r.2 - rv*v.2)/muKm)
        let ecc = norm(ev), energy = speed2/2 - muKm/radius
        guard energy < 0, ecc < 1 else { return nil }
        let a = -muKm/(2*energy)
        let incl = ac(h.2/hmag)*180/Double.pi
        var raan = nmag > 1e-9 ? ac(node.0/nmag)*180/Double.pi : 0
        if nmag > 1e-9 && node.1 < 0 { raan = 360-raan }
        var argp = nmag > 1e-9 && ecc > 1e-9 ? ac(dot(node,ev)/(nmag*ecc))*180/Double.pi : 0
        if nmag > 1e-9 && ecc > 1e-9 && ev.2 < 0 { argp = 360-argp }
        var nu = 0.0
        if ecc > 1e-9 { nu = ac(dot(ev,r)/(ecc*radius)); if rv < 0 { nu = 2*Double.pi-nu } }
        else if nmag > 1e-9 { nu = ac((node.0*r.0+node.1*r.1)/(nmag*radius)); if r.2 < 0 { nu = 2*Double.pi-nu } }
        let ea = atan2(sqrt(max(0,1-ecc*ecc))*sin(nu), ecc+cos(nu))
        let ma = ((ea - ecc*sin(ea))*180/Double.pi + 360).truncatingRemainder(dividingBy: 360)
        let n = sqrt(muKm/pow(a,3))*86400/(2*Double.pi)
        guard n > 0, n.isFinite else { return nil }
        return ManualSatelliteDefinition(name: "State-vector orbit", norad: 99001, epoch: epoch,
                                         inclinationDeg: incl, raanDeg: raan, eccentricity: ecc,
                                         argumentOfPerigeeDeg: argp, meanAnomalyDeg: ma,
                                         meanMotionRevPerDay: n, bstar: 0)
    }

    static func stateSanity(rx:Double,ry:Double,rz:Double,vx:Double,vy:Double,vz:Double)->[ToolResult]{
        let r=hypot(hypot(rx,ry),rz),v=hypot(hypot(vx,vy),vz),circ=r>0 ? sqrt(muKm/r):0,ratio=circ>0 ? v/circ:0
        var notes:[String]=[];var ok=true
        if r<6500{notes.append("position is inside Earth — meters?");ok=false}else if r>500000{notes.append("position beyond cislunar space — check units");ok=false}
        if v<0.5{notes.append("velocity very low — m/s rather than km/s?");ok=false}else if v>15{notes.append("velocity exceeds escape — check units");ok=false}
        if ok && !(0.5<ratio && ratio<1.45){notes.append(String(format:"speed is %.2fx circular; highly eccentric or inconsistent",ratio))}
        if notes.isEmpty{notes=["vector looks self-consistent"]}
        var out=[row("Radius",String(format:"%.1f km",r)),row("Speed",String(format:"%.3f km/s",v)),row("Circular speed",String(format:"%.3f km/s",circ),"at this radius"),row("Speed ratio",String(format:"%.3f",ratio),"1.0 = circular"),row("Plausible",ok && 0.5<ratio && ratio<1.45 ? "yes":"NO")]
        out += notes.map{row("",$0)};return out
    }

    static func orbitalThermal(alt:Double,units:Double,mass:Double,alpha:Double,epsilon:Double,power:Double,beta:Double,attitude:Int)->[ToolResult]{
        let sigma=5.670374419e-8,solar=1361.0,albedo=0.30,earthIR=237.0,cp=900.0
        let h=max(100,alt),m=max(0.1,mass),a=max(0.05,min(1,alpha)),e=max(0.05,min(1,epsilon)),p=max(0,power),u=max(1,Int(units))
        let side=0.1,len=0.1*Double(u),end=side*side,long=side*len,total=2*end+4*long,sunArea=attitude==1 ? max(end,long):total/4,earthArea=total/4
        let rr=earthKm/(earthKm+h),betaStar=acos(max(-1,min(1,rr)))*180/Double.pi
        let eclipseFrac:Double;if abs(beta)>=betaStar{eclipseFrac=0}else{let cb=cos(beta*Double.pi/180),num=sqrt(max(0,1-rr*rr))/max(cb,1e-6);eclipseFrac=acos(max(-1,min(1,num)))/Double.pi}
        let earthView=rr*rr
        func qin(_ sun:Double)->Double{a*solar*sunArea*sun+a*albedo*solar*earthArea*earthView*sun+e*earthIR*earthArea*earthView+p}
        func teq(_ sun:Double)->Double{pow(qin(sun)/(e*sigma*total),0.25)}
        let ts=teq(1),te=teq(0),period=2*Double.pi*sqrt(pow(earthKm+h,3)/muKm),heat=m*cp,eclStart=period*(1-eclipseFrac),steps=240,dt=period/Double(steps)
        var t=ts,tmin=t,tmax=t
        for orbit in 0..<2{var tt=0.0;for _ in 0..<steps{let sun=tt<eclStart ? 1.0:0.0,qout=e*sigma*total*pow(t,4);t+=(qin(sun)-qout)/heat*dt;t=max(3,t);if orbit==1{tmin=min(tmin,t);tmax=max(tmax,t)};tt+=dt}}
        return [row("Beta angle",String(format:"%+.1f°",beta)),row("Eclipse fraction",String(format:"%.1f %%",eclipseFrac*100),eclipseFrac==0 ? "continuous sun":""),row("Orbit period",String(format:"%.1f min",period/60)),row("Radiating area",String(format:"%.4f m²",total)),row("Sun-facing area",String(format:"%.4f m²",sunArea),attitude==1 ? "Sun-pointing":"Tumbling"),row("Sunlit equilibrium",String(format:"%.0f °C",ts-273.15)),row("Eclipse equilibrium",String(format:"%.0f °C",te-273.15)),row("Transient min",String(format:"%.0f °C",tmin-273.15)),row("Transient max",String(format:"%.0f °C",tmax-273.15)),row("Mean / swing",String(format:"%.0f °C / %.0f °C",0.5*(tmin+tmax)-273.15,tmax-tmin)),row("model","first-order, single node","not flight analysis")]
    }

    static func charLookup(_ raw: Double) -> [ToolResult] {
        let value = Int(raw) & 0xff, controls=["NUL","SOH","STX","ETX","EOT","ENQ","ACK","BEL","BS","TAB","LF","VT","FF","CR","SO","SI","DLE","DC1","DC2","DC3","DC4","NAK","SYN","ETB","CAN","EM","SUB","ESC","FS","GS","RS","US","SP"]
        let ltrs=["NUL","E","LF","A","SP","S","I","U","CR","D","R","J","N","F","C","K","T","Z","L","W","H","Y","P","Q","O","B","G","FIGS","M","X","V","LTRS"]
        let figs=["NUL","3","LF","-","SP","BEL","8","7","CR","$","4","'",",","!",":","(","5","\"",")","2","#","6","0","1","9","?","&","FIGS",".","/",";","LTRS"]
        let morse:[Character:String] = ["A":".-","B":"-...","C":"-.-.","D":"-..","E":".","F":"..-.","G":"--.","H":"....","I":"..","J":".---","K":"-.-","L":".-..","M":"--","N":"-.","O":"---","P":".--.","Q":"--.-","R":".-.","S":"...","T":"-","U":"..-","V":"...-","W":".--","X":"-..-","Y":"-.--","Z":"--..","0":"-----","1":".----","2":"..---","3":"...--","4":"....-","5":".....","6":"-....","7":"--...","8":"---..","9":"----."]
        var out=[row("Hex",String(format:"0x%02X",value)),row("Decimal","\(value)"),row("Octal",String(value,radix:8).prefix(1)=="0" ? String(value,radix:8):"0o"+String(value,radix:8)),row("Binary",String(value,radix:2).leftPadded(to:8,with:"0"))]
        let ascii:String;if value<33{ascii=controls[value]+" (control)"}else if value==127{ascii="DEL (control)"}else if value<127{ascii=String(UnicodeScalar(value)!)}else{ascii="(not 7-bit ASCII)"};out.append(row("ASCII",ascii))
        if value>32,value<127,let m=morse[Character(String(UnicodeScalar(value)!).uppercased())]{out.append(row("Morse",m))}
        if value<32{out.append(row("ITA2 letters",ltrs[value]));out.append(row("ITA2 figures",figs[value]))}
        let hi=value>>4,lo=value&0xf;out.append(row("BCD",hi<10 && lo<10 ? "\(hi)\(lo)":"invalid (nibble > 9)"));return out
    }

    static let unitFamilies: [(String, [(String, Double)])] = [
        ("Length",[("m",1),("km",1000),("cm",0.01),("mm",0.001),("in",0.0254),("ft",0.3048),("yd",0.9144),("mi",1609.344),("nmi",1852)]),
        ("Mass",[("kg",1),("g",0.001),("lb",0.45359237),("oz",0.028349523),("t",1000)]),
        ("Power",[("W",1),("mW",0.001),("kW",1000),("hp",745.6999)]),
        ("Frequency",[("Hz",1),("kHz",1e3),("MHz",1e6),("GHz",1e9)]),
        ("Speed",[("m/s",1),("km/h",1/3.6),("mph",0.44704),("kt",0.514444)]),
        ("Angle",[("deg",1),("rad",57.29577951308232),("arcmin",1/60),("arcsec",1/3600)]),
        ("Temperature",[("C",1),("F",1),("K",1)])
    ]

    static func unitConvert(value:Double,family:Int,from:Int,to:Int)->[ToolResult]{
        let fam=unitFamilies[max(0,min(unitFamilies.count-1,family))],units=fam.1,fi=max(0,min(units.count-1,from)),ti=max(0,min(units.count-1,to)),fu=units[fi].0,tu=units[ti].0
        func tempC(_ v:Double,_ u:String)->Double{u=="C" ? v:u=="F" ? (v-32)*5/9:v-273.15};func fromC(_ c:Double,_ u:String)->Double{u=="C" ? c:u=="F" ? c*9/5+32:c+273.15}
        func convert(_ v:Double,_ a:(String,Double),_ b:(String,Double))->Double{fam.0=="Temperature" ? fromC(tempC(v,a.0),b.0):v*a.1/b.1}
        let main=convert(value,units[fi],units[ti]);var out=[row(String(format:"%g %@",value,fu),String(format:"%g %@",main,tu)),row("— all units",fam.0,"—")]
        for u in units where u.0 != fu{out.append(row(u.0,String(format:"%g",convert(value,units[fi],u))))};return out
    }

    static func programmer(raw:String,base:Int,width:Int)->[ToolResult]{
        let cleaned=raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"_",with:"").replacingOccurrences(of:" ",with:"")
        let negative=cleaned.hasPrefix("-"),body=negative ? String(cleaned.dropFirst()):cleaned,lower=body.lowercased();let radix:Int;let digits:String
        if lower.hasPrefix("0x"){radix=16;digits=String(lower.dropFirst(2))}else if lower.hasPrefix("0b"){radix=2;digits=String(lower.dropFirst(2))}else if lower.hasPrefix("0o"){radix=8;digits=String(lower.dropFirst(2))}else{radix=[10,16,2,8][max(0,min(3,base))];digits=lower}
        guard let parsed=Int64(digits,radix:radix) else{return[row("error","not a valid value")]};let signed=negative ? -parsed:parsed,w=[8,16,32,64].contains(width) ? width:32,mask=w==64 ? UInt64.max:(UInt64(1)<<UInt64(w))-1,uv=UInt64(bitPattern:signed)&mask,bits=String(uv,radix:2).leftPadded(to:w,with:"0"),grouped=stride(from:0,to:w,by:4).map{String(bits.dropFirst($0).prefix(4))}.joined(separator:" ")
        var out=[row("Decimal","\(signed)"),row("Hex","0x"+String(uv,radix:16).uppercased()),row("Octal","0o"+String(uv,radix:8)),row("Binary","0b"+(String(uv,radix:2))),row("Grouped",grouped,"\(w)-bit"),row("Bits set","\(uv.nonzeroBitCount)","population count")]
        if signed<0{out.append(row("Two's complement","0x"+String(uv,radix:16).uppercased(),"at \(w) bits"))};return out
    }
}

/// What anchored a decay estimate — an observed n-dot trend, the B* drag term,
/// or nothing usable. Replaces brittle string-sentinel comparisons.
enum DecayAnchor: Sendable, Equatable {
    case observedNdot, bstar, noData
    var label: String {
        switch self {
        case .observedNdot: "observed decay rate"
        case .bstar: "B* drag term"
        case .noData: "no usable data"
        }
    }
}

enum OrbitDecayModel {
    static let mu = 3.986004418e14, re = 6.378137e6, twoPi = 2 * Double.pi
    static let atmosphere:[(Double,Double,Double)] = [(100,5.297e-7,5.877),(110,9.661e-8,7.263),(120,2.438e-8,9.473),(130,8.484e-9,12.636),(140,3.845e-9,16.149),(150,2.070e-9,22.523),(180,5.464e-10,29.740),(200,2.789e-10,37.105),(250,7.248e-11,45.546),(300,2.418e-11,53.628),(350,9.518e-12,53.298),(400,3.725e-12,58.515),(450,1.585e-12,60.828),(500,6.967e-13,63.822),(600,1.454e-13,71.835),(700,3.614e-14,88.667),(800,1.170e-14,124.64),(900,5.245e-15,181.05),(1000,3.019e-15,268)]
    static func band(_ h:Double)->(Double,Double,Double){var idx=0;for i in 0..<(atmosphere.count-1){if h<atmosphere[i+1].0{idx=i;break};idx=i+1};return atmosphere[idx]}
    static func density(_ h:Double)->Double{guard h<1100 else{return 0};let b=band(max(100,h));return b.1*exp(-(h-b.0)/b.2)}
    static func scaleHeight(_ h:Double)->Double{band(max(100,h)).2*1000}
    static func densCal(_ h:Double)->Double{min(8,1.30*exp((h-250)/300))}
    static func i0e(_ z:Double)->Double{if z<3.75{let t=pow(z/3.75,2),v=1+t*(3.5156229+t*(3.0899424+t*(1.2067492+t*(0.2659732+t*(0.0360768+t*0.0045813)))));return v*exp(-z)};let t=3.75/z;return (0.39894228+t*(0.01328592+t*(0.00225319+t*(-0.00157565+t*(0.00916281+t*(-0.02057706+t*(0.02635537+t*(-0.01647633+t*0.00392377))))))))/sqrt(z)}
    static func i1e(_ z:Double)->Double{if z<3.75{let t=pow(z/3.75,2),v=z*(0.5+t*(0.87890594+t*(0.51498869+t*(0.15084934+t*(0.02658733+t*(0.00301532+t*0.00032411))))));return v*exp(-z)};let t=3.75/z;return (0.39894228+t*(-0.03988024+t*(-0.00362018+t*(0.00163801+t*(-0.01031555+t*(0.02282967+t*(-0.02895312+t*(0.01787654+t*(-0.00420059)))))))))/sqrt(z)}
    static func kingHele(a:Double,e:Double,h:Double)->Double{if e<=1e-4{return 1};let z=a*e/scaleHeight(h);if z<=0.05{return 1};return i0e(z)+2*e*i1e(z)}
    static func estimate(meanMotion:Double,ecc:Double,bstar:Double,ndot:Double,solar:Int)->(Double,DecayAnchor){
        let scales=[0.35,1.0,3.0],densScale=scales[max(0,min(2,solar))];guard meanMotion>0 else{return(-1,.noData)};let nn=meanMotion*twoPi/86400;var a=pow(mu/(nn*nn),1.0/3),e=min(0.95,max(0,ecc)),rp=a*(1-e),ra=a*(1+e),hp0=(rp-re)/1000;if hp0<80{return(0,.noData)}
        func rho(_ h:Double)->Double{density(h)*densScale*densCal(h)};var ballistic=0.0;var src: DecayAnchor = .bstar;let adot = -(2.0/3.0)*(a/meanMotion)*(2*ndot),rho0=rho(hp0)
        if adot < -0.5,rho0>0,hp0<1000{let cand=1.15*(-adot/86400)/(rho0*sqrt(mu*a)*kingHele(a:a,e:e,h:hp0));if cand>1e-4 && cand<50{ballistic=cand;src = .observedNdot}}
        if ballistic==0{guard bstar>0 else{return(-1,.noData)};ballistic=12.741621*bstar}
        var days=0.0
        for _ in 0..<200000{let hp=rp-re,h=hp/1000;a=0.5*(rp+ra);let ec=(ra-rp)/(ra+rp),end=ec<=0.02 ? 120e3:90e3;if hp<end{return(days,src)};let densityNow=rho(h);if densityNow<=0{return(Double.infinity,src)};let dadt = -ballistic*densityNow*sqrt(mu*a)*kingHele(a:a,e:ec,h:h);if dadt>=0{return(Double.infinity,src)};var dt = -((hp-120e3)*0.20+500)/dadt;let cap=h<200 ? 0.15:h<350 ? 2.0:20.0;dt=min(dt,cap*86400);dt=max(dt,1);let da=dadt*dt;if ec>1e-3{ra+=2*da;if ra<rp{let mid=0.5*(ra+rp);ra=mid;rp=mid}}else{ra+=da;rp+=da};days+=dt/86400;if days>36500{return(Double.infinity,src)}}
        return(days,src)
    }

    /// Orbital lifetime for a satellite that is still on the bench — driven by its
    /// physical ballistic coefficient (Cd·A/m) rather than a fitted B*/n-dot. Uses
    /// the same King-Hele decay integrator as `estimate` so the two agree when
    /// 12.741621·B* equals Cd·A/m. Returns days (Double.infinity if effectively stable).
    static func lifetimeFromArea(perigeeAltKm:Double,apogeeAltKm:Double,massKg:Double,areaM2:Double,cd:Double,solar:Int)->Double{
        let scales=[0.35,1.0,3.0],densScale=scales[max(0,min(2,solar))]
        guard massKg>0,areaM2>0,cd>0 else{return -1}
        let ballistic=cd*areaM2/massKg   // Cd·A/m, m²/kg — same units as 12.741621·B*
        var rp=re+max(perigeeAltKm,0)*1000,ra=re+max(apogeeAltKm,perigeeAltKm)*1000
        let hp0=(rp-re)/1000;if hp0<80{return 0}
        func rho(_ h:Double)->Double{density(h)*densScale*densCal(h)}
        var days=0.0
        for _ in 0..<200000{let hp=rp-re,h=hp/1000;let a=0.5*(rp+ra);let ec=(ra-rp)/(ra+rp),end=ec<=0.02 ? 120e3:90e3;if hp<end{return days};let densityNow=rho(h);if densityNow<=0{return Double.infinity};let dadt = -ballistic*densityNow*sqrt(mu*a)*kingHele(a:a,e:ec,h:h);if dadt>=0{return Double.infinity};var dt = -((hp-120e3)*0.20+500)/dadt;let cap=h<200 ? 0.15:h<350 ? 2.0:20.0;dt=min(dt,cap*86400);dt=max(dt,1);let da=dadt*dt;if ec>1e-3{ra+=2*da;if ra<rp{let mid=0.5*(ra+rp);ra=mid;rp=mid}}else{ra+=da;rp+=da};days+=dt/86400;if days>36500{return Double.infinity}}
        return days
    }
}

extension String {
    fileprivate func leftPadded(to count: Int, with char: Character) -> String {
        self.count >= count ? self : String(repeating: String(char), count: count - self.count) + self
    }
}

extension BenchTools {
    static let deepParity2Tools: [ToolDefinition] = [
        .init(id:"sciCalc",category:"General",name:"Scientific calculator",description:"Infix evaluator (degrees). Trig/inverse/hyperbolic, ln/log/log2/exp, sqrt/cbrt, fact/ncr/npr, sign/mod/hypot/min/max; constants pi,e,c,kb,Re,mu,g0; and RF/orbit helpers: fspl, dop, lam/fq, dipole, db/undb, dbm2w/w2dbm, dbd/dbi, swr2rl/rl2swr/mml, nf2t/t2nf, porb/vorb/fpr/aorb, slant, dgain.",fields:[.init(id:"expression",label:"Expression",defaultValue:0,unit:"",isText:true,defaultText:"porb(500)")]),
        .init(id:"programmer",category:"General",name:"Programmer calc (hex/bin)",description:"Decimal/hex/binary/octal conversion, popcount and two's-complement view.",fields:[.init(id:"value",label:"Value",defaultValue:255,unit:"",isText:true,defaultText:"255"),.init(id:"base",label:"Input base",defaultValue:0,unit:"",choices:["decimal","hex","binary","octal"]),.init(id:"width",label:"Width",defaultValue:2,unit:"bits",choices:["8","16","32","64"])]),
        .init(id:"unitConverter",category:"General",name:"Unit converter",description:"Length, mass, power, frequency, speed, angle and temperature conversions.",fields:[.init(id:"value",label:"Value",defaultValue:1,unit:""),.init(id:"family",label:"Family",defaultValue:0,unit:"",choices:DeepToolMath.unitFamilies.map{$0.0}),.init(id:"from",label:"From",defaultValue:0,unit:"",choices:["m","km","cm","mm","in","ft","yd","mi","nmi"]),.init(id:"to",label:"To",defaultValue:1,unit:"",choices:["m","km","cm","mm","in","ft","yd","mi","nmi"])]),
        .init(id:"charLookup",category:"General",name:"Character / byte lookup",description:"Byte value in four bases, ASCII, Morse, ITA2 and BCD.",fields:[.init(id:"value",label:"Byte value",defaultValue:65,unit:"")]),
        .init(id:"dxccLookup",category:"General",name:"DXCC entity lookup",description:"Offline lookup over all 340 bundled DXCC entity reference points.",fields:[.init(id:"query",label:"Prefix or name",defaultValue:0,unit:"",isText:true,defaultText:"JA")]),
        .init(id:"gridConvert",category:"General",name:"Grid ↔ lat/lon",description:"Convert a Maidenhead locator to latitude/longitude, or “lat,lon” to a 6-character grid square.",fields:[.init(id:"loc",label:"Grid or lat,lon",defaultValue:0,unit:"",isText:true,defaultText:"FM18")]),
        .init(id:"ampacity",category:"Electronics & power",name:"Trace & wire ampacity",description:"IPC-2221 PCB trace width or chassis-wire ampacity.",fields:[.init(id:"mode",label:"Mode",defaultValue:0,unit:"",choices:["PCB external","PCB internal","Wire (AWG)"]),.init(id:"current",label:"Current",defaultValue:1,unit:"A"),.init(id:"rise",label:"Temp rise",defaultValue:10,unit:"°C"),.init(id:"copper",label:"Copper",defaultValue:1,unit:"oz"),.init(id:"awg",label:"Wire",defaultValue:24,unit:"AWG")]),
        .init(id:"toroid",category:"Electronics & power",name:"Toroid winding",description:"Turns required on common Amidon iron-powder/ferrite cores.",fields:[.init(id:"core",label:"Core",defaultValue:2,unit:"",choices:DeepToolMath.toroids.map{$0.0}),.init(id:"target",label:"Target L",defaultValue:10,unit:"µH")]),
        .init(id:"terrestrialBudget",category:"Terrestrial VHF/UHF",name:"Terrestrial path budget",description:"Two-way terrestrial link budget with nominal 12 kHz receiver noise floor.",fields:[.init(id:"power",label:"TX power",defaultValue:25,unit:"W"),.init(id:"txgain",label:"TX gain",defaultValue:6,unit:"dBi"),.init(id:"rxgain",label:"RX gain",defaultValue:6,unit:"dBi"),.init(id:"loss",label:"Line loss",defaultValue:2,unit:"dB"),.init(id:"freq",label:"Frequency",defaultValue:146,unit:"MHz"),.init(id:"distance",label:"Distance",defaultValue:50,unit:"km")]),
        .init(id:"terrainLOS",category:"Terrestrial VHF/UHF",name:"Terrain path (LOS)",description:"Manual worst-obstruction LOS check with Earth curvature and 60% Fresnel clearance.",fields:[.init(id:"path",label:"Path length",defaultValue:30,unit:"km"),.init(id:"obs",label:"Obstruction ht",defaultValue:200,unit:"m"),.init(id:"at",label:"Obstruction at",defaultValue:15,unit:"km"),.init(id:"txh",label:"TX ant HAAT",defaultValue:10,unit:"m"),.init(id:"rxh",label:"RX ant HAAT",defaultValue:10,unit:"m"),.init(id:"freq",label:"Frequency",defaultValue:146,unit:"MHz"),.init(id:"txg",label:"TX ground el",defaultValue:100,unit:"m"),.init(id:"rxg",label:"RX ground el",defaultValue:100,unit:"m")]),
        .init(id:"dopplerBudget",category:"Satellite & orbit",name:"Doppler budget (orbit)",description:"Peak Doppler shift and TCA rate expected from an orbit.",fields:[.init(id:"ap",label:"Apogee alt",defaultValue:550,unit:"km"),.init(id:"pe",label:"Perigee alt",defaultValue:550,unit:"km"),.init(id:"freq",label:"Frequency",defaultValue:435.5,unit:"MHz")]),
        .init(id:"orbitLifetime",category:"Satellite & orbit",name:"Orbit lifetime (decay)",description:"King-Hele decay integration anchored on observed n-dot where usable, otherwise B*.",fields:[.init(id:"mm",label:"Mean motion",defaultValue:15.50,unit:"rev/day"),.init(id:"ecc",label:"Eccentricity",defaultValue:0.0004,unit:""),.init(id:"bstar",label:"B*",defaultValue:0.00025,unit:""),.init(id:"ndot",label:"n-dot",defaultValue:0.0001,unit:"rev/day²"),.init(id:"solar",label:"Solar activity",defaultValue:1,unit:"",choices:["low","mean","high"])]),
        .init(id:"debrisCompliance",category:"Satellite & orbit",name:"Debris mitigation compliance",description:"Post-mission orbital lifetime for a spacecraft still on the bench, from its physical ballistic coefficient (mass, cross-sectional area, drag Cd). Checks the legacy 25-year and the current FCC 5-year deorbit rules. Get the cross-sectional area from the “Cross-section area” tool.",fields:[.init(id:"pe",label:"Perigee alt",defaultValue:550,unit:"km"),.init(id:"ap",label:"Apogee alt",defaultValue:550,unit:"km"),.init(id:"mass",label:"Mass",defaultValue:4,unit:"kg"),.init(id:"area",label:"Cross-section area",defaultValue:0.03,unit:"m²"),.init(id:"cd",label:"Drag coefficient",defaultValue:2.2,unit:""),.init(id:"solar",label:"Solar activity",defaultValue:1,unit:"",choices:["low","mean","high"])]),
        .init(id:"deltaV",category:"Satellite & orbit",name:"Delta-v (Hohmann/plane)",description:"Hohmann transfer, plane-change and illustrative deorbit Δv.",fields:[.init(id:"a1",label:"Alt 1",defaultValue:400,unit:"km"),.init(id:"a2",label:"Alt 2",defaultValue:800,unit:"km"),.init(id:"plane",label:"Plane change",defaultValue:0,unit:"°")]),
        .init(id:"pointingLoss",category:"Satellite & orbit",name:"Pointing loss",description:"Main-lobe dB loss from antenna pointing error and HPBW.",fields:[.init(id:"hpbw",label:"HPBW",defaultValue:30,unit:"°"),.init(id:"err",label:"Point error",defaultValue:3,unit:"°")]),
        .init(id:"linkElevation",category:"Satellite & orbit",name:"Link margin vs elevation",description:"Range-only margin improvement from horizon to overhead.",fields:[.init(id:"alt",label:"Altitude",defaultValue:550,unit:"km"),.init(id:"freq",label:"Frequency",defaultValue:435,unit:"MHz"),.init(id:"margin",label:"Margin @0°",defaultValue:6,unit:"dB")]),
        .init(id:"faraday",category:"Satellite & orbit",name:"Polarization / Faraday",description:"Order-of-magnitude ionospheric Faraday rotation for linear polarization.",fields:[.init(id:"freq",label:"Frequency",defaultValue:145.9,unit:"MHz"),.init(id:"condition",label:"Ionosphere",defaultValue:0,unit:"",choices:["Quiet (10 TECU)","Moderate (30)","Storm (80)"])]),
        .init(id:"stateVector",category:"Satellite & orbit",name:"State vector → GP",description:"Recover classical osculating orbital elements from a TEME position/velocity vector.",fields:[.init(id:"rx",label:"Pos X",defaultValue:-4400,unit:"km"),.init(id:"ry",label:"Pos Y",defaultValue:-5100,unit:"km"),.init(id:"rz",label:"Pos Z",defaultValue:0,unit:"km"),.init(id:"vx",label:"Vel X",defaultValue:3.6,unit:"km/s"),.init(id:"vy",label:"Vel Y",defaultValue:-3.1,unit:"km/s"),.init(id:"vz",label:"Vel Z",defaultValue:6,unit:"km/s"),.init(id:"frame",label:"Input frame",defaultValue:0,unit:"",choices:["TEME","J2000 (→TEME)"])]),
        .init(id:"stateSanity",category:"Satellite & orbit",name:"State vector sanity",description:"Unit/plausibility diagnostics before trusting a state-vector fit.",fields:[.init(id:"rx",label:"Rx",defaultValue:6800,unit:"km"),.init(id:"ry",label:"Ry",defaultValue:0,unit:"km"),.init(id:"rz",label:"Rz",defaultValue:0,unit:"km"),.init(id:"vx",label:"Vx",defaultValue:0,unit:"km/s"),.init(id:"vy",label:"Vy",defaultValue:7.66,unit:"km/s"),.init(id:"vz",label:"Vz",defaultValue:0,unit:"km/s")]),
        .init(id:"orbitalThermal",category:"Satellite & orbit",name:"Orbital thermal (CubeSat)",description:"First-order single-node orbital thermal model including Sun, albedo, Earth IR and eclipse.",fields:[.init(id:"alt",label:"Altitude",defaultValue:550,unit:"km"),.init(id:"units",label:"Size",defaultValue:3,unit:"U"),.init(id:"mass",label:"Mass",defaultValue:4,unit:"kg"),.init(id:"alpha",label:"Absorptivity α",defaultValue:0.35,unit:""),.init(id:"eps",label:"Emissivity ε",defaultValue:0.85,unit:""),.init(id:"power",label:"Internal power",defaultValue:2,unit:"W"),.init(id:"beta",label:"Beta angle",defaultValue:0,unit:"°"),.init(id:"attitude",label:"Attitude",defaultValue:0,unit:"",choices:["Tumbling","Sun-pointing"])]),
        .init(id:"linkMargin",category:"Satellite & orbit",name:"Link margin curve",description:"Received power and sensitivity margin from horizon to zenith for a nominal 0 dBm EIRP / 0 dBi receive system.",fields:[.init(id:"alt",label:"Satellite alt",defaultValue:500,unit:"km"),.init(id:"freq",label:"Frequency",defaultValue:145.8,unit:"MHz"),.init(id:"sens",label:"RX sensitivity",defaultValue:-120,unit:"dBm")])
    ]

    static func deepParity2Results(for id:String, raw:[String:String], values:[String:Double])->[ToolResult]? {
        func v(_ k:String,_ d:Double=0)->Double{values[k] ?? d}
        switch id {
        case "sciCalc": do { let x=try SafeMathEvaluator().evaluate(raw["expression"]?.isEmpty == false ? raw["expression"]! : "300/145.9", degrees: true); return [.init(label:"Result",value:String(format:"%g",x),note:""),.init(label:"Full precision",value:String(describing:x),note:"")] } catch { return [.init(label:"error",value:error.localizedDescription,note:"")] }
        case "programmer": return DeepToolMath.programmer(raw:raw["value"]?.isEmpty == false ? raw["value"]! : "255",base:Int(v("base")),width:[8,16,32,64][max(0,min(3,Int(v("width"))))])
        case "unitConverter": return DeepToolMath.unitConvert(value:v("value",1),family:Int(v("family")),from:Int(v("from")),to:Int(v("to",1)))
        case "charLookup": return DeepToolMath.charLookup(v("value",65))
        case "dxccLookup":
            let query = raw["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "JA"
            let effective = query.isEmpty ? "JA" : query
            if let code = Int(effective), let name = DXCCNumericData.nameByCode[code] {
                let coordinate = DXCCNumericData.byCode[code]
                let prefix = DXCCData.entities.first(where: { $0.name == name })?.prefix ?? ""
                let note: String
                if let coordinate {
                    note = String(format:"%.2f°, %.2f°%@", coordinate.latitude, coordinate.longitude, prefix.isEmpty ? "" : " · \(prefix)")
                } else {
                    note = prefix.isEmpty ? "no current reference coordinate" : "\(prefix) · no current reference coordinate"
                }
                return [.init(label:"ARRL \(code)", value:name, note:note)]
            }
            let hits = DXCCData.search(effective, limit: 8)
            if hits.isEmpty { return [.init(label:"DXCC",value:"no match",note:effective)] }
            return hits.map { entity in
                let code = DXCCNumericData.codeByName[entity.name]
                let label = code.map { "ARRL \($0) · \(entity.prefix)" } ?? entity.prefix
                return .init(label: label, value: entity.name, note: String(format:"%.1f°, %.1f°", entity.latitude, entity.longitude))
            }
        case "gridConvert":
            let input = (raw["loc"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "FM18"
            guard let ll = FeatureEngine.parseLocation(input) else {
                return [.init(label:"Grid ↔ lat/lon", value:"unrecognized", note:"Enter a Maidenhead grid (e.g. FM18lv) or “lat,lon”.")]
            }
            let grid = FeatureEngine.latLonToGrid6(latitude: ll.latitude, longitude: ll.longitude)
            return [
                .init(label:"Latitude", value:String(format:"%+.5f°", ll.latitude), note:""),
                .init(label:"Longitude", value:String(format:"%+.5f°", ll.longitude), note:""),
                .init(label:"Maidenhead", value:grid, note:"6-character locator")
            ]
        case "ampacity": return DeepToolMath.ampacity(mode:Int(v("mode")),current:v("current",1),rise:v("rise",10),copperOz:v("copper",1),awg:v("awg",24))
        case "toroid": return DeepToolMath.toroid(index:Int(v("core")),targetUH:v("target",10))
        case "terrestrialBudget": return DeepToolMath.terrestrialBudget(txPowerW:v("power",25),txGain:v("txgain",6),rxGain:v("rxgain",6),lineLoss:v("loss",2),freqMHz:v("freq",146),distanceKm:v("distance",50))
        case "terrainLOS": return DeepToolMath.terrainLOS(pathKm:v("path",30),obstructionM:v("obs",200),atKm:v("at",15),txHAAT:v("txh",10),rxHAAT:v("rxh",10),freqMHz:v("freq",146),txGround:v("txg",100),rxGround:v("rxg",100))
        case "dopplerBudget": return DeepToolMath.dopplerBudget(apogeeKm:v("ap",550),perigeeKm:v("pe",550),freqMHz:v("freq",435.5))
        case "orbitLifetime": let r=OrbitDecayModel.estimate(meanMotion:v("mm",15.5),ecc:v("ecc",0.0004),bstar:v("bstar",0.00025),ndot:v("ndot",0.0001),solar:Int(v("solar",1))); let life=r.0<0 ? "no usable data" : r.0.isInfinite ? "effectively stable" : r.0<365.25 ? String(format:"%.0f days",r.0):String(format:"%.1f years",r.0/365.25); return [.init(label:"Lifetime",value:life,note:""),.init(label:"Anchor",value:r.1.label,note:r.1 == .observedNdot ? "measured":"modeled"),.init(label:"Solar activity",value:["low","mean","high"][max(0,min(2,Int(v("solar",1))))],note:""),.init(label:"25-year rule",value:(!r.0.isInfinite && r.0>=0 && r.0<=25*365.25) ? "OK":"EXCEEDS",note:""),.init(label:"5-year rule",value:(!r.0.isInfinite && r.0>=0 && r.0<=5*365.25) ? "OK":"EXCEEDS",note:"")]
        case "debrisCompliance":
            let pe=v("pe",550),ap=max(v("ap",550),pe),mass=v("mass",4),area=v("area",0.03),cd=v("cd",2.2),sol=Int(v("solar",1))
            let d=OrbitDecayModel.lifetimeFromArea(perigeeAltKm:pe,apogeeAltKm:ap,massKg:mass,areaM2:area,cd:cd,solar:sol)
            let bc = (cd>0 && area>0) ? mass/(cd*area) : 0
            let life = d<0 ? "insufficient input" : d.isInfinite ? "> 100 years (effectively stable)" : d<365.25 ? String(format:"%.0f days",d) : String(format:"%.1f years",d/365.25)
            let finite = d>=0 && !d.isInfinite
            return [.init(label:"Ballistic coeff m/(Cd·A)",value:String(format:"%.1f kg/m²",bc),note:"higher decays slower"),
                    .init(label:"Est. post-mission lifetime",value:life,note:d.isInfinite ? "no natural reentry within 100 yr":""),
                    .init(label:"25-year rule (legacy)",value:(finite && d<=25*365.25) ? "OK":"EXCEEDS",note:""),
                    .init(label:"5-year rule (FCC 2024)",value:(finite && d<=5*365.25) ? "OK":"EXCEEDS",note:""),
                    .init(label:"Solar activity",value:["low","mean","high"][max(0,min(2,sol))],note:"first-order estimate")]
        case "deltaV": return DeepToolMath.deltaV(alt1:v("a1",400),alt2:v("a2",800),planeDeg:v("plane"))
        case "pointingLoss": return DeepToolMath.pointingLoss(hpbw:v("hpbw",30),error:v("err",3))
        case "linkElevation": return DeepToolMath.linkElevation(alt:v("alt",550),freq:v("freq",435),margin0:v("margin",6))
        case "faraday": return DeepToolMath.faraday(freqMHz:v("freq",145.9),condition:Int(v("condition")))
        case "stateVector": return DeepToolMath.stateVector(rx:v("rx"),ry:v("ry"),rz:v("rz"),vx:v("vx"),vy:v("vy"),vz:v("vz"),frame:Int(v("frame")),epoch:Date())
        case "stateSanity": return DeepToolMath.stateSanity(rx:v("rx"),ry:v("ry"),rz:v("rz"),vx:v("vx"),vy:v("vy"),vz:v("vz"))
        case "orbitalThermal": return DeepToolMath.orbitalThermal(alt:v("alt",550),units:v("units",3),mass:v("mass",4),alpha:v("alpha",0.35),epsilon:v("eps",0.85),power:v("power",2),beta:v("beta"),attitude:Int(v("attitude")))
        case "linkMargin": let alt=v("alt",500),freq=v("freq",145.8),sens=v("sens",-120);guard alt>0,freq>0 else{return [.init(label:"error",value:"need altitude/frequency > 0",note:"")]};func range(_ el:Double)->Double{let e=el*Double.pi/180,se=sin(e);return sqrt(DeepToolMath.earthKm*DeepToolMath.earthKm*se*se+2*DeepToolMath.earthKm*alt+alt*alt)-DeepToolMath.earthKm*se};return [0.0,10,20,30,45,60,90].map{el in let rng=range(el),loss=32.44+20*log10(rng)+20*log10(freq),rx = -loss,margin=rx-sens;return .init(label:String(format:"%.0f° elevation",el),value:String(format:"%.1f dBm",rx),note:String(format:"%+.1f dB margin, %.0f km",margin,rng))}
        default:return nil
        }
    }

    static func unitChoices(familyIndex:Int)->[String]{ DeepToolMath.unitFamilies[max(0,min(DeepToolMath.unitFamilies.count-1,familyIndex))].1.map{$0.0} }
}
