import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SatelliteKit

struct CelestialPoint: Identifiable, Sendable {
    let id: String
    let name: String
    let azimuth: Double
    let elevation: Double
    let category: String
}

struct SunMoonSnapshot: Sendable {
    let date: Date
    let sunAzimuth: Double
    let sunElevation: Double
    let moonAzimuth: Double
    let moonElevation: Double
    let moonPhaseAngle: Double
    let moonIllumination: Double
    let moonDistanceKm: Double

    var moonPhaseName: String {
        let names = [
            "New", "Waxing crescent", "First quarter", "Waxing gibbous",
            "Full", "Waning gibbous", "Last quarter", "Waning crescent"
        ]
        let index = Int(((moonPhaseAngle + 22.5).truncatingRemainder(dividingBy: 360)) / 45.0) % 8
        return names[max(0, index)]
    }
}

struct MutualWindowRecord: Identifiable, Sendable {
    let id: Date
    let start: Date
    let end: Date
    let myMaxElevation: Double
    let dxMaxElevation: Double

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct TargetWindowRecord: Identifiable, Sendable {
    let id: Date
    let start: Date
    let end: Date
    let marginDegrees: Double

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct ConjunctionRecord: Identifiable, Sendable {
    let id: Date
    let date: Date
    let missDistanceKm: Double
    let relativeVelocityKmS: Double
}

struct OrbitalNeighbor: Identifiable, Sendable {
    let id: UInt
    let name: String
    let rangeKm: Double
    let relativeVelocityKmS: Double
}


struct SkyGlanceRow: Identifiable, Sendable {
    let id: UInt
    let name: String
    let passes: [PredictedPass]
}

struct EMEWindowRecord: Identifiable, Sendable {
    let id: Date
    let start: Date
    let end: Date
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct EMESnapshot: Sendable {
    let moonAzimuth: Double
    let moonElevation: Double
    let moonDistanceKm: Double
    let selfEchoDopplerHz: Double
    let pathLossDb: Double
    let coldSkyTemperatureK: Double
}

struct ElementTrustSnapshot: Sendable {
    let ageDays: Double
    let level: String
    let note: String
}


struct TransitRecord: Identifiable, Sendable {
    let id: String
    let body: String
    let date: Date
    let separationDegrees: Double
    let isDiskTransit: Bool
    let satelliteAzimuth: Double
    let satelliteElevation: Double
    let bodyAzimuth: Double
    let bodyElevation: Double
    let rangeKm: Double
}

enum OrbitalZone: String, CaseIterable, Identifiable, Sendable {
    case saa = "South Atlantic Anomaly"
    case innerBelt = "Inner belt"
    case outerBelt = "Outer belt"
    case polar = "Polar caps"
    case eclipse = "Eclipse"
    var id: String { rawValue }
}

struct ZoneWindow: Identifiable, Sendable {
    let id: Date
    let start: Date
    let end: Date
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct OrbitalZoneResult: Sendable {
    let zone: OrbitalZone
    let inNow: Bool
    let shellL: Double
    let bRatio: Double
    let dwellMinutesPerDay: Double
    let scannedHours: Double
    let windows: [ZoneWindow]
}

struct MeteorShowerRecord: Identifiable, Sendable {
    let id: String
    let name: String
    let peak: Date
    let daysUntilPeak: Double
    let zhr: Int
    let radiantAzimuth: Double
    let radiantElevation: Double
    let moonIllumination: Double
    let moonElevation: Double
    let verdict: String
}

struct TwilightRecord: Identifiable, Sendable {
    let id: String
    let label: String
    let solarAltitude: Double
    let morning: Date?
    let evening: Date?
}

struct JupiterRadioStatus: Sendable {
    let cmlDegrees: Double
    let ioPhaseDegrees: Double
    let azimuth: Double
    let elevation: Double
    let activeSources: [String]
    let verdict: String
}

struct JupiterStormWindow: Identifiable, Sendable {
    let id: Date
    let start: Date
    let end: Date
    let sources: String
    let peakElevation: Double
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct EMEConditionsSnapshot: Sendable {
    let distanceKm: Double
    let perigeeKm: Double
    let perigeeDate: Date
    let apogeeKm: Double
    let apogeeDate: Date
    let degradationDb: Double
    let swingDb: Double
    let declinationDegrees: Double
}

enum HistoryColumn: String, CaseIterable, Identifiable, Codable, Sendable {
    case semiMajorAxis = "SEMIMAJOR_AXIS"
    case eccentricity = "ECCENTRICITY"
    case inclination = "INCLINATION"
    case period = "PERIOD"
    case apogee = "APOAPSIS"
    case perigee = "PERIAPSIS"
    case bstar = "BSTAR"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .semiMajorAxis: "Semi-major axis"
        case .eccentricity: "Eccentricity"
        case .inclination: "Inclination"
        case .period: "Period"
        case .apogee: "Apogee"
        case .perigee: "Perigee"
        case .bstar: "B* drag term"
        }
    }
    var unit: String {
        switch self {
        case .semiMajorAxis, .apogee, .perigee: "km"
        case .inclination: "deg"
        case .period: "min"
        case .bstar: "1/ER"
        case .eccentricity: ""
        }
    }
}

struct OrbitalHistorySample: Codable, Identifiable, Sendable {
    let epoch: Date
    var semiMajorAxis: Double?
    var eccentricity: Double?
    var inclination: Double?
    var period: Double?
    var apogee: Double?
    var perigee: Double?
    var bstar: Double?
    var id: Date { epoch }

    func value(_ column: HistoryColumn) -> Double? {
        switch column {
        case .semiMajorAxis: semiMajorAxis
        case .eccentricity: eccentricity
        case .inclination: inclination
        case .period: period
        case .apogee: apogee
        case .perigee: perigee
        case .bstar: bstar
        }
    }
}

struct OrbitalHistorySummary: Identifiable, Sendable {
    let id: HistoryColumn
    let column: HistoryColumn
    let first: Double
    let last: Double
    let delta: Double
    let ratePerYear: Double
    let minimum: Double
    let maximum: Double
    let samples: Int
}

struct OrbitalHistoryRatePoint: Identifiable, Sendable {
    let date: Date
    let ratePerYear: Double
    var id: Date { date }
}

struct OrbitalHistoryJump: Identifiable, Sendable {
    let date: Date
    let ratePerYear: Double
    var id: Date { date }
}

struct OrbitalHistoryRateAnalysis: Sendable {
    let intervalCount: Int
    let earlyMean: Double
    let lateMean: Double
    let ratio: Double
    let reversed: Bool
    let accelerationPerYear: Double
    let medianAbsoluteRate: Double
    let meanAbsoluteRate: Double
    let jumps: [OrbitalHistoryJump]
    let peakRate: Double
    let peakDate: Date
    let verdict: String
    let firstDate: Date
    let lastDate: Date
}

struct OrbitalHistoryDecayEstimate: Sendable {
    let days: Double
    let source: String
    let fittedNdot: Double?
    let note: String
}


struct SpaceWeatherSnapshot: Codable, Sendable {
    let fetchedAt: Date
    let flux: Double?
    let kp: Double?
    let aIndex: Double?
    let aIndexSource: String?
    let sunspotNumber: Double?
    let flux90Day: Double?

    init(fetchedAt: Date, flux: Double?, kp: Double?, aIndex: Double?, aIndexSource: String? = nil,
         sunspotNumber: Double?, flux90Day: Double?) {
        self.fetchedAt = fetchedAt
        self.flux = flux
        self.kp = kp
        self.aIndex = aIndex
        self.aIndexSource = aIndexSource
        self.sunspotNumber = sunspotNumber
        self.flux90Day = flux90Day
    }

    var fluxLabel: String {
        guard let flux else { return "—" }
        if flux < 90 { return "low" }
        if flux < 120 { return "moderate" }
        if flux < 160 { return "good" }
        return "very high"
    }
    var kpLabel: String {
        guard let kp else { return "—" }
        if kp < 3 { return "quiet" }
        if kp < 4 { return "unsettled" }
        if kp < 5 { return "active" }
        if kp < 6 { return "minor storm" }
        if kp < 7 { return "moderate storm" }
        return "major storm"
    }
    var outlook: String {
        if let kp, kp >= 5 {
            return "Geomagnetic storm: expect auroral flutter on VHF, degraded high-latitude HF, and possible aurora-mode openings."
        }
        var parts: [String] = []
        if let flux {
            if flux >= 120 { parts.append("good HF ionization and higher MUF") }
            else if flux < 90 { parts.append("weak HF ionization and lower MUF") }
            else { parts.append("moderate HF conditions") }
        }
        if let kp, kp < 3 { parts.append("quiet geomagnetic field and stable paths") }
        guard !parts.isEmpty else { return "Indices unavailable." }
        // Sentence case only — `.capitalized` would title-case every word and turn
        // acronyms like MUF/HF into "Muf"/"Hf".
        let joined = parts.joined(separator: "; ")
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }
}

struct AmsatStatusSummaryRecord: Identifiable, Sendable {
    let id: String
    let apiName: String
    let displayName: String
    let reports: Int
    let heard: Int
    let lastReport: String
}

struct NewLaunchHit: Identifiable, Sendable {
    let id: UInt
    let name: String
    let transmitterCount: Int
    let downlinkHz: Int64
    let mode: String
    let alreadyInCatalog: Bool
    let record: SatelliteRecord
    let transponders: [TransponderRecord]
    var isNoise: Bool = false
}

struct LatLon: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

enum FeatureEngineError: LocalizedError {
    case invalidLocation
    case propagation(String)

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Enter a valid Maidenhead grid or latitude,longitude pair."
        case .propagation(let message):
            return "Propagation failed: \(message)"
        }
    }
}

enum FeatureEngine {
    static let earthRadiusKm = 6378.135
    private static let degreesToRadians = Double.pi / 180.0

    // MARK: - Maidenhead / location helpers

    static func parseLocation(_ text: String) -> LatLon? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2,
                  let lat = Double(parts[0]),
                  let lon = Double(parts[1]),
                  (-90...90).contains(lat),
                  (-180...180).contains(lon) else { return nil }
            return LatLon(latitude: lat, longitude: lon)
        }
        return gridToLatLon(trimmed)
    }

    static func gridToLatLon(_ locator: String) -> LatLon? {
        let grid = locator.uppercased()
        guard grid.count >= 2 else { return nil }
        let chars = Array(grid)
        guard let a = chars[0].asciiValue,
              let b = chars[1].asciiValue,
              (65...82).contains(a), (65...82).contains(b) else { return nil }

        var lon = Double(Int(a) - 65) * 20.0 - 180.0
        var lat = Double(Int(b) - 65) * 10.0 - 90.0
        var lonWidth = 20.0
        var latHeight = 10.0

        if chars.count >= 4,
           let c = chars[2].wholeNumberValue,
           let d = chars[3].wholeNumberValue {
            lon += Double(c) * 2.0
            lat += Double(d)
            lonWidth = 2.0
            latHeight = 1.0
        } else if chars.count >= 4 {
            return nil
        }

        if chars.count >= 6,
           let e = chars[4].asciiValue,
           let f = chars[5].asciiValue,
           (65...88).contains(e), (65...88).contains(f) {
            lon += Double(Int(e) - 65) * (2.0 / 24.0)
            lat += Double(Int(f) - 65) * (1.0 / 24.0)
            lonWidth = 2.0 / 24.0
            latHeight = 1.0 / 24.0
        }

        return LatLon(latitude: lat + latHeight / 2.0, longitude: lon + lonWidth / 2.0)
    }

    static func latLonToGrid4(latitude: Double, longitude: Double) -> String {
        let lat = max(-90.0, min(89.999999, latitude)) + 90.0
        let lon = max(-180.0, min(179.999999, longitude)) + 180.0
        let fieldLon = Int(lon / 20.0)
        let fieldLat = Int(lat / 10.0)
        let squareLon = Int((lon.truncatingRemainder(dividingBy: 20.0)) / 2.0)
        let squareLat = Int(lat.truncatingRemainder(dividingBy: 10.0))
        let a = UnicodeScalar(65 + fieldLon)!
        let b = UnicodeScalar(65 + fieldLat)!
        return "\(Character(a))\(Character(b))\(squareLon)\(squareLat)"
    }

    /// Six-character Maidenhead locator (adds the subsquare pair) for a more
    /// precise position such as a rove stop.
    static func latLonToGrid6(latitude: Double, longitude: Double) -> String {
        let square = latLonToGrid4(latitude: latitude, longitude: longitude)
        let lat = max(-90.0, min(89.999999, latitude)) + 90.0
        let lon = max(-180.0, min(179.999999, longitude)) + 180.0
        let subLon = min(23, Int((lon.truncatingRemainder(dividingBy: 2.0)) * 12.0))
        let subLat = min(23, Int((lat.truncatingRemainder(dividingBy: 1.0)) * 24.0))
        let c = UnicodeScalar(97 + subLon)!
        let d = UnicodeScalar(97 + subLat)!
        return "\(square)\(Character(c))\(Character(d))"
    }

    /// ARRL VUCC tolerance for a station being "on" a grid boundary. The rules
    /// require the position be established with a GPS receiver whose error figure
    /// does not exceed 20 feet (≈6.1 m), so a fix within that distance of a grid
    /// line/corner is treated as sitting on it.
    static let vuccBoundaryToleranceMeters = 20.0 * 0.3048

    /// The 4-character (VUCC) grid squares a station at this position may claim.
    /// Normally one, but under ARRL VUCC rules a station physically on the line
    /// between two grids may count both, and one on the corner where four grids
    /// meet may count all four. A position within `toleranceMeters` of a boundary
    /// is considered on it (see `vuccBoundaryToleranceMeters`). Result is sorted.
    static func vuccGrids(latitude: Double, longitude: Double,
                          toleranceMeters: Double = vuccBoundaryToleranceMeters) -> [String] {
        var grids: Set<String> = [latLonToGrid4(latitude: latitude, longitude: longitude)]

        // 4-character grid squares are 1° tall (lat boundaries at integer degrees)
        // and 2° wide (lon boundaries at even offsets from the −180° antimeridian).
        let latBoundary = latitude.rounded()
        let lonBoundary = ((longitude + 180.0) / 2.0).rounded() * 2.0 - 180.0

        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(latitude * .pi / 180.0)
        let onLat = abs(latitude - latBoundary) * metersPerDegLat <= toleranceMeters
        let onLon = abs(longitude - lonBoundary) * metersPerDegLon <= toleranceMeters

        // A point nudged just across the nearest boundary lands in the neighbour.
        let otherLat = latBoundary - (latitude >= latBoundary ? 0.001 : -0.001)
        let otherLon = lonBoundary - (longitude >= lonBoundary ? 0.001 : -0.001)

        if onLat { grids.insert(latLonToGrid4(latitude: otherLat, longitude: longitude)) }
        if onLon { grids.insert(latLonToGrid4(latitude: latitude, longitude: otherLon)) }
        if onLat && onLon { grids.insert(latLonToGrid4(latitude: otherLat, longitude: otherLon)) }

        return grids.sorted()
    }

    // MARK: - Sun, Moon, planets and sky positions

    static func sunMoon(site: ObserverSite, at date: Date = .now) -> SunMoonSnapshot {
        let jd = date.julianDate
        let sun = sunECIUnit(jd)
        let moon = moonSolution(jd)
        let sunAltAz = vectorToAltAz(sun.vector, site: site, julianDay: jd)
        let moonAltAz = vectorToAltAz(moon.vector, site: site, julianDay: jd)

        let d = jd - 2451545.0
        let sunLongitude = normalizedDegrees(280.460 + 0.9856474 * d)
        let phase = normalizedDegrees(moon.longitudeDegrees - sunLongitude)
        let illumination = (1.0 - cos(phase * degreesToRadians)) / 2.0

        return SunMoonSnapshot(
            date: date,
            sunAzimuth: sunAltAz.azimuth,
            sunElevation: sunAltAz.elevation,
            moonAzimuth: moonAltAz.azimuth,
            moonElevation: moonAltAz.elevation,
            moonPhaseAngle: phase,
            moonIllumination: illumination,
            moonDistanceKm: moon.distanceKm
        )
    }

    static func skyObjects(
        site: ObserverSite,
        at date: Date = .now,
        selectedSatellite: SatelliteRecord? = nil
    ) -> [CelestialPoint] {
        let sm = sunMoon(site: site, at: date)
        var points = [
            CelestialPoint(id: "sun", name: "Sun", azimuth: sm.sunAzimuth,
                           elevation: sm.sunElevation, category: "Solar System"),
            CelestialPoint(id: "moon", name: "Moon", azimuth: sm.moonAzimuth,
                           elevation: sm.moonElevation, category: "Solar System")
        ]

        for name in ["Mercury", "Venus", "Mars", "Jupiter", "Saturn"] {
            if let radec = planetRaDec(name: name, date: date) {
                let ae = raDecToAzEl(raDegrees: radec.ra, decDegrees: radec.dec,
                                     site: site, date: date)
                points.append(CelestialPoint(id: name.lowercased(), name: name,
                                             azimuth: ae.azimuth, elevation: ae.elevation,
                                             category: "Planet"))
            }
        }

        let radioSources: [(String, Double, Double)] = [
            ("Cassiopeia A", 350.866, 58.811),
            ("Cygnus A", 299.868, 40.734),
            ("Taurus A (Crab)", 83.633, 22.014),
            ("Virgo A (M87)", 187.706, 12.391),
            ("Sagittarius A*", 266.417, -29.008),
            ("Orion A", 83.809, -5.389),
            ("Centaurus A", 201.365, -43.019),
            ("Fornax A", 50.674, -37.208)
        ]
        for (name, ra, dec) in radioSources {
            let ae = raDecToAzEl(raDegrees: ra, decDegrees: dec, site: site, date: date)
            points.append(CelestialPoint(id: "radio-\(name)", name: name,
                                         azimuth: ae.azimuth, elevation: ae.elevation,
                                         category: "Radio source"))
        }

        // Desktop OrbitDeck includes a representative high-galactic-latitude
        // cold-sky reference for antenna calibration.
        let cold = raDecToAzEl(raDegrees: 192.0, decDegrees: 27.4,
                               site: site, date: date)
        points.append(CelestialPoint(id: "cold-sky", name: "Cold sky (ref)",
                                     azimuth: cold.azimuth, elevation: cold.elevation,
                                     category: "Reference"))

        if let selectedSatellite,
           let look = try? OrbitPredictor.look(selectedSatellite, observer: site, at: date) {
            points.append(CelestialPoint(id: "satellite-\(selectedSatellite.id)",
                                         name: selectedSatellite.name,
                                         azimuth: look.azimuth, elevation: look.elevation,
                                         category: "Satellite"))
        }
        return points
    }

    // MARK: - Sky at a Glance

    static func skyGlance(
        favorites: [SatelliteRecord],
        observer: ObserverSite,
        from start: Date = .now,
        hours: Double = 12,
        minimumElevation: Double = 5
    ) throws -> [SkyGlanceRow] {
        var rows: [SkyGlanceRow] = []
        for satellite in favorites {
            let passes = try OrbitPredictor.predictPasses(
                satellite, observer: observer, from: start,
                minElevation: minimumElevation, maxCount: 20,
                horizonDays: hours / 24.0
            ).filter { $0.aos <= start.addingTimeInterval(hours * 3600) }
            rows.append(SkyGlanceRow(id: satellite.id, name: satellite.name, passes: passes))
        }
        return rows.sorted { lhs, rhs in
            let la = lhs.passes.first?.aos ?? .distantFuture
            let ra = rhs.passes.first?.aos ?? .distantFuture
            if la == ra { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return la < ra
        }
    }

    static func longestQuietGap(rows: [SkyGlanceRow], start: Date, hours: Double) -> (Date, Date)? {
        let end = start.addingTimeInterval(hours * 3600)
        let intervals = rows.flatMap(\.passes)
            .map { (max($0.aos, start), min($0.los, end)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        guard !intervals.isEmpty else { return (start, end) }
        var merged: [(Date, Date)] = []
        for interval in intervals {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else {
                merged.append(interval)
            }
        }
        var best = (start, merged[0].0)
        for i in 0..<(merged.count - 1) {
            let gap = (merged[i].1, merged[i + 1].0)
            if gap.1.timeIntervalSince(gap.0) > best.1.timeIntervalSince(best.0) { best = gap }
        }
        let tail = (merged.last!.1, end)
        if tail.1.timeIntervalSince(tail.0) > best.1.timeIntervalSince(best.0) { best = tail }
        return best
    }

    // MARK: - EME

    static func emeSnapshot(site: ObserverSite, frequencyMHz: Double, at date: Date = .now) -> EMESnapshot {
        let sm = sunMoon(site: site, at: date)
        let frequencyHz = frequencyMHz * 1_000_000
        let distanceM = sm.moonDistanceKm * 1000
        let wavelength = 299_792_458.0 / frequencyHz
        let oneWayFSPL = 20 * log10(4 * .pi * distanceM / wavelength)
        let moonRadiusM = 1_737_400.0
        let radarAlbedo = 0.065
        let effectiveArea = radarAlbedo * .pi * moonRadiusM * moonRadiusM
        let reflectorGain = 10 * log10(4 * .pi * effectiveArea / (wavelength * wavelength))
        let pathLoss = 2 * oneWayFSPL - reflectorGain
        let r0 = moonTopocentricRangeKm(site: site, at: date)
        let r1 = moonTopocentricRangeKm(site: site, at: date.addingTimeInterval(1))
        let rangeRateMS = (r1 - r0) * 1000
        let doppler = -2 * frequencyHz * rangeRateMS / 299_792_458.0
        let skyTemperature = 200.0 * pow(144.0 / max(1, frequencyMHz), 2.5)
        return EMESnapshot(moonAzimuth: sm.moonAzimuth, moonElevation: sm.moonElevation,
                           moonDistanceKm: sm.moonDistanceKm, selfEchoDopplerHz: doppler,
                           pathLossDb: pathLoss, coldSkyTemperatureK: skyTemperature)
    }

    static func emeCommonWindows(home: ObserverSite, dx: ObserverSite,
                                 from start: Date = .now, hours: Double = 48,
                                 minimumElevation: Double = 0,
                                 step: TimeInterval = 300) -> [EMEWindowRecord] {
        let end = start.addingTimeInterval(hours * 3600)
        var windows: [EMEWindowRecord] = []
        var currentStart: Date?
        var currentEnd: Date?
        var t = start
        while t <= end {
            let homeEl = sunMoon(site: home, at: t).moonElevation
            let dxEl = sunMoon(site: dx, at: t).moonElevation
            let okay = homeEl >= minimumElevation && dxEl >= minimumElevation
            if okay {
                if currentStart == nil { currentStart = t }
                currentEnd = t
            } else if let a = currentStart, let b = currentEnd {
                windows.append(EMEWindowRecord(id: a, start: a, end: b))
                currentStart = nil
                currentEnd = nil
            }
            t = t.addingTimeInterval(step)
        }
        if let a = currentStart, let b = currentEnd { windows.append(EMEWindowRecord(id: a, start: a, end: b)) }
        return windows
    }

    private static func moonTopocentricRangeKm(site: ObserverSite, at date: Date) -> Double {
        let jd = date.julianDate
        let moon = moonSolution(jd)
        let distance = moon.distanceKm
        let mx = moon.vector.x * distance
        let my = moon.vector.y * distance
        let mz = moon.vector.z * distance
        let lst = gmstRadians(jd) + site.longitude * degreesToRadians
        let cosLat = cos(site.latitude * degreesToRadians)
        let radius = earthRadiusKm + site.altitudeMeters / 1000
        let ox = radius * cosLat * cos(lst)
        let oy = radius * cosLat * sin(lst)
        let oz = radius * sin(site.latitude * degreesToRadians)
        return sqrt((mx - ox) * (mx - ox) + (my - oy) * (my - oy) + (mz - oz) * (mz - oz))
    }

    // MARK: - Mutual windows

    static func mutualWindows(
        _ record: SatelliteRecord,
        home: ObserverSite,
        dx: ObserverSite,
        from start: Date = .now,
        days: Double = 10,
        minimumElevation: Double = 0,
        step: TimeInterval = 10,
        maxCount: Int = 40
    ) throws -> [MutualWindowRecord] {
        let satellite = Satellite(elements: record.elements)
        // Mutual visibility can only happen while the home station sees the
        // satellite, so scope the fine-grained scan to the home passes instead of
        // walking the whole span. This is both faster and, at a 10 s step, tighter
        // on the window edges than the old 30 s full-timeline scan.
        let homePasses = try OrbitPredictor.predictPasses(
            record, observer: home, from: start,
            minElevation: max(0, minimumElevation), maxCount: 200, horizonDays: days)
        let fine = max(1, step)
        var results: [MutualWindowRecord] = []

        for pass in homePasses {
            var currentStart: Date?
            var currentEnd: Date?
            var homeMax = -90.0
            var dxMax = -90.0
            var t = pass.aos
            while t <= pass.los.addingTimeInterval(0.5) {
                let homeTop = try satellite.topPosition(julianDays: t.julianDate, observer: home.satelliteKitLocation)
                let dxTop = try satellite.topPosition(julianDays: t.julianDate, observer: dx.satelliteKitLocation)
                if homeTop.elev >= minimumElevation && dxTop.elev >= minimumElevation {
                    if currentStart == nil { currentStart = t }
                    currentEnd = t
                    homeMax = max(homeMax, homeTop.elev)
                    dxMax = max(dxMax, dxTop.elev)
                } else if let s = currentStart, let e = currentEnd {
                    results.append(MutualWindowRecord(id: s, start: s, end: e, myMaxElevation: homeMax, dxMaxElevation: dxMax))
                    currentStart = nil; currentEnd = nil; homeMax = -90; dxMax = -90
                    if results.count >= maxCount { return results }
                }
                t = t.addingTimeInterval(fine)
            }
            if let s = currentStart, let e = currentEnd {
                results.append(MutualWindowRecord(id: s, start: s, end: e, myMaxElevation: homeMax, dxMaxElevation: dxMax))
                if results.count >= maxCount { return results }
            }
        }
        return results
    }

    // MARK: - Workable grids / footprint planning

    static func workableGrids(subLatitude: Double, subLongitude: Double, altitudeKm: Double) -> [String] {
        let radius = footprintRadiusDegrees(altitudeKm: altitudeKm)
        guard radius > 0 else { return [] }
        var output: [String] = []
        output.reserveCapacity(1800)

        for fieldLon in 0..<18 {
            for fieldLat in 0..<18 {
                for squareLon in 0..<10 {
                    let lon = -180.0 + Double(fieldLon) * 20.0 + Double(squareLon) * 2.0 + 1.0
                    // No longitude fast-prune: a raw Δlon is not a valid bound on
                    // angular separation where meridians converge, so it would drop
                    // valid high-latitude / antimeridian cells for large footprints.
                    // The latitude prune below plus the exact check keep this correct.
                    for squareLat in 0..<10 {
                        let lat = -90.0 + Double(fieldLat) * 10.0 + Double(squareLat) + 0.5
                        if abs(lat - subLatitude) > radius + 2.0 { continue }
                        if angularSeparationDegrees(subLatitude, subLongitude, lat, lon) <= radius {
                            let a = Character(UnicodeScalar(65 + fieldLon)!)
                            let b = Character(UnicodeScalar(65 + fieldLat)!)
                            output.append("\(a)\(b)\(squareLon)\(squareLat)")
                        }
                    }
                }
            }
        }
        return output.sorted()
    }

    static func workableGridsNow(_ record: SatelliteRecord, at date: Date = .now) throws -> [String] {
        let satellite = Satellite(elements: record.elements)
        let geo = try satellite.geoPosition(julianDays: date.julianDate)
        return workableGrids(subLatitude: geo.lat, subLongitude: normalizedLongitude(geo.lon),
                             altitudeKm: geo.alt)
    }

    static func workableGridsAcrossNextPass(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        minimumElevation: Double,
        from start: Date = .now
    ) throws -> [String] {
        guard let pass = try OrbitPredictor.predictPasses(
            record, observer: observer, from: start.addingTimeInterval(-600),
            minElevation: minimumElevation, maxCount: 1, horizonDays: 6
        ).first else { return [] }
        let satellite = Satellite(elements: record.elements)
        let steps = max(8, Int(pass.duration / 60.0))
        var union = Set<String>()
        for index in 0...steps {
            let fraction = Double(index) / Double(steps)
            let date = pass.aos.addingTimeInterval(pass.duration * fraction)
            let geo = try satellite.geoPosition(julianDays: date.julianDate)
            union.formUnion(workableGrids(subLatitude: geo.lat,
                                          subLongitude: normalizedLongitude(geo.lon),
                                          altitudeKm: geo.alt))
        }
        return union.sorted()
    }

    static func bestPassesForTarget(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        target: LatLon,
        from start: Date = .now,
        hours: Double = 72,
        step: TimeInterval = 30,
        maxResults: Int = 20
    ) throws -> [TargetWindowRecord] {
        let satellite = Satellite(elements: record.elements)
        let end = start.addingTimeInterval(hours * 3600)
        var windows: [(Date, Date)] = []
        var currentStart: Date?
        var currentEnd: Date?
        var t = start

        while t <= end {
            let geo = try satellite.geoPosition(julianDays: t.julianDate)
            let radius = footprintRadiusDegrees(altitudeKm: geo.alt)
            let homeDistance = angularSeparationDegrees(geo.lat, geo.lon,
                                                        observer.latitude, observer.longitude)
            let targetDistance = angularSeparationDegrees(geo.lat, geo.lon,
                                                          target.latitude, target.longitude)
            let okay = homeDistance <= radius && targetDistance <= radius
            if okay {
                if currentStart == nil { currentStart = t }
                currentEnd = t
            } else if let a = currentStart, let b = currentEnd {
                windows.append((a, b))
                currentStart = nil
                currentEnd = nil
            }
            t = t.addingTimeInterval(step)
        }
        if let a = currentStart, let b = currentEnd { windows.append((a, b)) }

        return try windows.prefix(maxResults).map { start, end in
            let middle = Date(timeIntervalSince1970:
                (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2.0)
            let geo = try satellite.geoPosition(julianDays: middle.julianDate)
            let radius = footprintRadiusDegrees(altitudeKm: geo.alt)
            let homeDistance = angularSeparationDegrees(geo.lat, geo.lon,
                                                        observer.latitude, observer.longitude)
            let targetDistance = angularSeparationDegrees(geo.lat, geo.lon,
                                                          target.latitude, target.longitude)
            return TargetWindowRecord(id: start, start: start, end: end,
                                      marginDegrees: radius - max(homeDistance, targetDistance))
        }
    }

    static func elementTrust(_ record: SatelliteRecord, now: Date = .now) -> ElementTrustSnapshot {
        let age = max(0, now.timeIntervalSince(record.epoch) / 86400.0)
        if age <= 3 {
            return ElementTrustSnapshot(ageDays: age, level: "Fresh",
                                        note: "Suitable for normal pass and Doppler planning.")
        } else if age <= 7 {
            return ElementTrustSnapshot(ageDays: age, level: "Usable",
                                        note: "Good for general planning; refresh before precision work.")
        } else if age <= 14 {
            return ElementTrustSnapshot(ageDays: age, level: "Aging",
                                        note: "Timing and pointing error may be noticeable. Refresh GP data.")
        } else {
            return ElementTrustSnapshot(ageDays: age, level: "Stale",
                                        note: "Treat predictions as approximate until elements are refreshed.")
        }
    }

    // MARK: - Conjunction awareness

    static func screenConjunctions(
        primary: SatelliteRecord,
        secondary: SatelliteRecord,
        from start: Date = .now,
        hours: Double = 6,
        step: TimeInterval = 30,
        thresholdKm: Double = 800,
        maxResults: Int = 8
    ) throws -> [ConjunctionRecord] {
        let satA = Satellite(elements: primary.elements)
        let satB = Satellite(elements: secondary.elements)
        let end = start.addingTimeInterval(hours * 3600)
        var results: [ConjunctionRecord] = []
        var previousPreviousDistance = Double.greatestFiniteMagnitude
        var previousDistance = Double.greatestFiniteMagnitude
        var previousTime: Date?
        var t = start

        while t <= end {
            let a = try state(satA, at: t)
            let b = try state(satB, at: t)
            let distance = separation(a.position, b.position)
            if let candidateTime = previousTime,
               previousDistance < previousPreviousDistance,
               previousDistance <= distance,
               previousDistance < thresholdKm {
                var bestTime = candidateTime
                var bestDistance = previousDistance
                var bestRelativeVelocity = 0.0
                var rt = candidateTime.addingTimeInterval(-step)
                let refineEnd = candidateTime.addingTimeInterval(step)
                while rt <= refineEnd {
                    let r1 = try state(satA, at: rt)
                    let r2 = try state(satB, at: rt)
                    let d = separation(r1.position, r2.position)
                    if d < bestDistance {
                        bestDistance = d
                        bestTime = rt
                        bestRelativeVelocity = separation(r1.velocity, r2.velocity)
                    }
                    rt = rt.addingTimeInterval(1)
                }
                results.append(ConjunctionRecord(id: bestTime, date: bestTime,
                                                  missDistanceKm: bestDistance,
                                                  relativeVelocityKmS: bestRelativeVelocity))
            }
            previousPreviousDistance = previousDistance
            previousDistance = distance
            previousTime = t
            t = t.addingTimeInterval(step)
        }
        return Array(results.sorted { $0.missDistanceKm < $1.missDistanceKm }.prefix(maxResults))
    }

    static func orbitalNeighborhood(
        primary: SatelliteRecord,
        others: [SatelliteRecord],
        at date: Date = .now,
        maxResults: Int = 12
    ) throws -> [OrbitalNeighbor] {
        let baseSatellite = Satellite(elements: primary.elements)
        let base = try state(baseSatellite, at: date)
        var results: [OrbitalNeighbor] = []
        results.reserveCapacity(min(maxResults * 4, others.count))
        for other in others where other.id != primary.id {
            do {
                let satellite = Satellite(elements: other.elements)
                let s = try state(satellite, at: date)
                results.append(OrbitalNeighbor(
                    id: other.id,
                    name: other.name,
                    rangeKm: separation(base.position, s.position),
                    relativeVelocityKmS: separation(base.velocity, s.velocity)
                ))
            } catch {
                continue
            }
        }
        return Array(results.sorted { $0.rangeKm < $1.rangeKm }.prefix(maxResults))
    }

    // MARK: - AO-7 illumination support

    static func orbitEclipseSampleCount(_ record: SatelliteRecord, at date: Date,
                                        sampleCount: Int = 24) throws -> Int {
        let satellite = Satellite(elements: record.elements)
        let period = record.meanMotionRevPerDay > 0 ? 86400.0 / record.meanMotionRevPerDay : 5700.0
        var shadowed = 0
        for index in 0..<sampleCount {
            let t = date.addingTimeInterval(period * Double(index) / Double(sampleCount))
            let r = try satellite.position(julianDays: t.julianDate)
            if !isSunlit(position: r, julianDay: t.julianDate) { shadowed += 1 }
        }
        return shadowed
    }

    static func continuousSunlightStart(_ record: SatelliteRecord, now: Date = .now,
                                        backDays: Double = 120) throws -> (date: Date, exact: Bool)? {
        if try orbitEclipseSampleCount(record, at: now) >= 2 { return nil }
        let coarseStep: TimeInterval = 12 * 3600
        let limit = now.addingTimeInterval(-backDays * 86400)
        var sunlitTime = now
        var eclipsingTime: Date?
        var t = now.addingTimeInterval(-coarseStep)
        while t > limit {
            if try orbitEclipseSampleCount(record, at: t) >= 2 {
                eclipsingTime = t
                break
            }
            sunlitTime = t
            t = t.addingTimeInterval(-coarseStep)
        }
        guard var low = eclipsingTime else { return (limit, false) }
        var high = sunlitTime
        while high.timeIntervalSince(low) > 1800 {
            let mid = Date(timeIntervalSince1970:
                (low.timeIntervalSince1970 + high.timeIntervalSince1970) / 2)
            if try orbitEclipseSampleCount(record, at: mid) >= 2 {
                low = mid
            } else {
                high = mid
            }
        }
        return (high, true)
    }



    // MARK: - Sun / Moon transits

    static func findTransits(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        from start: Date = .now,
        days: Double = 7,
        body: String = "both",
        maximumSeparationDegrees: Double = 1.0,
        coarseStep: TimeInterval = 20
    ) throws -> [TransitRecord] {
        let satellite = Satellite(elements: record.elements)
        let passes = try OrbitPredictor.predictPasses(
            record, observer: observer, from: start, minElevation: 0,
            maxCount: 300, horizonDays: days, coarseStep: 30
        )
        let bodies = body == "both" ? ["sun", "moon"] : [body]
        var events: [TransitRecord] = []

        for pass in passes {
            var current: [String: TransitRecord] = [:]
            var t = pass.aos
            while t <= pass.los {
                let top = try satellite.topPosition(julianDays: t.julianDate,
                                                    observer: observer.satelliteKitLocation)
                let snapshot = sunMoon(site: observer, at: t)
                for b in bodies {
                    let baz = b == "sun" ? snapshot.sunAzimuth : snapshot.moonAzimuth
                    let bel = b == "sun" ? snapshot.sunElevation : snapshot.moonElevation
                    let radius = b == "sun" ? 0.266 : 0.259
                    guard bel >= 0 else {
                        if let prior = current.removeValue(forKey: b) { events.append(prior) }
                        continue
                    }
                    let sep = directionSeparationDegrees(top.azim, top.elev, baz, bel)
                    if sep <= maximumSeparationDegrees {
                        let candidate = TransitRecord(
                            id: "\(b)-\(t.timeIntervalSince1970)", body: b, date: t,
                            separationDegrees: sep, isDiskTransit: sep <= radius,
                            satelliteAzimuth: normalizedDegrees(top.azim), satelliteElevation: top.elev,
                            bodyAzimuth: baz, bodyElevation: bel, rangeKm: top.dist
                        )
                        if current[b] == nil || sep < current[b]!.separationDegrees { current[b] = candidate }
                    } else if let prior = current.removeValue(forKey: b) {
                        events.append(prior)
                    }
                }
                t = t.addingTimeInterval(coarseStep)
            }
            events.append(contentsOf: current.values)
        }
        return events.sorted { $0.date < $1.date }
    }

    // MARK: - Orbital zones

    static func scanOrbitalZone(
        _ record: SatelliteRecord,
        zone: OrbitalZone,
        from start: Date = .now,
        hours: Double = 24,
        maxWindows: Int = 16
    ) throws -> OrbitalZoneResult {
        let satellite = Satellite(elements: record.elements)
        let period = record.meanMotionRevPerDay > 0 ? 86400.0 / record.meanMotionRevPerDay : 5700.0
        let step = max(30.0, min(300.0, period / 200.0))
        let end = start.addingTimeInterval(hours * 3600)

        func state(at date: Date) throws -> (inside: Bool, l: Double, br: Double) {
            let geo = try satellite.geoPosition(julianDays: date.julianDate)
            let position = try satellite.position(julianDays: date.julianDate)
            let sunlit = isSunlit(position: position, julianDay: date.julianDate)
            let l = shellL(latitude: geo.lat, longitude: geo.lon, altitudeKm: geo.alt)
            let br = magneticBRatio(latitude: geo.lat, longitude: geo.lon)
            return (inOrbitalZone(zone, latitude: geo.lat, longitude: geo.lon,
                                  altitudeKm: geo.alt, sunlit: sunlit, at: date,
                                  shellL: l, bRatio: br), l, br)
        }

        func refine(_ low: Date, _ high: Date, lowState: Bool) throws -> Date {
            var lo = low
            var hi = high
            while hi.timeIntervalSince(lo) > 2 {
                let mid = Date(timeIntervalSince1970:
                    (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
                if try state(at: mid).inside == lowState { lo = mid } else { hi = mid }
            }
            return hi
        }

        let initial = try state(at: start)
        var priorInside = initial.inside
        var enter: Date? = priorInside ? start : nil
        var windows: [ZoneWindow] = []
        var total: TimeInterval = 0
        var previousDate = start
        var t = start.addingTimeInterval(step)
        while t <= end && windows.count < maxWindows {
            let inside = try state(at: t).inside
            if inside != priorInside {
                let crossing = try refine(previousDate, t, lowState: priorInside)
                if inside {
                    enter = crossing
                } else if let a = enter {
                    windows.append(ZoneWindow(id: a, start: a, end: crossing))
                    total += crossing.timeIntervalSince(a)
                    enter = nil
                }
                priorInside = inside
            }
            previousDate = t
            t = t.addingTimeInterval(step)
        }
        if let a = enter, windows.count < maxWindows {
            windows.append(ZoneWindow(id: a, start: a, end: end))
            total += end.timeIntervalSince(a)
        }
        let days = hours / 24.0
        return OrbitalZoneResult(zone: zone, inNow: initial.inside,
                                 shellL: initial.l, bRatio: initial.br,
                                 dwellMinutesPerDay: days > 0 ? total / 60 / days : 0,
                                 scannedHours: hours, windows: windows)
    }

    // MARK: - Astronomy planning

    static func meteorShowers(site: ObserverSite, now: Date = .now) -> [MeteorShowerRecord] {
        let showers: [(String, String, Int, Int, Double, Double, Int)] = [
            ("QUA", "Quadrantids", 1, 3, 230, 49, 110),
            ("LYR", "Lyrids", 4, 22, 271, 34, 18),
            ("ETA", "Eta Aquariids", 5, 6, 338, -1, 50),
            ("SDA", "S d-Aquariids", 7, 30, 339, -16, 25),
            ("PER", "Perseids", 8, 13, 48, 58, 100),
            ("DRA", "Draconids", 10, 8, 262, 54, 10),
            ("ORI", "Orionids", 10, 21, 95, 16, 20),
            ("STA", "S Taurids", 11, 5, 52, 13, 7),
            ("LEO", "Leonids", 11, 17, 152, 22, 15),
            ("GEM", "Geminids", 12, 14, 112, 33, 150),
            ("URS", "Ursids", 12, 22, 217, 76, 10)
        ]
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        return showers.compactMap { code, name, month, day, ra, dec, zhr in
            var peak: Date?
            for y in year...(year + 1) where peak == nil {
                var comps = DateComponents()
                comps.calendar = calendar
                comps.timeZone = TimeZone(secondsFromGMT: 0)
                comps.year = y; comps.month = month; comps.day = day; comps.hour = 2
                if let d = comps.date, d >= now.addingTimeInterval(-12 * 3600) { peak = d }
            }
            guard let peak else { return nil }
            let radiant = raDecToAzEl(raDegrees: ra, decDegrees: dec, site: site, date: peak)
            let moon = sunMoon(site: site, at: peak)
            let verdict: String
            if radiant.elevation < 0 {
                verdict = "Radiant below horizon at 02:00 UTC — little scatter here"
            } else if radiant.elevation > 15 && zhr >= 50 {
                verdict = "Strong — high rate with the radiant well up"
            } else if radiant.elevation > 15 {
                verdict = "Workable — radiant up, modest rate"
            } else if zhr >= 50 {
                verdict = "Marginal — high rate but the radiant is low"
            } else {
                verdict = "Weak — low rate and a low radiant"
            }
            return MeteorShowerRecord(id: code, name: name, peak: peak,
                daysUntilPeak: peak.timeIntervalSince(now) / 86400,
                zhr: zhr, radiantAzimuth: radiant.azimuth,
                radiantElevation: radiant.elevation,
                moonIllumination: moon.moonIllumination,
                moonElevation: moon.moonElevation,
                verdict: verdict + (moon.moonIllumination > 0.7 && moon.moonElevation > 0
                    ? "; bright Moon up (visual only, radio unaffected)" : ""))
        }.sorted { $0.peak < $1.peak }
    }

    static func jupiterRadioStatus(site: ObserverSite, at date: Date = .now) -> JupiterRadioStatus {
        let d = date.julianDate - 2451545.0
        let cml = normalizedDegrees(284.95 + 870.5360000 * d)
        let io = normalizedDegrees(342.86 + 203.4889538 * d)
        let jupiter = planetRaDec(name: "Jupiter", date: date).map {
            raDecToAzEl(raDegrees: $0.ra, decDegrees: $0.dec, site: site, date: date)
        } ?? (azimuth: 0.0, elevation: -90.0)
        // CML and Io-phase boxes for the classic Io-A/B/C decametric sources.
        // A box is expressed as (low, high); when low > high it wraps through
        // 360° (Io-C's CML spans 300°→360°→20°).
        func inBox(_ value: Double, _ low: Double, _ high: Double) -> Bool {
            low <= high ? (value >= low && value <= high) : (value >= low || value <= high)
        }
        let sources: [(name: String, cLow: Double, cHigh: Double, iLow: Double, iHigh: Double)] = [
            ("Io-A", 200, 270, 200, 270),
            ("Io-B", 105, 190, 75, 105),
            ("Io-C", 300, 20, 225, 260)
        ]
        var active: [String] = []
        for s in sources where inBox(cml, s.cLow, s.cHigh) && inBox(io, s.iLow, s.iHigh) {
            active.append(s.name)
        }
        let verdict = active.isEmpty ? "No Io source active" : "\(active.joined(separator: ", ")) active"
        return JupiterRadioStatus(cmlDegrees: cml, ioPhaseDegrees: io,
                                  azimuth: jupiter.azimuth, elevation: jupiter.elevation,
                                  activeSources: active,
                                  verdict: verdict + (jupiter.elevation > 0 ? "" : "; Jupiter is down"))
    }

    /// Upcoming Io-controlled decametric storm windows over the next `days`,
    /// where an Io source (A/B/C) is active AND Jupiter is above the horizon.
    static func jupiterStormWindows(site: ObserverSite, from: Date = .now, days: Double = 14, step: TimeInterval = 600) -> [JupiterStormWindow] {
        let end = from.addingTimeInterval(days * 86400)
        var windows: [JupiterStormWindow] = []
        var windowStart: Date?
        var windowSources: Set<String> = []
        var windowPeak = -90.0
        func close(_ endTime: Date) {
            if let start = windowStart {
                windows.append(JupiterStormWindow(id: start, start: start, end: endTime,
                                                  sources: windowSources.sorted().joined(separator: ", "),
                                                  peakElevation: windowPeak))
            }
            windowStart = nil; windowSources = []; windowPeak = -90
        }
        var t = from
        while t <= end {
            let status = jupiterRadioStatus(site: site, at: t)
            if !status.activeSources.isEmpty && status.elevation > 0 {
                if windowStart == nil { windowStart = t }
                windowSources.formUnion(status.activeSources)
                windowPeak = max(windowPeak, status.elevation)
            } else if windowStart != nil {
                close(t)
            }
            t = t.addingTimeInterval(step)
        }
        close(end)
        return windows
    }

    static func twilightTimes(site: ObserverSite, day: Date = .now,
                              stepMinutes: Int = 5) -> [TwilightRecord] {
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: day)
        comps.hour = 0; comps.minute = 0; comps.second = 0
        let start = cal.date(from: comps) ?? day
        let levels: [(String, Double)] = [
            ("Sunrise/sunset", -0.833), ("Civil", -6),
            ("Nautical", -12), ("Astronomical", -18)
        ]
        let step = TimeInterval(stepMinutes * 60)
        var samples: [(Date, Double)] = []
        var t = start
        while t <= start.addingTimeInterval(86400) {
            samples.append((t, sunMoon(site: site, at: t).sunElevation))
            t = t.addingTimeInterval(step)
        }
        return levels.map { label, altitude in
            var morning: Date?
            var evening: Date?
            for i in 0..<(samples.count - 1) {
                let (ta, ea) = samples[i]
                let (tb, eb) = samples[i + 1]
                if ea == altitude || (ea - altitude) * (eb - altitude) < 0 {
                    let fraction = eb != ea ? (altitude - ea) / (eb - ea) : 0
                    let cross = ta.addingTimeInterval(tb.timeIntervalSince(ta) * fraction)
                    if eb > ea && morning == nil { morning = cross }
                    else if eb < ea { evening = cross }
                }
            }
            return TwilightRecord(id: label, label: label, solarAltitude: altitude,
                                  morning: morning, evening: evening)
        }
    }

    static func emeConditions(at date: Date = .now, days: Int = 30,
                              stepHours: Int = 6) -> EMEConditionsSnapshot {
        let now = moonSolution(date.julianDate)
        var samples: [(Date, Double)] = []
        for i in 0...(days * 24 / stepHours) {
            let t = date.addingTimeInterval(Double(i * stepHours) * 3600)
            samples.append((t, moonSolution(t.julianDate).distanceKm))
        }
        let perigee = samples.min { $0.1 < $1.1 } ?? (date, now.distanceKm)
        let apogee = samples.max { $0.1 < $1.1 } ?? (date, now.distanceKm)
        let vector = now.vector
        let declination = atan2(vector.z, hypot(vector.x, vector.y)) / degreesToRadians
        return EMEConditionsSnapshot(
            distanceKm: now.distanceKm,
            perigeeKm: perigee.1, perigeeDate: perigee.0,
            apogeeKm: apogee.1, apogeeDate: apogee.0,
            degradationDb: 40 * log10(now.distanceKm / perigee.1),
            swingDb: 40 * log10(apogee.1 / perigee.1),
            declinationDegrees: declination
        )
    }

    // MARK: - Space-Track orbital history parsing / summaries

    static func parseOrbitalHistoryCSV(_ text: String) -> [OrbitalHistorySample] {
        let rows = parseCSV(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }),
              let epochIndex = header.firstIndex(of: "EPOCH") else { return [] }
        let indexes = Dictionary(uniqueKeysWithValues: HistoryColumn.allCases.compactMap { c in
            header.firstIndex(of: c.rawValue).map { (c, $0) }
        })
        let positive: Set<HistoryColumn> = [.semiMajorAxis, .inclination, .period, .apogee, .perigee]
        func cell(_ row: [String], _ column: HistoryColumn) -> Double? {
            guard let i = indexes[column], i < row.count else { return nil }
            let trimmed = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
            if positive.contains(column) && value <= 0 { return nil }
            return value
        }
        return rows.dropFirst().compactMap { row in
            guard epochIndex < row.count, let epoch = parseSpaceTrackDate(row[epochIndex]) else { return nil }
            return OrbitalHistorySample(epoch: epoch,
                semiMajorAxis: cell(row, .semiMajorAxis), eccentricity: cell(row, .eccentricity),
                inclination: cell(row, .inclination), period: cell(row, .period),
                apogee: cell(row, .apogee), perigee: cell(row, .perigee), bstar: cell(row, .bstar))
        }.sorted { $0.epoch < $1.epoch }
    }

    static func summarizeHistory(_ samples: [OrbitalHistorySample]) -> [OrbitalHistorySummary] {
        HistoryColumn.allCases.compactMap { column in
            let pairs = samples.compactMap { sample in sample.value(column).map { (sample.epoch, $0) } }
            guard let first = pairs.first, let last = pairs.last else { return nil }
            let values = pairs.map(\.1)
            let spanDays = last.0.timeIntervalSince(first.0) / 86400
            return OrbitalHistorySummary(id: column, column: column,
                first: first.1, last: last.1, delta: last.1 - first.1,
                ratePerYear: spanDays > 0 ? (last.1 - first.1) / spanDays * 365.25 : 0,
                minimum: values.min() ?? first.1, maximum: values.max() ?? first.1,
                samples: values.count)
        }
    }

    /// Samples inside a fractional slice of the archive time axis. This mirrors
    /// desktop OrbitDeck's zoom/pan model: a dense recent era does not receive
    /// more screen width merely because Space-Track published more element sets.
    static func historyWindow(_ samples: [OrbitalHistorySample], lower: Double = 0, upper: Double = 1) -> [OrbitalHistorySample] {
        guard let first = samples.first?.epoch, let last = samples.last?.epoch else { return [] }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return samples }
        var lo = max(0, min(1, lower)), hi = max(0, min(1, upper))
        if hi < lo { swap(&lo, &hi) }
        let start = first.addingTimeInterval(span * lo)
        let end = first.addingTimeInterval(span * hi)
        return samples.filter { $0.epoch >= start && $0.epoch <= end }
    }

    /// Consecutive-sample derivative, expressed per year. Intervals shorter
    /// than one hour are discarded because gp_history can contain several sets
    /// per day and tiny time denominators manufacture meaningless spikes.
    static func historyRateSeries(_ samples: [OrbitalHistorySample], column: HistoryColumn) -> [OrbitalHistoryRatePoint] {
        let pairs = samples.compactMap { sample in sample.value(column).map { (sample.epoch, $0) } }
        guard pairs.count >= 2 else { return [] }
        var out: [OrbitalHistoryRatePoint] = []
        out.reserveCapacity(pairs.count - 1)
        for i in 1..<pairs.count {
            let dt = pairs[i].0.timeIntervalSince(pairs[i - 1].0)
            guard dt >= 3600 else { continue }
            let mid = pairs[i - 1].0.addingTimeInterval(dt / 2)
            let rate = (pairs[i].1 - pairs[i - 1].1) / dt * 86400 * 365.25
            out.append(.init(date: mid, ratePerYear: rate))
        }
        return out
    }

    static func analyzeHistoryRate(_ samples: [OrbitalHistorySample], column: HistoryColumn) -> OrbitalHistoryRateAnalysis? {
        let points = historyRateSeries(samples, column: column)
        guard points.count >= 4, let first = points.first, let last = points.last else { return nil }
        let midpoint = first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) / 2)
        let early = points.filter { $0.date < midpoint }.map(\.ratePerYear)
        let late = points.filter { $0.date >= midpoint }.map(\.ratePerYear)
        let earlyMean = early.isEmpty ? 0 : early.reduce(0, +) / Double(early.count)
        let lateMean = late.isEmpty ? 0 : late.reduce(0, +) / Double(late.count)

        let days = points.map { $0.date.timeIntervalSince(first.date) / 86400 }
        let rates = points.map(\.ratePerYear)
        let n = Double(rates.count)
        let sx = days.reduce(0, +), sy = rates.reduce(0, +)
        let sxx = days.reduce(0) { $0 + $1 * $1 }
        let sxy = zip(days, rates).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = n * sxx - sx * sx
        let acceleration = abs(denominator) > 1e-20 ? (n * sxy - sx * sy) / denominator * 365.25 : 0

        let absoluteRates = rates.map(abs)
        let sorted = absoluteRates.sorted()
        let medianAbsolute = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let meanAbsolute = absoluteRates.reduce(0, +) / n
        let baseline = medianAbsolute > 1e-12 ? medianAbsolute : meanAbsolute
        let jumps = points.compactMap { point -> OrbitalHistoryJump? in
            baseline > 1e-12 && abs(point.ratePerYear) > 5 * baseline
                ? .init(date: point.date, ratePerYear: point.ratePerYear) : nil
        }
        let peak = points.max { abs($0.ratePerYear) < abs($1.ratePerYear) }!

        let significant = meanAbsolute > 1e-12 ? meanAbsolute * 0.1 : 1e-12
        let earlyZero = abs(earlyMean) < significant, lateZero = abs(lateMean) < significant
        let reversed = !earlyZero && !lateZero && ((earlyMean < 0) != (lateMean < 0))
        let ratio = earlyZero ? 0 : abs(lateMean) / abs(earlyMean)
        let verdict: String
        if earlyZero && !lateZero { verdict = "NEW trend developed lately" }
        else if lateZero && !earlyZero { verdict = "trend has largely ceased" }
        else if earlyZero && lateZero { verdict = "little change in either era" }
        else if reversed { verdict = "direction REVERSED between eras" }
        else if ratio >= 1.5 { verdict = String(format: "change is %.1fx FASTER lately", ratio) }
        else if ratio > 0 && ratio <= 0.67 { verdict = String(format: "change is %.1fx slower lately", 1 / ratio) }
        else { verdict = String(format: "rate roughly steady (%.2fx)", ratio) }

        return .init(intervalCount: rates.count, earlyMean: earlyMean, lateMean: lateMean,
                     ratio: ratio, reversed: reversed, accelerationPerYear: acceleration,
                     medianAbsoluteRate: medianAbsolute, meanAbsoluteRate: meanAbsolute,
                     jumps: jumps, peakRate: peak.ratePerYear, peakDate: peak.date, verdict: verdict,
                     firstDate: first.date, lastDate: last.date)
    }

    /// Fit GP/TLE n-dot from the archived PERIOD column. Returns the GP convention
    /// (rev/day², already divided by two) only for a positive decay trend spanning
    /// at least six samples and 30 days, matching desktop OrbitDeck.
    static func historyNdot(_ samples: [OrbitalHistorySample], minSpanDays: Double = 30, minPoints: Int = 6) -> Double? {
        let pairs = samples.compactMap { sample -> (Date, Double)? in
            guard let period = sample.period, period > 0 else { return nil }
            return (sample.epoch, 1440 / period)
        }.sorted { $0.0 < $1.0 }
        guard pairs.count >= minPoints,
              let first = pairs.first, let last = pairs.last,
              last.0.timeIntervalSince(first.0) / 86400 >= minSpanDays else { return nil }
        let xs = pairs.map { $0.0.timeIntervalSince(first.0) / 86400 }
        let ys = pairs.map(\.1)
        let n = Double(pairs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let slope = sxy / sxx
        guard slope > 0 else { return nil }
        return slope / 2
    }

    static func historyDecayEstimate(_ samples: [OrbitalHistorySample], satellite: SatelliteRecord) -> OrbitalHistoryDecayEstimate {
        if let fitted = historyNdot(samples) {
            let result = OrbitDecayModel.estimate(meanMotion: satellite.meanMotionRevPerDay,
                                                   ecc: satellite.eccentricity,
                                                   bstar: satellite.bstar, ndot: fitted, solar: 1)
            if result.1 == .observedNdot {
                return .init(days: result.0, source: "element archive", fittedNdot: fitted,
                             note: "Archive-fitted mean-motion trend anchors the decay model.")
            }
            return .init(days: result.0, source: result.1.label, fittedNdot: fitted,
                         note: "Archive trend fell outside the physical n-dot anchor range; using the model fallback.")
        }
        let result = OrbitDecayModel.estimate(meanMotion: satellite.meanMotionRevPerDay,
                                               ecc: satellite.eccentricity,
                                               bstar: satellite.bstar, ndot: 0, solar: 1)
        return .init(days: result.0, source: result.1.label, fittedNdot: nil,
                     note: "Archive is too short, sparse, flat, or rising to supply a decay anchor.")
    }

    // MARK: - Zone / transit helpers

    private static func directionSeparationDegrees(_ az1: Double, _ el1: Double,
                                                    _ az2: Double, _ el2: Double) -> Double {
        let a1 = az1 * degreesToRadians, e1 = el1 * degreesToRadians
        let a2 = az2 * degreesToRadians, e2 = el2 * degreesToRadians
        let cosine = sin(e1) * sin(e2) + cos(e1) * cos(e2) * cos(a1 - a2)
        return acos(max(-1, min(1, cosine))) / degreesToRadians
    }

    private static func magneticLatitude(_ latitude: Double, _ longitude: Double) -> Double {
        let poleLat = 80.7 * degreesToRadians
        let poleLon = -72.7 * degreesToRadians
        let lat = latitude * degreesToRadians
        let lon = longitude * degreesToRadians
        let value = sin(lat) * sin(poleLat) + cos(lat) * cos(poleLat) * cos(lon - poleLon)
        return asin(max(-1, min(1, value))) / degreesToRadians
    }

    private static func shellL(latitude: Double, longitude: Double, altitudeKm: Double) -> Double {
        let mlat = magneticLatitude(latitude, longitude) * degreesToRadians
        let c = cos(mlat)
        guard abs(c) > 1e-6 else { return 999 }
        return ((6371.0 + altitudeKm) / 6371.0) / (c * c)
    }

    private static func magneticBRatio(latitude: Double, longitude: Double) -> Double {
        let mlat = magneticLatitude(latitude, longitude) * degreesToRadians
        let c = cos(mlat)
        guard abs(c) > 1e-6 else { return 1e6 }
        let s = sin(mlat)
        return sqrt(1 + 3 * s * s) / pow(c, 6)
    }

    private static func inOrbitalZone(_ zone: OrbitalZone, latitude: Double,
                                      longitude: Double, altitudeKm: Double,
                                      sunlit: Bool, at date: Date,
                                      shellL: Double, bRatio: Double) -> Bool {
        let lon = normalizedLongitude(longitude)
        switch zone {
        case .saa:
            let year = Calendar(identifier: .gregorian).component(.year, from: date)
            let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: date) ?? 1
            let years = Double(year - 2025) + Double(day) / 365.0
            let centerLat = -27.0
            let centerLon = -53.0 - 0.30 * years
            let dlon = normalizedLongitude(lon - centerLon)
            let u = (latitude - centerLat) / 25.0
            let v = dlon / 55.0
            return u * u + v * v <= 1
        case .eclipse:
            return !sunlit
        case .polar:
            return abs(latitude) >= 60
        case .innerBelt, .outerBelt:
            guard altitudeKm >= 300, bRatio <= 3 else { return false }
            return zone == .innerBelt ? (1.2...2.5).contains(shellL) : (3.0...7.0).contains(shellL)
        }
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" {
                    field.append("\""); i += 1
                } else { quoted.toggle() }
            } else if ch == "," && !quoted {
                row.append(field); field = ""
            } else if (ch == "\n" || ch == "\r") && !quoted {
                if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else { field.append(ch) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func parseSpaceTrackDate(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "T", with: " ")
        let formats = ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        for format in formats {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0); df.dateFormat = format
            if let date = df.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Geometry

    static func footprintRadiusDegrees(altitudeKm: Double) -> Double {
        let radius = earthRadiusKm + altitudeKm
        guard radius > earthRadiusKm else { return 0 }
        return acos(earthRadiusKm / radius) / degreesToRadians
    }

    static func angularSeparationDegrees(_ lat1: Double, _ lon1: Double,
                                         _ lat2: Double, _ lon2: Double) -> Double {
        let a = lat1 * degreesToRadians
        let b = lat2 * degreesToRadians
        let dl = (lon2 - lon1) * degreesToRadians
        let cosine = sin(a) * sin(b) + cos(a) * cos(b) * cos(dl)
        return acos(max(-1, min(1, cosine))) / degreesToRadians
    }

    private static func state(_ satellite: Satellite, at date: Date) throws -> (position: Vector, velocity: Vector) {
        (try satellite.position(julianDays: date.julianDate),
         try satellite.velocity(julianDays: date.julianDate))
    }

    private static func separation(_ a: Vector, _ b: Vector) -> Double {
        let x = a.x - b.x
        let y = a.y - b.y
        let z = a.z - b.z
        return sqrt(x * x + y * y + z * z)
    }

    static func gmstRadians(_ jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525.0
        let gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t - t * t * t / 38710000.0
        return normalizedDegrees(gmst) * degreesToRadians
    }

    static func sunECIUnit(_ jd: Double) -> (vector: Vector, longitudeDegrees: Double) {
        let n = jd - 2451545.0
        let l = normalizedDegrees(280.460 + 0.9856474 * n)
        let g = normalizedDegrees(357.528 + 0.9856003 * n) * degreesToRadians
        let lambdaDegrees = normalizedDegrees(l + 1.915 * sin(g) + 0.020 * sin(2 * g))
        let lambda = lambdaDegrees * degreesToRadians
        let epsilon = (23.439 - 0.0000004 * n) * degreesToRadians
        return (Vector(cos(lambda), cos(epsilon) * sin(lambda), sin(epsilon) * sin(lambda)),
                lambdaDegrees)
    }

    /// Local (mean solar) Time of the Ascending Node, in hours [0,24). For a
    /// sun-synchronous orbit this is nearly constant and characterises the bird
    /// (e.g. a 10:30 morning crossing). LTAN = 12h + (RAAN − α☉)/15°.
    static func localTimeOfAscendingNode(raanDeg: Double, at date: Date) -> Double {
        let sun = sunECIUnit(date.julianDate).vector
        let raSunDeg = normalizedDegrees(atan2(sun.y, sun.x) * 180 / Double.pi)
        var hours = (raanDeg - raSunDeg) / 15.0 + 12.0
        hours = hours.truncatingRemainder(dividingBy: 24)
        if hours < 0 { hours += 24 }
        return hours
    }

    static func moonSolution(_ jd: Double) -> (vector: Vector, longitudeDegrees: Double, distanceKm: Double) {
        let d = jd - 2451543.5
        let node = normalizedDegrees(125.1228 - 0.0529538083 * d) * degreesToRadians
        let inclination = 5.1454 * degreesToRadians
        let argPerigee = normalizedDegrees(318.0634 + 0.1643573223 * d) * degreesToRadians
        let a = 60.2666
        let eccentricity = 0.054900
        let meanAnomaly = normalizedDegrees(115.3654 + 13.0649929509 * d) * degreesToRadians
        let sunMeanAnomaly = normalizedDegrees(356.0470 + 0.9856002585 * d) * degreesToRadians
        let sunArg = normalizedDegrees(282.9404 + 4.70935e-5 * d) * degreesToRadians
        let sunLongitude = sunArg + sunMeanAnomaly
        let moonMeanLongitude = node + argPerigee + meanAnomaly
        let elongation = moonMeanLongitude - sunLongitude
        let argumentLatitude = moonMeanLongitude - node

        var eccentricAnomaly = meanAnomaly + eccentricity * sin(meanAnomaly) *
            (1 + eccentricity * cos(meanAnomaly))
        for _ in 0..<6 {
            eccentricAnomaly -= (eccentricAnomaly - eccentricity * sin(eccentricAnomaly) - meanAnomaly) /
                (1 - eccentricity * cos(eccentricAnomaly))
        }
        let x = a * (cos(eccentricAnomaly) - eccentricity)
        let y = a * sqrt(1 - eccentricity * eccentricity) * sin(eccentricAnomaly)
        var radius = hypot(x, y)
        let trueAnomaly = atan2(y, x)

        let xe = radius * (cos(node) * cos(trueAnomaly + argPerigee)
                           - sin(node) * sin(trueAnomaly + argPerigee) * cos(inclination))
        let ye = radius * (sin(node) * cos(trueAnomaly + argPerigee)
                           + cos(node) * sin(trueAnomaly + argPerigee) * cos(inclination))
        let ze = radius * sin(trueAnomaly + argPerigee) * sin(inclination)
        var longitude = atan2(ye, xe) / degreesToRadians
        var latitude = atan2(ze, hypot(xe, ye)) / degreesToRadians

        longitude += -1.274 * sin(meanAnomaly - 2 * elongation)
            + 0.658 * sin(2 * elongation)
            - 0.186 * sin(sunMeanAnomaly)
            - 0.059 * sin(2 * meanAnomaly - 2 * elongation)
            - 0.057 * sin(meanAnomaly - 2 * elongation + sunMeanAnomaly)
            + 0.053 * sin(meanAnomaly + 2 * elongation)
            + 0.046 * sin(2 * elongation - sunMeanAnomaly)
            + 0.041 * sin(meanAnomaly - sunMeanAnomaly)
            - 0.035 * sin(elongation)
            - 0.031 * sin(meanAnomaly + sunMeanAnomaly)
            - 0.015 * sin(2 * argumentLatitude - 2 * elongation)
            + 0.011 * sin(meanAnomaly - 4 * elongation)
        latitude += -0.173 * sin(argumentLatitude - 2 * elongation)
            - 0.055 * sin(meanAnomaly - argumentLatitude - 2 * elongation)
            - 0.046 * sin(meanAnomaly + argumentLatitude - 2 * elongation)
            + 0.033 * sin(argumentLatitude + 2 * elongation)
            + 0.017 * sin(2 * meanAnomaly + argumentLatitude)
        radius += -0.58 * cos(meanAnomaly - 2 * elongation) - 0.46 * cos(2 * elongation)

        let lonRad = longitude * degreesToRadians
        let latRad = latitude * degreesToRadians
        let epsilon = 23.4393 * degreesToRadians
        let vx = cos(latRad) * cos(lonRad)
        let vy = cos(epsilon) * cos(latRad) * sin(lonRad) - sin(epsilon) * sin(latRad)
        let vz = sin(epsilon) * cos(latRad) * sin(lonRad) + cos(epsilon) * sin(latRad)
        return (Vector(vx, vy, vz), normalizedDegrees(longitude), radius * 6378.137)
    }

    static func vectorToAltAz(_ vector: Vector, site: ObserverSite,
                                      julianDay: Double) -> (azimuth: Double, elevation: Double) {
        let lst = gmstRadians(julianDay) + site.longitude * degreesToRadians
        let sinSidereal = sin(lst)
        let cosSidereal = cos(lst)
        let sinLat = sin(site.latitude * degreesToRadians)
        let cosLat = cos(site.latitude * degreesToRadians)
        let east = -sinSidereal * vector.x + cosSidereal * vector.y
        let north = -sinLat * cosSidereal * vector.x - sinLat * sinSidereal * vector.y + cosLat * vector.z
        let up = cosLat * cosSidereal * vector.x + cosLat * sinSidereal * vector.y + sinLat * vector.z
        return (normalizedDegrees(atan2(east, north) / degreesToRadians),
                atan2(up, hypot(east, north)) / degreesToRadians)
    }

    private static func isSunlit(position: Vector, julianDay: Double) -> Bool {
        let sun = sunECIUnit(julianDay).vector
        let projection = position.x * sun.x + position.y * sun.y + position.z * sun.z
        let r2 = position.x * position.x + position.y * position.y + position.z * position.z
        let perpendicular = sqrt(max(0, r2 - projection * projection))
        return !(projection < 0 && perpendicular < earthRadiusKm)
    }

    private static let planetElements: [String: [Double]] = [
        "Mercury": [0.38709927, 0.20563593, 7.00497902, 252.25032350, 77.45779628, 48.33076593,
                    0.00000037, 0.00001906, -0.00594749, 149472.67411175, 0.16047689, -0.12534081],
        "Venus": [0.72333566, 0.00677672, 3.39467605, 181.97909950, 131.60246718, 76.67984255,
                  0.00000390, -0.00004107, -0.00078890, 58517.81538729, 0.00268329, -0.27769418],
        "Mars": [1.52371034, 0.09339410, 1.84969142, -4.55343205, -23.94362959, 49.55953891,
                 0.00001847, 0.00007882, -0.00813131, 19140.30268499, 0.44441088, -0.29257343],
        "Jupiter": [5.20288700, 0.04838624, 1.30439695, 34.39644051, 14.72847983, 100.47390909,
                    -0.00011607, -0.00013253, -0.00183714, 3034.74612775, 0.21252668, 0.20469106],
        "Saturn": [9.53667594, 0.05386179, 2.48599187, 49.95424423, 92.59887831, 113.66242448,
                   -0.00125060, -0.00050991, 0.00193609, 1222.49362201, -0.41897216, -0.28867794]
    ]

    private static let earthElements: [Double] = [
        1.00000261, 0.01671123, -0.00001531, 100.46457166, 102.93768193, 0.0,
        0.00000562, -0.00004392, -0.01294668, 35999.37244981, 0.32327364, 0.0
    ]

    private static func heliocentricXYZ(_ elements: [Double], date: Date) -> (Double, Double, Double) {
        let t = (date.julianDate - 2451545.0) / 36525.0
        let a = elements[0] + elements[6] * t
        let e = elements[1] + elements[7] * t
        let i = (elements[2] + elements[8] * t) * degreesToRadians
        let l = elements[3] + elements[9] * t
        let peri = elements[4] + elements[10] * t
        var node = elements[5] + elements[11] * t
        let m = normalizedDegrees(l - peri) * degreesToRadians
        let w = (peri - node) * degreesToRadians
        node *= degreesToRadians
        var eccentricAnomaly = m
        for _ in 0..<8 {
            eccentricAnomaly -= (eccentricAnomaly - e * sin(eccentricAnomaly) - m) /
                (1 - e * cos(eccentricAnomaly))
        }
        let xv = a * (cos(eccentricAnomaly) - e)
        let yv = a * sqrt(1 - e * e) * sin(eccentricAnomaly)
        let xh = xv * (cos(w) * cos(node) - sin(w) * sin(node) * cos(i))
            + yv * (-sin(w) * cos(node) - cos(w) * sin(node) * cos(i))
        let yh = xv * (cos(w) * sin(node) + sin(w) * cos(node) * cos(i))
            + yv * (-sin(w) * sin(node) + cos(w) * cos(node) * cos(i))
        let zh = xv * sin(w) * sin(i) + yv * cos(w) * sin(i)
        return (xh, yh, zh)
    }

    static func planetRaDec(name: String, date: Date) -> (ra: Double, dec: Double)? {
        guard let elements = planetElements[name] else { return nil }
        let p = heliocentricXYZ(elements, date: date)
        let e = heliocentricXYZ(earthElements, date: date)
        let gx = p.0 - e.0
        let gy = p.1 - e.1
        let gz = p.2 - e.2
        let epsilon = 23.43928 * degreesToRadians
        let xq = gx
        let yq = gy * cos(epsilon) - gz * sin(epsilon)
        let zq = gy * sin(epsilon) + gz * cos(epsilon)
        return (normalizedDegrees(atan2(yq, xq) / degreesToRadians),
                atan2(zq, hypot(xq, yq)) / degreesToRadians)
    }

    static func raDecToAzEl(raDegrees: Double, decDegrees: Double,
                                    site: ObserverSite, date: Date) -> (azimuth: Double, elevation: Double) {
        let lst = gmstRadians(date.julianDate) + site.longitude * degreesToRadians
        let hourAngle = lst - raDegrees * degreesToRadians
        let dec = decDegrees * degreesToRadians
        let sinLat = sin(site.latitude * degreesToRadians)
        let cosLat = cos(site.latitude * degreesToRadians)
        let sinDec = sin(dec)
        let cosDec = cos(dec)
        let elevation = asin(sinLat * sinDec + cosLat * cosDec * cos(hourAngle))
        // Azimuth from North, measured eastward. The sin(hourAngle) term must be
        // positive here; a leading minus mirrored azimuth about the meridian, which
        // put planets on the wrong side of the sky (e.g. Venus shown east of you
        // when it was west). Matches the ENU convention used by vectorToAltAz.
        let azimuth = atan2(cosDec * sin(hourAngle),
                            cosDec * cos(hourAngle) * sinLat - sinDec * cosLat) + .pi
        return (normalizedDegrees(azimuth / degreesToRadians), elevation / degreesToRadians)
    }

    static func normalizedDegrees(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 360.0)
        return result < 0 ? result + 360 : result
    }

    static func normalizedLongitude(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360.0)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}


actor SpaceTrackHistoryService {
    enum ServiceError: LocalizedError {
        case missingCredentials
        case rejected
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials: "Enter your Space-Track identity and password."
            case .rejected: "Space-Track login was rejected."
            case .invalidResponse: "Space-Track returned an invalid response."
            case .server(let message): message
            }
        }
    }

    private static let columns = "EPOCH,SEMIMAJOR_AXIS,ECCENTRICITY,INCLINATION,PERIOD,APOAPSIS,PERIAPSIS,BSTAR"
    /// Space-Track asks for a minimum ~3 s between queries; the actor serializes
    /// requests and spaces them to stay well within the published rate limits.
    private var lastRequestAt: Date?
    private static let minRequestInterval: TimeInterval = 3

    func cachedHistory(norad: UInt) -> [OrbitalHistorySample]? {
        let url = cacheURL(norad: norad)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([OrbitalHistorySample].self, from: data)
    }

    func fetchHistory(norad: UInt, identity: String, password: String) async throws -> [OrbitalHistorySample] {
        guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else { throw ServiceError.missingCredentials }

        // Space these requests to respect Space-Track's minimum query interval.
        if let last = lastRequestAt {
            let wait = Self.minRequestInterval - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lastRequestAt = Date()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        // Bound the requests so a dropped connection surfaces an error instead of
        // hanging on the system default (~60 s request / 7 day resource).
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        guard let loginURL = URL(string: "https://www.space-track.org/ajaxauth/login") else {
            throw ServiceError.invalidResponse
        }
        var login = URLRequest(url: loginURL)
        login.httpMethod = "POST"
        login.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "identity=\(formEncode(identity))&password=\(formEncode(password))"
        login.httpBody = body.data(using: .utf8)
        let (loginData, loginResponse) = try await session.data(for: login)
        guard let httpLogin = loginResponse as? HTTPURLResponse,
              (200..<400).contains(httpLogin.statusCode) else { throw ServiceError.rejected }
        let loginText = String(decoding: loginData, as: UTF8.self).lowercased()
        if loginText.contains("invalid") || loginText.contains("failed") || loginText.contains("denied") {
            throw ServiceError.rejected
        }

        let path = "https://www.space-track.org/basicspacedata/query/class/gp_history/NORAD_CAT_ID/\(norad)/EPOCH/%3E1957-01-01/orderby/EPOCH%20asc/format/csv/predicates/\(Self.columns)"
        guard let historyURL = URL(string: path) else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: historyURL)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ServiceError.server("Space-Track history query failed.")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") {
            throw ServiceError.server("Space-Track returned HTML; the authenticated session may have expired.")
        }
        let samples = FeatureEngine.parseOrbitalHistoryCSV(text)
        if !samples.isEmpty { saveCache(samples, norad: norad) }
        return samples
    }

    private func cacheURL(norad: UInt) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OrbitDeck/SpaceTrackHistory", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(norad).json")
    }

    private func saveCache(_ samples: [OrbitalHistorySample], norad: UInt) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: cacheURL(norad: norad), options: .atomic)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}


struct SpaceWeatherService {
    static func fetch() async throws -> SpaceWeatherSnapshot {
        async let fluxData = get(URL(string: "https://services.swpc.noaa.gov/json/f107_cm_flux.json")!)
        // Official 3-hour estimated planetary Kp (fractional) + running A index —
        // the value other space-weather sources display. The older 1-minute file
        // carried an integer `kp_index` (floor) that read as 0 for a real Kp of 0.33.
        async let kpData = get(URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!)
        async let cycleData = get(URL(string: "https://services.swpc.noaa.gov/json/solar-cycle/observed-solar-cycle-indices.json")!)
        async let geomagneticData = getOptional(URL(string: "https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt")!)
        // Most-recent DAILY observed (SESC) sunspot number; the solar-cycle file is
        // only monthly, so this keeps the sunspot number as current as flux and Kp.
        async let dailyData = getOptional(URL(string: "https://services.swpc.noaa.gov/text/daily-solar-indices.txt")!)
        // The community-standard sunspot number shown by the N0NBH/hamqsl solar
        // widget most hams compare against (differs from NOAA's SESC count).
        async let hamData = getOptionalBrowser(URL(string: "https://www.hamqsl.com/solarxml.php")!)
        let (fData, kData, cData, gData, dData, hData) = try await (fluxData, kpData, cycleData, geomagneticData, dailyData, hamData)
        var flux: Double?
        var flux90: Double?
        if let rows = try JSONSerialization.jsonObject(with: fData) as? [[String: Any]] {
            let valid = rows.filter { $0["time_tag"] != nil && numeric($0["flux"]) != nil }
            if let newest = valid.max(by: { String(describing: $0["time_tag"] ?? "") < String(describing: $1["time_tag"] ?? "") }) {
                flux = numeric(newest["flux"])
                flux90 = numeric(newest["ninety_day_mean"])
            }
        }
        // Prefer the N0NBH/hamqsl sunspot number (matches the ham solar widget most
        // operators reference); fall back to NOAA's daily SESC number, then the
        // monthly observed value (and use the monthly f10.7 for the 90-day mean if
        // the flux feed didn't carry one).
        var ssn: Double? = hData.flatMap { parseHamqslSunspots($0) } ?? dData.flatMap { parseDailySunspot($0) }
        if let rows = try JSONSerialization.jsonObject(with: cData) as? [[String: Any]] {
            let valid = rows.filter { $0["time-tag"] != nil && numeric($0["ssn"]) != nil }
            if let newest = valid.max(by: { String(describing: $0["time-tag"] ?? "") < String(describing: $1["time-tag"] ?? "") }) {
                if ssn == nil, let n = numeric(newest["ssn"]), n >= 0 { ssn = n }
                if flux90 == nil { flux90 = numeric(newest["f10.7"]) }
            }
        }
        let (kp, aRunning) = parsePlanetaryKp(kData)
        let reportedA = gData.flatMap(parsePlanetaryA)
        // Prefer the finalized daily planetary A; fall back to the running A from
        // the Kp product, then to a Kp→ap conversion.
        let aIndex = reportedA ?? aRunning ?? kp.map(kpToAP)
        let aSource: String?
        if reportedA != nil { aSource = "NOAA daily planetary A" }
        else if aRunning != nil { aSource = "NOAA running planetary A" }
        else { aSource = kp == nil ? nil : "Kp→ap equivalent" }
        return SpaceWeatherSnapshot(fetchedAt: .now, flux: flux, kp: kp,
                                    aIndex: aIndex, aIndexSource: aSource,
                                    sunspotNumber: ssn, flux90Day: flux90)
    }

    /// Parse NOAA's 3-hour planetary Kp product for the newest fractional Kp and
    /// its running A index. NOAA serves this in two shapes over time, so handle
    /// both:
    ///   • array of objects: [{"time_tag":…,"Kp":0.33,"a_running":2,…}, …]
    ///   • array of arrays with a header row:
    ///       [["time_tag","Kp","a_running","station_count"], ["…","0.33","2","6"], …]
    static func parsePlanetaryKp(_ data: Data) -> (kp: Double?, aRunning: Double?) {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return (nil, nil) }

        // Shape 1: array of dictionaries (current SWPC format).
        let dicts: [[String: Any]] = top.compactMap { $0 as? [String: Any] }
        if dicts.count == top.count && !dicts.isEmpty {
            func kpOf(_ d: [String: Any]) -> Double? {
                numeric(d["Kp"] ?? d["kp"] ?? d["kp_index"] ?? d["estimated_kp"])
            }
            let valid = dicts.filter { kpOf($0) != nil }
            guard let newest = valid.max(by: {
                String(describing: $0["time_tag"] ?? "") < String(describing: $1["time_tag"] ?? "")
            }) else { return (nil, nil) }
            let a = numeric(newest["a_running"] ?? newest["a"])
            return (kpOf(newest), a.flatMap { $0 >= 0 ? $0 : nil })
        }

        // Shape 2: array of arrays with a leading header row.
        // Cast the outer array then map each row: a direct `as? [[Any]]` deep-cast
        // of the bridged NSArray fails at runtime even for valid nested arrays.
        let rows: [[Any]] = top.compactMap { $0 as? [Any] }
        guard rows.count > 1 else { return (nil, nil) }
        // Locate columns from the header so we tolerate reordering.
        let header = rows[0].map { String(describing: $0).lowercased() }
        let kpCol = header.firstIndex(where: { $0 == "kp" }) ?? 1
        let aCol = header.firstIndex(where: { $0.contains("a_running") || $0 == "a" }) ?? 2
        let timeCol = header.firstIndex(where: { $0.contains("time") }) ?? 0
        let body = rows.dropFirst().filter { row in
            row.count > max(kpCol, timeCol) && numeric(row[kpCol]) != nil
        }
        guard let newest = body.max(by: {
            String(describing: $0[timeCol]) < String(describing: $1[timeCol])
        }) else { return (nil, nil) }
        let kp = numeric(newest[kpCol])
        let a = newest.count > aCol ? numeric(newest[aCol]) : nil
        return (kp, a.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// Parse NOAA SWPC's Daily Geomagnetic Data product. The file contains
    /// separate Middle Latitude, High Latitude and Estimated Planetary tables;
    /// each data row starts YYYY MM DD followed by the 24-hour A index and the
    /// eight 3-hour K indices. Use the newest valid row in the Estimated
    /// Planetary section and ignore -1/missing records.
    static func parsePlanetaryA(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var inPlanetary = false
        var latest: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.contains("estimated planetary") {
                inPlanetary = true
                continue
            }
            if inPlanetary && (lower.contains("middle latitude") || lower.contains("high latitude")) {
                inPlanetary = false
            }
            guard inPlanetary else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 4,
                  fields[0].count == 4,
                  Int(fields[0]) != nil,
                  Int(fields[1]) != nil,
                  Int(fields[2]) != nil,
                  let a = Double(fields[3]), a >= 0 else { continue }
            latest = a
        }
        return latest
    }

    /// Parse NOAA SWPC's Daily Solar Data product for the newest daily observed
    /// (SESC) sunspot number. Each data row is `YYYY MM DD  <10.7cm flux>
    /// <sunspot number> …`; the sunspot number is the fifth whitespace field.
    static func parseDailySunspot(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var latest: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 5,
                  fields[0].count == 4,
                  Int(fields[0]) != nil,
                  Int(fields[1]) != nil,
                  Int(fields[2]) != nil,
                  let ssn = Double(fields[4]), ssn >= 0 else { continue }
            latest = ssn
        }
        return latest
    }

    private static func getOptional(_ url: URL) async -> Data? {
        try? await get(url)
    }

    /// Optional GET with a browser User-Agent (some community feeds reject
    /// non-browser agents).
    private static func getOptionalBrowser(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: request).0
    }

    /// Parse the `<sunspots>` value from the N0NBH/hamqsl solar XML.
    static func parseHamqslSunspots(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "<sunspots>"),
              let end = text.range(of: "</sunspots>", range: start.upperBound..<text.endIndex) else { return nil }
        let inner = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(inner)
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func kpToAP(_ kp: Double) -> Double {
        let table: [(Double, Double)] = [
            (0,0),(0.33,2),(0.67,3),(1,4),(1.33,5),(1.67,6),(2,7),(2.33,9),
            (2.67,12),(3,15),(3.33,18),(3.67,22),(4,27),(4.33,32),(4.67,39),
            (5,48),(5.33,56),(5.67,67),(6,80),(6.33,94),(6.67,111),(7,132),
            (7.33,154),(7.67,179),(8,207),(8.33,236),(8.67,300),(9,400)
        ]
        return table.min(by: { abs($0.0 - kp) < abs($1.0 - kp) })?.1 ?? 0
    }
}

struct AmsatStatusService {
    static func fetchSummary(hours: Int = 24) async throws -> [AmsatStatusSummaryRecord] {
        guard let url = URL(string: "https://www.amsat.org/status/api/v1/summary.php?hours=\(hours)") else { return [] }
        let data = try await requestData(url)   // browser UA + retry (some CDNs block custom agents)
        let object = try JSONSerialization.jsonObject(with: data)
        let records: [[String: Any]]
        if let d = object as? [String: Any], let error = d["error"] as? [String: Any] {
            throw NSError(domain: "AMSAT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(describing: error["message"] ?? "AMSAT API error")])
        } else if let d = object as? [String: Any] {
            records = (d["data"] as? [[String: Any]]) ?? (d["summary"] as? [[String: Any]]) ?? []
        } else { records = object as? [[String: Any]] ?? [] }
        var grouped: [String: (display: String, reports: Int, heard: Int, last: String)] = [:]
        for row in records {
            let name = (row["name"] as? String) ?? (row["satellite"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            let count = int(row["report_count"] ?? row["reports"] ?? row["count"])
            let status = String(describing: row["report"] ?? row["status"] ?? "")
            let last = String(describing: row["latest_reported_time"] ?? row["last_report"] ?? row["reported_time"] ?? "")
            var g = grouped[name] ?? (pretty(name), 0, 0, "")
            g.reports += count
            if status.lowercased().hasPrefix("heard") { g.heard += count }
            if last > g.last { g.last = last }
            grouped[name] = g
        }
        return grouped.map { key, value in
            AmsatStatusSummaryRecord(id: key, apiName: key, displayName: value.display,
                                     reports: value.reports, heard: value.heard, lastReport: value.last)
        }.sorted { a, b in
            a.reports != b.reports ? a.reports > b.reports : a.displayName < b.displayName
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(Double(s) ?? 0) }
        return 0
    }
    private static func pretty(_ name: String) -> String {
        name.replacingOccurrences(of: "_[", with: " (")
            .replacingOccurrences(of: "[", with: " (")
            .replacingOccurrences(of: "]", with: ")")
    }
}

struct NewLaunchService {
    static func discover(knownNorads: Set<UInt>) async throws -> [NewLaunchHit] {
        let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=last-30-days&FORMAT=JSON")!
        var request = URLRequest(url: url); request.timeoutInterval = 45
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let gpURLRequest = request
        async let gpRequest = URLSession.shared.data(for: gpURLRequest)
        async let txRequest = TransponderService.fetchAll()
        let ((data, response), transmitters) = try await (gpRequest, txRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var hits: [NewLaunchHit] = []
        for row in rows {
            let name = (row["OBJECT_NAME"] as? String) ?? ""
            let norad: UInt?
            if let n = row["NORAD_CAT_ID"] as? NSNumber { norad = UInt(n.uint64Value) }
            else if let s = row["NORAD_CAT_ID"] as? String { norad = UInt(s) }
            else { norad = nil }
            guard let norad else { continue }
            guard let txValue = transmitters[norad] else { continue }
            let tx: [TransponderRecord] = txValue
            guard let first = tx.first(where: { $0.downlinkLow > 0 }) ?? tx.first,
                  var record = GPService.parseOMM(row) else { continue }
            record.transponders = tx
            hits.append(NewLaunchHit(id: norad, name: name.isEmpty ? "NORAD \(norad)" : name,
                                     transmitterCount: tx.count, downlinkHz: first.downlinkLow,
                                     mode: first.mode, alreadyInCatalog: knownNorads.contains(norad),
                                     record: record, transponders: tx, isNoise: isNoise(name)))
        }
        return hits.sorted { $0.id > $1.id }
    }

    private static func isNoise(_ rawName: String) -> Bool {
        let name = rawName.uppercased()
        if name.contains("TBA") || name.contains("TO BE ASSIGNED") { return false }
        if name.contains("R/B") || name.contains(" DEB") || name.hasSuffix("DEB") || name.contains("DEBRIS") { return true }
        // Mirrors the desktop's curated list: only tokens for objects that cannot
        // carry an amateur transmitter, or that arrive in industrial-quantity
        // fleets. Deliberately NOT commercial-operator names (SES/INTELSAT/…) —
        // those would cut real amateur payloads.
        let tokens = [
            // broadband / IoT constellations
            "STARLINK","ONEWEB","KUIPER","QIANFAN","SPACESAIL","GUOWANG",
            "LIGHTSPEED","HONGYAN","HONGYUN","YINHE","GALAXYSPACE","LEOSAT",
            "IRIDIUM","GLOBALSTAR","ORBCOMM","SPACEBEE","SWARM","LACUNA",
            "O3B","ASTROCAST","KEPLER","FOSSA",
            // commercial imaging / SAR fleets
            "FLOCK","SKYSAT","LEMUR","ICEYE","CAPELLA","BLACKSKY","PLANET",
            "NUSAT","SUPERVIEW","JILIN","GAOFEN","YAOGAN","SIWEI","PELICAN",
            "TANAGER","EOS-","SENTINEL","WORLDVIEW","GEOEYE",
            // navigation
            "NAVSTAR","GPS BIII","GLONASS","BEIDOU","GALILEO","IRNSS","QZS",
            // launch hardware / upper stages
            "SHROUD","FAIRING","PLATFORM","AKM","ADAPTER","DISPENSER",
            "BREEZE","CENTAUR","FREGAT","BLOCK DM"
        ]
        return tokens.contains(where: name.contains)
    }
}

// MARK: - 0.4 operating/data-feed feature slice

struct MUFRegionResult: Identifiable, Sendable {
    let id: String
    let name: String
    let mufMHz: Double
    let workableMHz: Double
    let bestBand: String
    let quality: String
    let distanceKm: Double
    let bearingDegrees: Double
}

struct PropagationBandRecord: Identifiable, Sendable {
    let id: String
    let band: String
    let dayState: String
    let nightState: String
}

struct PropagationOutlookSnapshot: Sendable {
    let flux: Double?
    let kp: Double?
    let dayMUF: Double?
    let nightMUF: Double?
    let geomagnetic: String
    let aurora: String
    let absorption: String
    let meteor: String
    let sporadicE: String
    let bands: [PropagationBandRecord]
    let summary: String
}

struct ActivationRecord: Identifiable, Sendable {
    let id: String
    let title: String
    let date: String
    let callsign: String
    let satellite: String
    let grid: String
    let start: String
    let end: String
    let maximumElevation: String
    let frequency: String
    let mode: String
    let comment: String
}

struct ActivationCheckResult: Sendable {
    let workable: Bool
    let message: String
    let satellite: SatelliteRecord?
    let listedDate: Date?
    let mutualWindow: MutualWindowRecord?
    let myMaximumElevation: Double?
}


struct ActivationDetailResult: Identifiable, Sendable {
    let activation: ActivationRecord
    let satellite: SatelliteRecord
    let dxSite: ObserverSite
    let listedDate: Date
    let windows: [MutualWindowRecord]
    var id: String { activation.id }
}

enum DXDopplerMode: String, CaseIterable, Identifiable, Sendable {
    case trueRule
    case fixedDownlink
    case fixedUplink
    var id: String { rawValue }
    var label: String {
        switch self {
        case .trueRule: "True rule"
        case .fixedDownlink: "Fixed downlink"
        case .fixedUplink: "Fixed uplink"
        }
    }
}

enum DXDopplerAnchor: String, CaseIterable, Identifiable, Sendable {
    case myRX, myTX, dxRX, dxTX
    var id: String { rawValue }
    var label: String {
        switch self {
        case .myRX: "My RX"
        case .myTX: "My TX"
        case .dxRX: "DX RX"
        case .dxTX: "DX TX"
        }
    }
    var isDX: Bool { self == .dxRX || self == .dxTX }
}

struct DXDopplerRow: Identifiable, Sendable {
    let date: Date
    let myRX: Int64
    let myTX: Int64
    let dxRX: Int64
    let dxTX: Int64
    var id: Date { date }
}

enum DXDopplerEngine {
    static func table(
        satellite: SatelliteRecord,
        home: ObserverSite,
        dx: ObserverSite,
        transponder: TransponderRecord,
        window: MutualWindowRecord,
        offsetHz: Int64,
        mode: DXDopplerMode,
        anchor: DXDopplerAnchor,
        calDlHz: Int64 = 0,
        calUlHz: Int64 = 0,
        step: TimeInterval = 30
    ) throws -> [DXDopplerRow] {
        var rows: [DXDopplerRow] = []
        var t = window.start
        let safeStep = max(5, step)
        while t <= window.end.addingTimeInterval(0.5), rows.count < 100_000 {
            let d = try dials(at: t, reference: window.start, satellite: satellite, home: home, dx: dx,
                              transponder: transponder, offsetHz: offsetHz, mode: mode, anchor: anchor,
                              calDlHz: calDlHz, calUlHz: calUlHz)
            rows.append(.init(date: t, myRX: d.0, myTX: d.1, dxRX: d.2, dxTX: d.3))
            t = t.addingTimeInterval(safeStep)
        }
        return rows
    }

    static func skyTrack(
        satellite: SatelliteRecord,
        observer: ObserverSite,
        window: MutualWindowRecord,
        step: TimeInterval = 20
    ) throws -> [SkyPoint] {
        var points: [SkyPoint] = []
        var t = window.start
        let safeStep = max(5, step)
        while t <= window.end.addingTimeInterval(0.5) {
            let look = try OrbitPredictor.look(satellite, observer: observer, at: t)
            points.append(.init(id: t, date: t, azimuth: look.azimuth, elevation: look.elevation))
            t = t.addingTimeInterval(safeStep)
        }
        if points.last?.date != window.end {
            let look = try OrbitPredictor.look(satellite, observer: observer, at: window.end)
            points.append(.init(id: window.end, date: window.end, azimuth: look.azimuth, elevation: look.elevation))
        }
        return points
    }

    static func matchingTransponder(_ activation: ActivationRecord, in satellite: SatelliteRecord) -> (index: Int, leg: String, hz: Int64)? {
        guard let hz = advertisedFrequencyHz(activation.frequency) else { return nil }
        for (index, tp) in satellite.transponders.enumerated() {
            if contains(hz, low: tp.downlinkLow, high: tp.downlinkHigh) { return (index, "downlink", hz) }
            if contains(hz, low: tp.uplinkLow, high: tp.uplinkHigh) { return (index, "uplink", hz) }
        }
        return nil
    }

    static func solvePassbandOffset(
        targetHz: Int64,
        satellite: SatelliteRecord,
        home: ObserverSite,
        dx: ObserverSite,
        transponder: TransponderRecord,
        reference: Date,
        mode: DXDopplerMode,
        anchor: DXDopplerAnchor
    ) -> Int64 {
        guard transponder.isLinear, transponder.bandwidth > 0 else { return 0 }
        let index: Int
        switch anchor { case .myRX: index = 0; case .myTX: index = 1; case .dxRX: index = 2; case .dxTX: index = 3 }
        func dial(_ offset: Double) -> Double? {
            guard let d = try? dials(at: reference, reference: reference, satellite: satellite, home: home, dx: dx,
                                     transponder: transponder, offsetHz: Int64(offset.rounded()), mode: mode, anchor: anchor) else { return nil }
            return Double([d.0, d.1, d.2, d.3][index])
        }
        guard let base = dial(0), let probeDial = dial(1000) else { return 0 }
        let slope = (probeDial - base) / 1000
        guard abs(slope) > 1e-6 else { return 0 }
        var offset = (Double(targetHz) - base) / slope
        for _ in 0..<24 {
            guard let here = dial(offset) else { break }
            let error = Double(targetHz) - here
            if abs(error) <= 0.5 { break }
            guard let nearby = dial(offset + 1000) else { break }
            let local = (nearby - here) / 1000
            if abs(local) < 1e-6 { break }
            offset += error / local
        }
        return Int64(max(0, min(Double(transponder.bandwidth), offset)).rounded())
    }

    private static func dials(
        at date: Date,
        reference: Date,
        satellite: SatelliteRecord,
        home: ObserverSite,
        dx: ObserverSite,
        transponder: TransponderRecord,
        offsetHz: Int64,
        mode: DXDopplerMode,
        anchor: DXDopplerAnchor,
        calDlHz: Int64 = 0,
        calUlHz: Int64 = 0
    ) throws -> (Int64, Int64, Int64, Int64) {
        _ = reference   // No longer needed: the CardSat model derives the operating
                        // point live from the anchor's current Doppler, not a fixed
                        // reference-time value.
        let nominal = OrbitPredictor.passbandFrequencies(transponder, offsetHz: offsetHz)
        let homeLook = try OrbitPredictor.look(satellite, observer: home, at: date)
        let dxLook = try OrbitPredictor.look(satellite, observer: dx, at: date)
        let dlOp = Double(nominal.downlink), ulOp = Double(nominal.uplink)
        let sign = transponder.invert ? -1.0 : 1.0
        let bHome = homeLook.rangeRateKmS * 1000 / OrbitPredictor.speedOfLightMS
        let bDX = dxLook.rangeRateKmS * 1000 / OrbitPredictor.speedOfLightMS

        // Determine the satellite-frame operating point (dlSat = emitted downlink,
        // ulSat = heard uplink) at this instant, following CardSat's "One True Rule":
        // in a fixed mode the anchor station parks the *nominal* ground dial and the
        // satellite-frame point is derived from that station's live Doppler; the
        // linked leg carries the drift (sign-flipped for inverting transponders).
        let dlSat: Double, ulSat: Double
        switch mode {
        case .trueRule:
            dlSat = dlOp; ulSat = ulOp
        case .fixedDownlink:
            let bAnchor = anchor.isDX ? bDX : bHome
            let denom = abs(1 - bAnchor) < 1e-12 ? 1e-12 : 1 - bAnchor
            dlSat = dlOp / denom                                  // parked RX = dlOp
            ulSat = ulOp == 0 ? 0 : ulOp + sign * (dlSat - dlOp)
        case .fixedUplink:
            let bAnchor = anchor.isDX ? bDX : bHome
            let heard = ulOp * (1 - bAnchor)                      // parked TX = ulOp
            ulSat = ulOp == 0 ? 0 : heard
            dlSat = dlOp + sign * (heard - ulOp)
        }

        // Each station tunes for its own Doppler. Calibration is the operator's OWN
        // combined oscillator error (radio + satellite), which the operator can
        // measure from either the downlink or the uplink leg. Both offsets fold into
        // a single overall correction referred to the downlink and applied only to
        // my receive dial — the uplink contribution is sign-flipped on an inverting
        // transponder. The transmit dial is left on the computed frequency, and the
        // DX station's dials are never calibrated.
        let overallCal = Double(calDlHz) + sign * Double(calUlHz)
        func stationDials(_ b: Double, mine: Bool) -> (Int64, Int64) {
            let rx = Int64((dlSat * (1 - b) + (mine ? overallCal : 0)).rounded())
            let tx = ulSat > 0 ? Int64((ulSat / (1 - b)).rounded()) : 0
            return (rx, tx)
        }
        let me = stationDials(bHome, mine: true)
        let them = stationDials(bDX, mine: false)
        return (me.0, me.1, them.0, them.1)
    }

    private static func contains(_ hz: Int64, low: Int64, high: Int64) -> Bool {
        guard low > 0 else { return false }
        let lo = min(low, high > 0 ? high : low)
        let hi = max(low, high > 0 ? high : low)
        let tolerance: Int64 = lo == hi ? 25_000 : 0
        return hz >= lo - tolerance && hz <= hi + tolerance
    }

    private static func advertisedFrequencyHz(_ text: String) -> Int64? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else { return nil }
        let hz = value > 100_000 ? Int64(value.rounded()) : Int64((value * 1_000_000).rounded())
        // Sanity band (20 MHz – 25 GHz): reject a number that isn't plausibly an
        // amateur-satellite RF frequency (e.g. a stray elevation or count).
        guard hz >= 20_000_000, hz <= 25_000_000_000 else { return nil }
        return hz
    }
}

struct QRZRecord: Sendable {
    let call: String
    let name: String
    let address: String
    let country: String
    let grid: String
    let licenseClass: String
}

struct AmsatReportRecord: Identifiable, Sendable {
    let id: String
    let callsign: String
    let grid: String
    let status: String
    let date: Date?
    let rawTime: String
}

enum MUFEngine {
    static let workableFraction = 0.85
    private static let piC = 3.141593
    private static let halfPiC = 1.570796
    private static let d2r = Double.pi / 180.0

    // Longitude is west-positive here because MINIMUF-3.5 uses that convention.
    static let regions: [(String, Double, Double)] = [
        ("W Europe", 50, -5), ("E Europe", 52, -21),
        ("Scandinavia", 60, -18), ("Iceland", 64, 22),
        ("Mediterranean", 40, -15), ("W Africa", 10, 2),
        ("N Africa", 30, -5), ("E Africa", 1, -37),
        ("S Africa", -26, -28), ("Middle East", 30, -45),
        ("Russia/C Asia", 55, -83), ("S Asia", 20, -78),
        ("China", 35, -116), ("Japan", 36, -140),
        ("SE Asia", 1, -104), ("Oceania", -18, -178),
        ("Australia", -34, -151), ("N America E", 40, 74),
        ("N America W", 37, 122), ("Caribbean", 18, 66),
        ("C America", 15, 90), ("S America N", 4, 74),
        ("S America S", -34, 58), ("Arctic", 80, 0)
    ]

    static func ssnFromFlux(_ flux: Double?) -> Double {
        guard let flux else { return 100 }
        return max(0, 1.61 * (flux - 67.0))
    }

    static func toRegions(observer: ObserverSite, date: Date = .now, ssn: Double) -> [MUFRegionResult] {
        let cal = utcCalendar
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        let hour = Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60.0
        return regions.map { name, lat, westLon in
            let muf = minimufMHz(lat1: observer.latitude * d2r,
                                 westLon1: -observer.longitude * d2r,
                                 lat2: lat * d2r, westLon2: westLon * d2r,
                                 month: month, day: day, utHours: hour, ssn: ssn)
            let geometry = greatCircle(lat1: observer.latitude, lon1: observer.longitude,
                                       lat2: lat, lon2: -westLon)
            return MUFRegionResult(id: name, name: name, mufMHz: muf,
                                   workableMHz: workableFraction * muf,
                                   bestBand: workableBand(muf), quality: quality(muf),
                                   distanceKm: geometry.distanceKm,
                                   bearingDegrees: geometry.bearingDegrees)
        }
    }

    static func toDestination(observer: ObserverSite, destination: LatLon,
                              date: Date = .now, ssn: Double) -> MUFRegionResult {
        let cal = utcCalendar
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        let hour = Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60.0
        let muf = minimufMHz(lat1: observer.latitude * d2r,
                             westLon1: -observer.longitude * d2r,
                             lat2: destination.latitude * d2r,
                             westLon2: -destination.longitude * d2r,
                             month: month, day: day, utHours: hour, ssn: ssn)
        let geometry = greatCircle(lat1: observer.latitude, lon1: observer.longitude,
                                   lat2: destination.latitude, lon2: destination.longitude)
        return MUFRegionResult(id: "custom", name: "Custom destination", mufMHz: muf,
                               workableMHz: workableFraction * muf,
                               bestBand: workableBand(muf), quality: quality(muf),
                               distanceKm: geometry.distanceKm,
                               bearingDegrees: geometry.bearingDegrees)
    }

    static func minimufMHz(lat1: Double, westLon1: Double, lat2: Double, westLon2: Double,
                           month: Int, day: Int, utHours: Double, ssn: Double) -> Double {
        let l1 = lat1, w1 = westLon1, l2 = lat2, w2 = westLon2
        let m0 = Double(month), d6 = Double(day), t5 = utHours, s9 = ssn
        var ft = sin(l1) * sin(l2) + cos(l1) * cos(l2) * cos(w2 - w1)
        let dist = acos(clamp1(ft))
        let k6 = max(1.0, 1.59 * dist)
        let p = sin(l2), q = cos(l2)
        let a: Double
        if abs(q) < 1e-12 || abs(sin(dist)) < 1e-12 {
            a = 0
        } else {
            a = (sin(l1) - p * cos(dist)) / (q * sin(dist))
        }
        let y1 = 0.0172 * (10 + (m0 - 1) * 30.4 + d6)
        let y2 = 0.409 * cos(y1)
        ft = min(halfPiC, 2.5 * dist / k6)
        ft = sin(ft)
        // ft = sin(θ), θ ∈ [0, π/2], so ft ≥ 0 here — no clamp (matches MINIMUF-3.5).
        let m9 = 1 + 2.5 * ft * sqrt(ft)
        var j9 = 100.0
        var step = abs(0.9999 - 1.0 / k6)
        if step <= 0 { step = 1 }
        var k1 = 1.0 / (2 * k6)
        let k1End = 1 - 1.0 / (2 * k6)

        while k1 <= k1End + 1e-12 {
            let gt = dist * k1
            ft = clamp1(p * cos(gt) + q * sin(gt) * a)
            let y3 = halfPiC - acos(ft)
            let denom = q * sqrt(max(1e-12, 1 - ft * ft))
            var ft2 = abs(denom) > 1e-12 ? (cos(gt) - ft * p) / denom : 0
            ft2 = clamp1(ft2)
            ft2 = w2 + sign(sin(w1 - w2)) * acos(ft2)
            if ft2 < 0 { ft2 += 2 * piC }
            if ft2 >= 2 * piC { ft2 -= 2 * piC }
            ft2 = 3.82 * ft2 + 12 + 0.13 * (sin(y1) + 1.2 * sin(2 * y1))
            let k8 = ft2 - 12 * (1 + sign(ft2 - 24)) * sign(abs(ft2 - 24))

            var k9 = 0.0
            var g0 = 0.0
            if cos(y3 + y2) > -0.26 {
                let f = (-0.26 + sin(y2) * sin(y3)) / (cos(y2) * cos(y3) + 0.001)
                k9 = 12 - atan(f / sqrt(abs(1 - f * f))) * 7.639437
                let t = k8 - k9 / 2 + 12 * (1 - sign(k8 - k9 / 2)) * sign(abs(k8 - k9 / 2))
                let t4 = k8 + k9 / 2 - 12 * (1 + sign(k8 + k9 / 2 - 24)) * sign(abs(k8 + k9 / 2 - 24))
                let c0 = abs(cos(y3 + y2))
                let t9 = max(0.1, 9.7 * pow(c0, 9.6))
                let g8 = k9 == 0 ? 0 : piC * t9 / k9
                if (t4 < t && (t5 - t4) * (t - t5) > 0) ||
                    (t4 >= t && (t5 - t) * (t4 - t5) <= 0) {
                    let f1 = t5 + 12 * (1 + sign(t4 - t5)) * sign(abs(t4 - t5))
                    let f2 = (t4 - f1) / 2
                    g0 = c0 * (g8 * (exp(-k9 / t9) + 1)) * exp(f2) / (1 + g8 * g8)
                } else {
                    let f1 = t5 + 12 * (1 + sign(t - t5)) * sign(abs(t - t5))
                    let gt2 = k9 == 0 ? 0 : piC * (f1 - t) / k9
                    let f2 = (t - f1) / t9
                    g0 = c0 * (sin(gt2) + g8 * (exp(f2) - cos(gt2))) / (1 + g8 * g8)
                    let floorValue = c0 * (g8 * (exp(-k9 / t9) + 1)) * exp((k9 - 24) / 2) / (1 + g8 * g8)
                    g0 = max(g0, floorValue)
                }
            }

            var value = (1 + s9 / 250.0) * m9 * sqrt(6 + 58 * sqrt(max(0, g0)))
            value *= 1 - 0.1 * exp((k9 - 24) / 3)
            value *= 1 + 0.1 * (1 - sign(l1) * sign(l2))
            value *= 1 - 0.1 * (1 + sign(abs(sin(y3)) - cos(y3)))
            j9 = min(j9, value)
            k1 += step
        }
        return min(32, max(2, j9))
    }

    static func workableBand(_ muf: Double) -> String {
        let usable = workableFraction * muf
        for (limit, name) in [(28.0,"10 m"),(24.0,"12 m"),(21.0,"15 m"),(18.0,"17 m"),
                              (14.0,"20 m"),(10.0,"30 m"),(7.0,"40 m")] {
            if usable >= limit { return name }
        }
        return "80 m"
    }

    private static func quality(_ muf: Double) -> String {
        if muf < 10 { return "low" }
        if muf < 17 { return "fair" }
        if muf < 24 { return "good" }
        return "high"
    }

    private static func greatCircle(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> (distanceKm: Double, bearingDegrees: Double) {
        let p1 = lat1 * d2r, p2 = lat2 * d2r, dl = (lon2 - lon1) * d2r
        let a = pow(sin((p2 - p1) / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        let distance = 2 * 6371.0 * asin(min(1, sqrt(a)))
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (distance, (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
    }

    private static func sign(_ x: Double) -> Double { x > 0 ? 1 : (x < 0 ? -1 : 0) }
    private static func clamp1(_ x: Double) -> Double { min(1, max(-1, x)) }
    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
}

enum PropagationEngine {
    static let bands: [(String, Double)] = [
        ("80 m", 3.6), ("40 m", 7.1), ("30 m", 10.1), ("20 m", 14.1),
        ("17 m", 18.1), ("15 m", 21.2), ("12 m", 24.9), ("10 m", 28.3), ("6 m", 50.1)
    ]

    static func outlook(weather: SpaceWeatherSnapshot?, date: Date = .now) -> PropagationOutlookSnapshot {
        let flux = weather?.flux, kp = weather?.kp
        let dayMUF = simpleMUF(flux: flux, kp: kp, day: true)
        let nightMUF = simpleMUF(flux: flux, kp: kp, day: false)
        let rows = bands.map { name, mhz in
            PropagationBandRecord(id: name, band: name,
                                  dayState: bandState(muf: dayMUF, bandMHz: mhz),
                                  nightState: bandState(muf: nightMUF, bandMHz: mhz))
        }
        let geomagnetic = geomagneticState(kp)
        let aurora = auroraVHF(kp)
        let absorption = absorptionState(kp)
        let meteor = meteorScatter(date)
        let es = sporadicE(date)
        var parts: [String] = []
        if let dayMUF, let nightMUF { parts.append(String(format: "MUF about %.0f MHz by day, %.0f at night", dayMUF, nightMUF)) }
        parts.append("field \(geomagnetic)")
        let open = rows.filter { $0.dayState == "open" }.map(\.band)
        parts.append(open.isEmpty ? "no band comfortably open by day" : "open by day: \(open.joined(separator: ", "))")
        let summary = weather == nil ? "No space-weather data yet — update Space Wx first." : parts.joined(separator: "; ") + "."
        return PropagationOutlookSnapshot(flux: flux, kp: kp, dayMUF: dayMUF, nightMUF: nightMUF,
                                          geomagnetic: geomagnetic, aurora: aurora,
                                          absorption: absorption, meteor: meteor, sporadicE: es,
                                          bands: rows, summary: summary)
    }

    private static func simpleMUF(flux: Double?, kp: Double?, day: Bool) -> Double? {
        guard let flux, flux > 0 else { return nil }
        let k = max(0, kp ?? 0)
        return max(3, 8 + (flux - 65) * 0.16 - k * 1.2 + (day ? 4 : -3))
    }

    private static func bandState(muf: Double?, bandMHz: Double) -> String {
        guard let muf else { return "unknown" }
        let head = muf - bandMHz
        if head >= 4 { return "open" }
        if head >= 0 { return "fair" }
        if head >= -3 { return "weak" }
        return "shut"
    }

    private static func geomagneticState(_ kp: Double?) -> String {
        guard let kp, kp >= 0 else { return "unknown" }
        if kp < 4 { return "quiet" }
        if kp < 5 { return "unsettled" }
        if kp < 6 { return "minor storm" }
        if kp < 7 { return "moderate storm" }
        return "major storm"
    }

    private static func auroraVHF(_ kp: Double?) -> String {
        guard let kp, kp >= 0 else { return "unknown" }
        if kp < 4 { return "unlikely" }
        if kp < 5 { return "possible at high latitudes" }
        if kp < 7 { return "likely at high latitudes" }
        return "likely into mid latitudes"
    }

    private static func absorptionState(_ kp: Double?) -> String {
        guard let kp, kp >= 0 else { return "unknown" }
        if kp < 4 { return "low — 80/40 normal" }
        if kp < 5 { return "moderate — low bands noisy" }
        if kp < 7 { return "high — 80/40 degraded" }
        return "severe — low bands absorbed"
    }

    private static func meteorScatter(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = cal.component(.month, from: date), day = cal.component(.day, from: date)
        let md = month * 100 + day
        let showers = [(101,105,"Quadrantids"),(419,425,"Lyrids"),(503,510,"Eta Aquariids"),
                       (725,820,"Perseids"),(1018,1024,"Orionids"),(1115,1120,"Leonids"),(1210,1216,"Geminids")]
        if let shower = showers.first(where: { md >= $0.0 && md <= $0.1 }) {
            return "\(shower.2) active — strong meteor scatter"
        }
        return "sporadic background (best near dawn)"
    }

    private static func sporadicE(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = cal.component(.month, from: date)
        if [5,6,7,8].contains(month) { return "Es season — 6 m and 10 m openings likely" }
        if [12,1].contains(month) { return "minor winter Es season" }
        return "outside the main Es season"
    }
}

/// Robust catalog↔operating-name matcher, ported from the desktop's amsatnames
/// ladder. Bridges AMSAT/hams.at operating names ("AO-91", "AO-7_[V/a]") to GP
/// catalog names ("AO-91 (RADFXSAT)", "AO-7 (OSCAR 7)", "RADFXSAT (FOX-1B)").
enum SatelliteNameMatch {
    /// Designators with no lexical bridge to the catalog name.
    static let aliases: [String: String] = [
        "CAS-3H": "LILACSAT-2",
        "IO-117": "GREENCUBE",
        "LO-19": "LUSAT"
    ]

    /// Upper-case; keep alphanumerics and hyphens; other runs → a single space.
    static func norm(_ text: String) -> String {
        var out = ""
        var space = true
        for ch in text.uppercased() {
            if ch.isLetter || ch.isNumber || ch == "-" {
                out.append(ch); space = false
            } else if !space {
                out.append(" "); space = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Drop spaces and hyphens too: AO-7 / AO 7 / AO7 all → AO7.
    static func collapse(_ text: String) -> String {
        String(String.UnicodeScalarView(norm(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Legacy stem: stop at the first space/bracket/underscore, strip leading
    /// zeros in the segment after the last hyphen. "AO-07_[V/a]" → "AO-7".
    static func baseCall(_ text: String) -> String {
        var stem = ""
        for ch in text {
            if ch == " " || ch == "[" || ch == "(" || ch == "_" { break }
            stem.append(contentsOf: ch.uppercased())
        }
        if let hyphen = stem.range(of: "-", options: .backwards) {
            let head = String(stem[stem.startIndex..<hyphen.lowerBound])
            var tail = String(stem[hyphen.upperBound...])
            tail = String(tail.drop { $0 == "0" })
            if tail.isEmpty { tail = "0" }
            return "\(head)-\(tail)"
        }
        return stem
    }

    /// Strip a trailing mode tag: "AO-7_[V/a]" or "AO-7[V/a]" → "AO-7".
    static func apiBase(_ apiName: String) -> String {
        let s = apiName.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "_?\\[[^\\]]*\\]$", options: .regularExpression) {
            return String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static func tokenIn(_ haystackNorm: String, _ needleNorm: String) -> Bool {
        guard !needleNorm.isEmpty else { return false }
        let pattern = "(^|\\s)\(NSRegularExpression.escapedPattern(for: needleNorm))($|\\s)"
        return haystackNorm.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parenTokens(_ name: String) -> [String] {
        var tokens: [String] = []
        var depth = 0, current = ""
        for ch in name {
            if ch == "(" { depth += 1; current = "" }
            else if ch == ")" { if depth > 0 { tokens.append(current); depth -= 1 } }
            else if depth > 0 { current.append(ch) }
        }
        return tokens
    }

    /// Index of the catalog name this operating/API name belongs to, or nil.
    static func matchIndex(apiName: String, in names: [String]) -> Int? {
        let base = apiBase(apiName)
        guard !base.isEmpty else { return nil }
        let bn = norm(base), ab = baseCall(base), bc = collapse(base)
        let normed = names.map { norm($0) }
        // 1. parenthesised designator equality ("AO-91" ↔ "… (AO-91)")
        for (i, name) in names.enumerated() {
            for tok in parenTokens(name) where !norm(tok).isEmpty && norm(tok) == bn { return i }
        }
        // 2. whole-name equality
        for (i, nm) in normed.enumerated() where nm == bn { return i }
        // 3. delimited-token containment
        for (i, nm) in normed.enumerated() where tokenIn(nm, bn) { return i }
        // 4. legacy prefix base (AO-07 ↔ AO-7)
        if !ab.isEmpty { for (i, name) in names.enumerated() where baseCall(name) == ab { return i } }
        // 5. collapsed form (AO-7 ↔ AO7), more tolerant than the token tiers
        if !bc.isEmpty { for (i, name) in names.enumerated() where collapse(name) == bc { return i } }
        // 6. known aliases with no lexical bridge
        if let target = aliases[base.uppercased()] {
            let tn = norm(target)
            for (i, nm) in normed.enumerated() where nm == tn || tokenIn(nm, tn) { return i }
        }
        return nil
    }
}

enum ActivationServiceError: LocalizedError {
    case invalidFeed
    case server(Int)
    case celestrakRateLimit

    var errorDescription: String? {
        switch self {
        case .invalidFeed: "hams.at returned a response that was not an activation feed."
        case .server(let code): "The activation service returned HTTP \(code)."
        case .celestrakRateLimit: "CelesTrak appears to be rate-limiting searches. Try again later."
        }
    }
}

// MARK: - hams.at activation alert posting (POST /api/alerts)

/// A request to publish an activation alert to hams.at. Field names/semantics
/// mirror the documented `POST /api/alerts` body.
struct HamsatAlertRequest: Sendable, Equatable {
    var satelliteNumber: Int          // NORAD catalog number (required)
    var observerLatitude: Double      // required, -90…90
    var observerLongitude: Double     // required, -180…180
    var maxAt: Date                   // required, approx. time of pass maximum
    var callsign: String              // required, ≥ 3 chars
    var grids: [String]               // required, 1–4 Maidenhead squares (4 or 6 char)
    var mode: String? = nil           // optional: SSB | CW | Data | FM
    var comment: String? = nil        // optional, ≤ 50 chars
    var mhz: Double? = nil            // optional frequency in MHz
    var mhzDirection: String? = nil   // optional: up | down (defaults to down)
    var chatEnabled: Bool? = nil      // optional, defaults to true server-side

    static let allowedModes = ["SSB", "CW", "Data", "FM"]
    static let allowedDirections = ["up", "down"]
}

/// The alert hams.at returns after a successful create.
struct HamsatPostedAlert: Sendable, Equatable {
    let id: String
    let url: String
    let callsign: String
    let satelliteName: String
}

enum HamsatAlertError: LocalizedError, Equatable {
    case missingAPIKey
    case field(String)             // local pre-flight validation failure
    case unauthorized([String])    // HTTP 401
    case validation([String])      // HTTP 422
    case server(Int, String)       // other non-2xx
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Enter your hams.at API key (from the hams.at Settings page) before posting."
        case .field(let message):
            return message
        case .unauthorized(let messages):
            let joined = messages.joined(separator: " ")
            return joined.isEmpty ? "hams.at rejected the API key (401 Unauthorized)." : "hams.at rejected the API key: \(joined)"
        case .validation(let messages):
            let joined = messages.joined(separator: " ")
            return joined.isEmpty ? "hams.at rejected the activation (422)." : "hams.at rejected the activation: \(joined)"
        case .server(let code, let body):
            return "hams.at returned HTTP \(code). \(body.prefix(160))"
        case .invalidResponse:
            return "hams.at returned a response OrbitDeck could not read."
        }
    }
}

/// A seam over the network so the posting client can be exercised by a local
/// test harness (hams.at has no sandbox/test endpoint).
protocol HamsatTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport: a plain URLSession round-trip.
struct URLSessionHamsatTransport: HamsatTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HamsatAlertError.invalidResponse }
        return (data, http)
    }
}

enum HamsatAlertService {
    static let baseURL = URL(string: "https://hams.at")!

    /// Normalize grids: trim, upper-case, drop empties.
    static func normalizedGrids(_ grids: [String]) -> [String] {
        grids.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    /// Local pre-flight validation mirroring the server's required-field rules, so
    /// obvious problems surface without a round-trip.
    static func validate(_ alert: HamsatAlertRequest) throws {
        guard alert.satelliteNumber > 0 else { throw HamsatAlertError.field("Choose a satellite.") }
        let call = alert.callsign.trimmingCharacters(in: .whitespaces)
        guard call.count >= 3 else { throw HamsatAlertError.field("Enter a callsign of at least three characters.") }
        let grids = normalizedGrids(alert.grids)
        guard (1...4).contains(grids.count) else { throw HamsatAlertError.field("Enter 1 to 4 Maidenhead grid squares.") }
        for grid in grids where grid.count != 4 && grid.count != 6 {
            throw HamsatAlertError.field("Grid \(grid) must be 4 or 6 characters.")
        }
        guard (-90.0...90.0).contains(alert.observerLatitude) else { throw HamsatAlertError.field("Observer latitude is out of range.") }
        guard (-180.0...180.0).contains(alert.observerLongitude) else { throw HamsatAlertError.field("Observer longitude is out of range.") }
        if let comment = alert.comment, comment.count > 50 { throw HamsatAlertError.field("Comment must be 50 characters or fewer.") }
        if let mode = alert.mode, !HamsatAlertRequest.allowedModes.contains(mode) { throw HamsatAlertError.field("Mode must be SSB, CW, Data or FM.") }
        if let dir = alert.mhzDirection, !HamsatAlertRequest.allowedDirections.contains(dir) { throw HamsatAlertError.field("Direction must be up or down.") }
    }

    /// Build the signed, JSON-bodied request. Pure and synchronous so it can be
    /// asserted in tests without any network.
    static func makeRequest(_ alert: HamsatAlertRequest, apiKey: String, baseURL: URL = baseURL) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw HamsatAlertError.missingAPIKey }

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        var body: [String: Any] = [
            "satellite_number": alert.satelliteNumber,
            "observer_lat": alert.observerLatitude,
            "observer_lon": alert.observerLongitude,
            "max_at": iso.string(from: alert.maxAt),
            "callsign": alert.callsign.trimmingCharacters(in: .whitespaces).uppercased(),
            "grids": normalizedGrids(alert.grids)
        ]
        if let mode = alert.mode { body["mode"] = mode }
        if let comment = alert.comment, !comment.isEmpty { body["comment"] = comment }
        if let mhz = alert.mhz { body["mhz"] = mhz }
        if let dir = alert.mhzDirection { body["mhz_direction"] = dir }
        if let chat = alert.chatEnabled { body["chat_enabled"] = chat }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/alerts"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ActivationService.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Turn a server response into a posted alert, or a typed error. Pure so the
    /// 201 / 401 / 422 branches can each be unit-tested.
    static func parseResponse(data: Data, response: HTTPURLResponse) throws -> HamsatPostedAlert {
        func messages() -> [String] {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let errors = object["errors"] as? [String] else { return [] }
            return errors
        }
        switch response.statusCode {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let alert = object["data"] as? [String: Any] else { throw HamsatAlertError.invalidResponse }
            let id = alert["id"] as? String ?? ""
            let url = alert["url"] as? String ?? ""
            let callsign = alert["callsign"] as? String ?? ""
            let satelliteName = (alert["satellite"] as? [String: Any])?["name"] as? String ?? ""
            return HamsatPostedAlert(id: id, url: url, callsign: callsign, satelliteName: satelliteName)
        case 401:
            throw HamsatAlertError.unauthorized(messages())
        case 422:
            throw HamsatAlertError.validation(messages())
        default:
            let snippet = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HamsatAlertError.server(response.statusCode, snippet)
        }
    }

    /// Post an activation alert. The transport defaults to URLSession in the app
    /// and is swapped for a mock hams.at server in tests.
    @discardableResult
    static func postAlert(_ alert: HamsatAlertRequest, apiKey: String,
                          transport: HamsatTransport = URLSessionHamsatTransport(),
                          baseURL: URL = baseURL) async throws -> HamsatPostedAlert {
        try validate(alert)
        let request = try makeRequest(alert, apiKey: apiKey, baseURL: baseURL)
        let (data, http) = try await transport.send(request)
        return try parseResponse(data: data, response: http)
    }
}

struct ActivationService {
    static let feedURL = URL(string: "https://hams.at/feeds/upcoming_alerts")!
    // Some feeds/CDNs reject non-browser user agents; present a Safari-like one.
    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    static func fetch(attempts: Int = 3) async throws -> [ActivationRecord] {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<max(1, attempts) {
            do {
                var request = URLRequest(url: feedURL); request.timeoutInterval = 25
                request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ActivationServiceError.server(http.statusCode)
                }
                let text = String(decoding: data, as: UTF8.self)
                let rows = parse(text)
                if rows.isEmpty {
                    // Surface what actually came back so a blocked/changed feed is diagnosable.
                    let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)
                    throw NSError(domain: "Activation", code: 20, userInfo: [NSLocalizedDescriptionKey:
                        "hams.at returned no parseable activations. First bytes: \(snippet)"])
                }
                return rows
            } catch {
                lastError = error
                if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        throw lastError
    }

    static func parse(_ body: String, maxCount: Int = 60) -> [ActivationRecord] {
        let entryPattern = "<entry[^>]*>(.*?)</entry>"
        let regex = try? NSRegularExpression(pattern: entryPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = body as NSString
        let matches = regex?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? []
        var output: [ActivationRecord] = []
        for (idx, match) in matches.prefix(maxCount).enumerated() where match.numberOfRanges > 1 {
            let block = ns.substring(with: match.range(at: 1))
            let title = tag(block, "title")
            var content = tag(block, "content")
            content = htmlUnescape(content.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: ""))
            var date = "", call = "", satellite = "", grid = ""
            if let parsed = capture(title, pattern: "^\\s*\\[([^\\]]*)\\]\\s*(.*)$"), parsed.count >= 2 {
                date = parsed[0]
                if let titleParts = capture(parsed[1], pattern: "^\\s*(\\S+)\\s+on\\s+(.+?)\\s+from\\s+(\\S+)") , titleParts.count >= 3 {
                    call = titleParts[0]; satellite = titleParts[1]; grid = titleParts[2]
                } else { call = parsed[1] }
            } else if let titleParts = capture(title, pattern: "^\\s*(\\S+)\\s+on\\s+(.+?)\\s+from\\s+(\\S+)") , titleParts.count >= 3 {
                call = titleParts[0]; satellite = titleParts[1]; grid = titleParts[2]
            }
            let start = liValue(content, label: "Start time")
            let id = "\(date)|\(call)|\(satellite)|\(start)|\(idx)"
            output.append(ActivationRecord(id: id, title: title, date: date, callsign: call,
                                           satellite: satellite, grid: grid, start: start,
                                           end: liValue(content, label: "End time"),
                                           maximumElevation: liValue(content, label: "Max elevation"),
                                           frequency: liValue(content, label: "Frequency"),
                                           mode: liValue(content, label: "Mode"),
                                           comment: liValue(content, label: "Comment")))
        }
        return output
    }

    static func detail(_ activation: ActivationRecord, satellites: [SatelliteRecord],
                       home: ObserverSite, minimumElevation: Double = 0) throws -> ActivationDetailResult {
        let firstGrid = activation.grid.split(whereSeparator: { "/,; ".contains($0) }).first.map(String.init) ?? ""
        guard let dxLocation = FeatureEngine.gridToLatLon(firstGrid) else {
            throw NSError(domain: "Activation", code: 10, userInfo: [NSLocalizedDescriptionKey: "Activator grid is not usable."])
        }
        guard let satellite = matchSatellite(activation.satellite, in: satellites) else {
            throw NSError(domain: "Activation", code: 11, userInfo: [NSLocalizedDescriptionKey: "Satellite is not in the loaded catalog."])
        }
        guard let listed = listedDate(activation) else {
            throw NSError(domain: "Activation", code: 12, userInfo: [NSLocalizedDescriptionKey: "The feed date/start time could not be parsed."])
        }
        let dx = ObserverSite(name: activation.callsign.isEmpty ? firstGrid : activation.callsign,
                              latitude: dxLocation.latitude, longitude: dxLocation.longitude, altitudeMeters: 0)
        let searchStart = listed.addingTimeInterval(-3600)
        let windows = try FeatureEngine.mutualWindows(satellite, home: home, dx: dx, from: searchStart,
                                                      days: 2.0 / 24.0, minimumElevation: minimumElevation,
                                                      step: 30, maxCount: 12)
            .filter { $0.start <= listed.addingTimeInterval(3600) && $0.end >= searchStart }
        return ActivationDetailResult(activation: activation, satellite: satellite, dxSite: dx,
                                      listedDate: listed, windows: windows)
    }

    static func check(_ activation: ActivationRecord, satellites: [SatelliteRecord],
                      home: ObserverSite, minimumElevation: Double = 0) throws -> ActivationCheckResult {
        let firstGrid = activation.grid.split(whereSeparator: { "/,; ".contains($0) }).first.map(String.init) ?? ""
        guard let dxLocation = FeatureEngine.gridToLatLon(firstGrid) else {
            return ActivationCheckResult(workable: false, message: "Activator grid is not usable.", satellite: nil,
                                         listedDate: nil, mutualWindow: nil, myMaximumElevation: nil)
        }
        guard let satellite = matchSatellite(activation.satellite, in: satellites) else {
            return ActivationCheckResult(workable: false, message: "Satellite is not in the loaded catalog.", satellite: nil,
                                         listedDate: nil, mutualWindow: nil, myMaximumElevation: nil)
        }
        guard let listed = listedDate(activation) else {
            return ActivationCheckResult(workable: false, message: "The feed date/start time could not be parsed.", satellite: satellite,
                                         listedDate: nil, mutualWindow: nil, myMaximumElevation: nil)
        }
        let dx = ObserverSite(name: activation.callsign, latitude: dxLocation.latitude,
                              longitude: dxLocation.longitude, altitudeMeters: 0)
        let searchStart = listed.addingTimeInterval(-3600)
        let windows = try FeatureEngine.mutualWindows(satellite, home: home, dx: dx, from: searchStart,
                                                      days: 2.0 / 24.0, minimumElevation: minimumElevation,
                                                      step: 30, maxCount: 12)
        let searchEnd = listed.addingTimeInterval(3600)
        let near = windows.filter { $0.start <= searchEnd && $0.end >= searchStart }
        let best = near.min { abs($0.start.timeIntervalSince(listed)) < abs($1.start.timeIntervalSince(listed)) }
        let passes = try OrbitPredictor.predictPasses(satellite, observer: home, from: searchStart,
                                                      minElevation: 0, maxCount: 6, horizonDays: 2.0 / 24.0)
        let homePass = passes.min { abs($0.aos.timeIntervalSince(listed)) < abs($1.aos.timeIntervalSince(listed)) }
        if let best {
            return ActivationCheckResult(workable: true,
                                         message: "Mutual visibility found near the advertised activation time.",
                                         satellite: satellite, listedDate: listed, mutualWindow: best,
                                         myMaximumElevation: homePass?.maxElevation)
        }
        return ActivationCheckResult(workable: false,
                                     message: "No mutual visibility window within ±60 minutes of the advertised start.",
                                     satellite: satellite, listedDate: listed, mutualWindow: nil,
                                     myMaximumElevation: homePass?.maxElevation)
    }

    static func matchSatellite(_ query: String, in satellites: [SatelliteRecord]) -> SatelliteRecord? {
        guard let index = SatelliteNameMatch.matchIndex(apiName: query, in: satellites.map { $0.name }) else { return nil }
        return satellites[index]
    }

    static func searchCelesTrak(_ query: String) async throws -> [SatelliteRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var comps = URLComponents(string: "https://celestrak.org/NORAD/elements/gp.php")!
        comps.queryItems = [URLQueryItem(name: trimmed.allSatisfy(\.isNumber) ? "CATNR" : "NAME", value: trimmed),
                            URLQueryItem(name: "FORMAT", value: "JSON")]
        var request = URLRequest(url: comps.url!); request.timeoutInterval = 20
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return [] }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ActivationServiceError.server(http.statusCode)
        }
        let text = String(decoding: data, as: UTF8.self)
        let low = text.lowercased()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") &&
            (low.contains("rate") || low.contains("throttl") || low.contains("too many")) {
            throw ActivationServiceError.celestrakRateLimit
        }
        return (try? GPService.parse(data: data)) ?? []
    }

    private static func listedDate(_ a: ActivationRecord) -> Date? {
        // Extract the date and clock by regex so suffixes like "(UTC)" on the
        // feed's "Start time" value don't defeat parsing (the old string-strip
        // left "22:44:00 ()", which no DateFormatter could read).
        guard let d = capture(a.date, pattern: "(\\d{4})-(\\d{1,2})-(\\d{1,2})"), d.count >= 3,
              let year = Int(d[0]), let month = Int(d[1]), let day = Int(d[2]) else { return nil }
        // Time may live in a.start ("22:44:00 (UTC)") or, as a fallback, in a.date.
        let timeSource = capture(a.start, pattern: "(\\d{1,2}):(\\d{2})(?::(\\d{2}))?")
            ?? capture(a.date, pattern: "(\\d{1,2}):(\\d{2})(?::(\\d{2}))?")
        guard let t = timeSource, t.count >= 2, let hour = Int(t[0]), let minute = Int(t[1]) else { return nil }
        let second = (t.count >= 3 ? Int(t[2]) : nil) ?? 0
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: comps)
    }

    private static func normalizedName(_ s: String) -> String {
        s.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func tag(_ block: String, _ name: String) -> String {
        capture(block, pattern: "<\(NSRegularExpression.escapedPattern(for: name))[^>]*>(.*?)</\(NSRegularExpression.escapedPattern(for: name))>")?.first ?? ""
    }

    private static func liValue(_ content: String, label: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        guard let value = capture(content, pattern: "<li>\\s*\(escaped)\\s*:\\s*(.*?)</li>")?.first else { return "" }
        return value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capture(_ text: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).map { idx in
            let r = match.range(at: idx); return r.location == NSNotFound ? "" : ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func htmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

actor QRZService {
    private var sessionKey = ""
    private static let base = "https://xmldata.qrz.com/xml/current/"

    func lookup(username: String, password: String, callsign: String) async throws -> QRZRecord {
        var key = sessionKey
        if key.isEmpty {
            key = try await login(username: username, password: password)
            sessionKey = key
        }
        var body = try await get(Self.base + "?s=\(encode(key));callsign=\(encode(callsign))")
        if let record = parseCallsign(body) { return record }
        let error = xmlTag(body, "Error")
        if error.localizedCaseInsensitiveContains("session") || error.localizedCaseInsensitiveContains("timeout") || error.localizedCaseInsensitiveContains("invalid") {
            key = try await login(username: username, password: password)
            sessionKey = key
            body = try await get(Self.base + "?s=\(encode(key));callsign=\(encode(callsign))")
            if let record = parseCallsign(body) { return record }
        }
        throw NSError(domain: "QRZ", code: 2, userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "QRZ callsign not found." : error])
    }

    private func login(username: String, password: String) async throws -> String {
        guard !username.isEmpty, !password.isEmpty else {
            throw NSError(domain: "QRZ", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set QRZ XML credentials in Settings first."])
        }
        let body = try await get(Self.base + "?username=\(encode(username));password=\(encode(password));agent=OrbitDeck-iOS")
        let key = xmlTag(body, "Key")
        if key.isEmpty {
            let error = xmlTag(body, "Error")
            throw NSError(domain: "QRZ", code: 1, userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "QRZ login failed." : error])
        }
        return key
    }

    private func get(_ raw: String) async throws -> String {
        guard let url = URL(string: raw) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }

    private func parseCallsign(_ body: String) -> QRZRecord? {
        guard body.range(of: "<Callsign>", options: .caseInsensitive) != nil else { return nil }
        let first = xmlTag(body, "fname"), last = xmlTag(body, "name")
        let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let state = xmlTag(body, "state"), zip = xmlTag(body, "zip")
        var locality = xmlTag(body, "addr2")
        if !state.isEmpty { locality += locality.isEmpty ? state : ", \(state)" }
        if !zip.isEmpty { locality += " \(zip)" }
        let street = xmlTag(body, "addr1")
        let address = [street, locality].filter { !$0.isEmpty }.joined(separator: "\n")
        return QRZRecord(call: xmlTag(body, "call").uppercased(), name: name,
                         address: address, country: xmlTag(body, "country"),
                         grid: xmlTag(body, "grid"), licenseClass: xmlTag(body, "class"))
    }

    private func xmlTag(_ body: String, _ tag: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let re = try? NSRegularExpression(pattern: "<\(escaped)>(.*?)</\(escaped)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        let ns = body as NSString
        guard let match = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return "" }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: ";&=+?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Session cache of the AMSAT catalog.php name list, so a match that succeeds
/// once (after cold-start retries) never has to hit the network again.
private actor AmsatCatalogCache {
    static let shared = AmsatCatalogCache()
    private var names: [String]?
    func get() -> [String]? { names }
    func set(_ value: [String]) { names = value }
}

extension AmsatStatusService {
    static let reportStatuses = ["Heard", "Telemetry Only", "Not Heard", "Crew Active"]

    static func catalogNames() async throws -> [String] {
        if let cached = await AmsatCatalogCache.shared.get(), !cached.isEmpty { return cached }
        let url = URL(string: "https://www.amsat.org/status/api/v1/catalog.php")!
        let data = try await requestData(url)
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let dict = object as? [String: Any] { rows = (dict["data"] as? [[String: Any]]) ?? (dict["catalog"] as? [[String: Any]]) ?? [] }
        else { rows = object as? [[String: Any]] ?? [] }
        let all = rows.compactMap { $0["name"] as? String }
        if !all.isEmpty { await AmsatCatalogCache.shared.set(all) }
        return all
    }

    static func catalogMatches(commonName: String) async throws -> [String] {
        let all = try await catalogNames()
        // Keep every API/operating name that resolves to this catalog entry
        // through the full matching ladder (AO-7 has one per transponder mode).
        // De-duplicate: the AMSAT catalog can list a name more than once, which
        // otherwise yields duplicate SwiftUI Picker IDs ("invalid selection").
        var seen = Set<String>()
        let matches = all.filter {
            SatelliteNameMatch.matchIndex(apiName: $0, in: [commonName]) != nil && seen.insert($0).inserted
        }
        return matches.sorted()
    }

    static func fetchReports(apiName: String, hours: Int = 24, limit: Int = 200) async throws -> [AmsatReportRecord] {
        var comps = URLComponents(string: "https://www.amsat.org/status/api/v1/reports.php")!
        comps.queryItems = [URLQueryItem(name: "name", value: apiName), URLQueryItem(name: "hours", value: String(hours)), URLQueryItem(name: "limit", value: String(limit))]
        let data = try await requestData(comps.url!)
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let dict = object as? [String: Any], let err = dict["error"] as? [String: Any] {
            throw NSError(domain: "AMSAT", code: 2, userInfo: [NSLocalizedDescriptionKey: String(describing: err["message"] ?? "AMSAT API error")])
        } else if let dict = object as? [String: Any] {
            rows = (dict["data"] as? [[String: Any]]) ?? (dict["reports"] as? [[String: Any]]) ?? []
        } else { rows = object as? [[String: Any]] ?? [] }
        return rows.compactMap { row in
            let status = (row["report"] as? String) ?? (row["status"] as? String) ?? ""
            guard !status.isEmpty else { return nil }
            let call = ((row["callsign"] as? String) ?? (row["call"] as? String) ?? "").uppercased()
            let grid = ((row["grid_square"] as? String) ?? (row["grid"] as? String) ?? "").uppercased()
            let stamp = (row["reported_time"] as? String) ?? (row["reported_at"] as? String) ?? (row["time"] as? String) ?? ""
            return AmsatReportRecord(id: "\(call)|\(stamp)|\(status)", callsign: call, grid: grid,
                                     status: status, date: parseAmsatDate(stamp), rawTime: stamp)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func submitReport(apiName: String, status: String, callsign: String, grid: String, date: Date = .now) async throws -> String {
        guard reportStatuses.contains(status) else { throw NSError(domain: "AMSAT", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown AMSAT report status."]) }
        let call = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !call.isEmpty else { throw NSError(domain: "AMSAT", code: 3, userInfo: [NSLocalizedDescriptionKey: "Set your callsign in Settings before reporting."]) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        var body: [String: Any] = ["name": apiName, "report": status, "callsign": call, "reported_at": iso.string(from: date)]
        if !grid.isEmpty { body["grid_square"] = grid.uppercased() }
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "https://www.amsat.org/status/api/v1/reports.php")!
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ActivationService.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(decoding: responseData, as: UTF8.self)
            throw NSError(domain: "AMSAT", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "AMSAT rejected the report (HTTP \(http.statusCode)): \(text.prefix(120))"])
        }
        let text = String(decoding: responseData, as: UTF8.self)
        if text.lowercased().contains("error") || text.lowercased().contains("invalid") || text.lowercased().contains("fail") {
            throw NSError(domain: "AMSAT", code: 4, userInfo: [NSLocalizedDescriptionKey: "AMSAT rejected the report: \(text.prefix(120))"])
        }
        return "\(status) reported for \(apiName)."
    }

    private static func requestData(_ url: URL, attempts: Int = 3) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<max(1, attempts) {
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 25
                request.setValue(ActivationService.browserUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let snippet = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)
                    throw NSError(domain: "AMSAT", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey:
                        "amsat.org returned HTTP \(http.statusCode). \(snippet)"])
                }
                return data
            } catch {
                lastError = error
                if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        throw lastError
    }

    private static func normalizedAmsatName(_ value: String) -> String {
        value.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func parseAmsatDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: value) { return d }
        let clean = value.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0); df.dateFormat = fmt
            if let d = df.date(from: clean.components(separatedBy: ".").first ?? clean) { return d }
        }
        return nil
    }
}
