import Foundation
import SatelliteKit

struct ObserverSite: Codable, Equatable, Sendable {
    var name: String = "Home"
    var latitude: Double = 39.93
    var longitude: Double = -74.89
    var altitudeMeters: Double = 20

    var satelliteKitLocation: LatLonAlt {
        LatLonAlt(latitude, longitude, altitudeMeters / 1000.0)
    }

    /// Location rounded to ~100 m, used in `.task(id:)` recompute keys so that
    /// sub-meter GPS jitter (while following the device) doesn't constantly
    /// restart heavy recomputes and make live screens flash.
    var coarseKey: String { String(format: "%.3f,%.3f", latitude, longitude) }

    /// Location rounded to ~1 km, for the heaviest recomputes (pass lists, daily
    /// schedule). While following the device at coarse GPS precision the fix can
    /// jitter by hundreds of metres each second — enough to flip `coarseKey` and
    /// keep cancelling multi-second loads before they finish. Passes don't change
    /// meaningfully over ~1 km, so this key stays stable while stationary.
    var stableKey: String { String(format: "%.2f,%.2f", latitude, longitude) }
}

struct TransponderRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var description: String
    var downlinkLow: Int64
    var downlinkHigh: Int64
    var uplinkLow: Int64
    var uplinkHigh: Int64
    var mode: String
    var invert: Bool
    var type: String
    var baud: Double
    var service: String

    // A true linear transponder has an uplink passband and a downlink passband.
    // Requiring an uplink (and a Transponder type or ≥5 kHz width) stops wide
    // beacon/data transmitters from being mislabeled "Linear", which corrupted
    // passband and Doppler math. Matches CardSat's classification.
    var isLinear: Bool {
        guard downlinkLow > 0, downlinkHigh > downlinkLow, uplinkLow > 0 else { return false }
        return type.localizedCaseInsensitiveContains("transponder") || (downlinkHigh - downlinkLow) >= 5000
    }
    var bandwidth: Int64 { isLinear ? downlinkHigh - downlinkLow : 0 }

    // A two-way transponder has both an uplink and a downlink passband (a linear
    // transponder or an FM repeater) — the kind you actually work through.
    // Beacons and telemetry are downlink-only, so they are one-way. Two-way
    // transponders are listed first.
    var isTwoWay: Bool { uplinkLow > 0 && downlinkLow > 0 }

    var downlinkCenter: Int64 {
        downlinkHigh > downlinkLow ? (downlinkLow + downlinkHigh) / 2 : downlinkLow
    }

    var uplinkCenter: Int64 {
        uplinkHigh > uplinkLow ? (uplinkLow + uplinkHigh) / 2 : uplinkLow
    }

    var kind: String {
        if isLinear { return invert ? "Linear (inverting)" : "Linear" }
        let haystack = "\(mode) \(description)".uppercased()
        if haystack.contains("FM") { return "FM" }
        if haystack.contains("CW") || haystack.contains("BEACON") { return "CW / Beacon" }
        for tag in ["BPSK", "GMSK", "FSK", "AFSK", "GFSK", "QPSK", "MSK", "LORA", "APRS", "AX.25"] {
            if haystack.contains(tag) { return "Data (\(tag))" }
        }
        return type.isEmpty ? (mode.isEmpty ? "Transmitter" : mode) : type
    }
}

struct SatelliteRecord: Identifiable, Sendable {
    let id: UInt
    let name: String
    let internationalDesignator: String
    let epoch: Date
    let meanMotionRevPerDay: Double
    let eccentricity: Double
    let inclinationDeg: Double
    let raanDeg: Double
    let argumentOfPerigeeDeg: Double
    let meanAnomalyDeg: Double
    let bstar: Double
    let elements: Elements
    var transponders: [TransponderRecord] = []
    var isManual: Bool = false

    static func == (lhs: SatelliteRecord, rhs: SatelliteRecord) -> Bool {
        lhs.id == rhs.id && lhs.epoch == rhs.epoch
    }

    var periodMinutes: Double {
        meanMotionRevPerDay > 0 ? 1440.0 / meanMotionRevPerDay : 0
    }

    var semiMajorAxisKm: Double {
        let mu = 398600.8
        let n = meanMotionRevPerDay * 2.0 * .pi / 86400.0
        guard n > 0 else { return 0 }
        return pow(mu / (n * n), 1.0 / 3.0)
    }

    var apogeeKm: Double {
        semiMajorAxisKm * (1.0 + eccentricity) - 6378.135
    }

    var perigeeKm: Double {
        semiMajorAxisKm * (1.0 - eccentricity) - 6378.135
    }

    var elementAgeDays: Double {
        Date().timeIntervalSince(epoch) / 86400.0
    }
}

struct LiveLook: Sendable {
    var date: Date
    var azimuth: Double
    var elevation: Double
    var rangeKm: Double
    var rangeRateKmS: Double
    var subLatitude: Double
    var subLongitude: Double
    var altitudeKm: Double
    var sunlit: Bool
    var betaAngleDeg: Double
    var footprintRadiusKm: Double

    var visible: Bool { elevation > 0 }
}

struct PredictedPass: Identifiable, Sendable {
    let id: Date
    let aos: Date
    let los: Date
    let tca: Date
    let maxElevation: Double
    let aosAzimuth: Double
    let losAzimuth: Double

    var duration: TimeInterval { max(0, los.timeIntervalSince(aos)) }
}

struct SkyPoint: Identifiable, Sendable {
    let id: Date
    let date: Date
    let azimuth: Double
    let elevation: Double
}

enum GPSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case amsat
    case celestrak
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amsat: "AMSAT Daily Bulletin"
        case .celestrak: "CelesTrak Group"
        case .custom: "Custom OMM JSON URL"
        }
    }
}

/// A per-radio frequency-error correction for one satellite. These are the
/// operator's own transceiver offsets (in Hz), applied only to the operator's own
/// tuned dials — never the DX station's — as a final correction on top of the
/// Doppler/passband solution.
struct RadioCalibration: Codable, Sendable, Equatable {
    var downlinkHz: Double = 0
    var uplinkHz: Double = 0

    var isZero: Bool { downlinkHz == 0 && uplinkHz == 0 }
}

struct StorePreferences: Codable, Sendable {
    var observer = ObserverSite()
    var minElevation = 5.0
    var selectedNorad: UInt?
    var favorites: Set<UInt> = []
    var sourceKind: GPSourceKind = .amsat
    var celestrakGroup = "amateur"
    var customURL = ""

    // Added after the original preference schema. Optional storage preserves
    // decoding of 0.1-0.3 preference blobs without a migration failure.
    var callsign: String?
    var qrzUsername: String?
    var savedSites: [ObserverSite]?
    var manualSatellites: [ManualSatelliteDefinition]?
    // Extra catalog objects added from New Launches. Stored as a last-known
    // element snapshot so they survive offline launches, then refreshed by
    // NORAD from CelesTrak on the normal GP-update path.
    var extraSatellites: [ManualSatelliteDefinition]?
    var manualTransponders: [String: [TransponderRecord]]?
    // Per-satellite radio calibration (operator's own transceiver offsets),
    // keyed by NORAD id string. Optional preserves decoding of older blobs.
    var satelliteCalibrations: [String: RadioCalibration]?
    var passAlarmLeadMinutes: Int?
    var labOrbit: LabOrbitDefinition?
    // Whether observer-relative screens use the fixed primary site or continuously
    // follow the device's current location. Optional preserves decoding of older
    // preference blobs; nil is treated as .fixed.
    var locationMode: LocationMode?
    // While following the device, `observer` holds the live "Current location"
    // site; the operator's real fixed primary site is preserved here so switching
    // back to Fixed restores it intact.
    var savedFixedSite: ObserverSite?
    // Display all times in the device's local zone instead of UTC. Optional
    // preserves decoding of older preference blobs; nil is treated as UTC.
    var useLocalTime: Bool?
}

/// How OrbitDeck resolves the observer station.
enum LocationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case fixed            // use the entered primary site
    case currentLocation  // always follow the device's current location
    var id: String { rawValue }
}


struct LabOrbitDefinition: Codable, Equatable, Sendable {
    var altitudeKm: Double = 420
    var eccentricity: Double = 0
    var inclinationDeg: Double = 51.6
    var raanDeg: Double = 0
    var argumentOfPerigeeDeg: Double = 0
    var meanAnomalyDeg: Double = 0
}


struct ManualSatelliteDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: UInt { norad }
    var name: String
    var norad: UInt
    var internationalDesignator: String = ""
    var epoch: Date
    var inclinationDeg: Double
    var raanDeg: Double
    var eccentricity: Double
    var argumentOfPerigeeDeg: Double
    var meanAnomalyDeg: Double
    var meanMotionRevPerDay: Double
    var bstar: Double = 0

    init(record: SatelliteRecord) {
        self.name = record.name
        self.norad = record.id
        self.internationalDesignator = record.internationalDesignator
        self.epoch = record.epoch
        self.inclinationDeg = record.inclinationDeg
        self.raanDeg = record.raanDeg
        self.eccentricity = record.eccentricity
        self.argumentOfPerigeeDeg = record.argumentOfPerigeeDeg
        self.meanAnomalyDeg = record.meanAnomalyDeg
        self.meanMotionRevPerDay = record.meanMotionRevPerDay
        self.bstar = record.bstar
    }

    init(name: String, norad: UInt, internationalDesignator: String = "", epoch: Date,
         inclinationDeg: Double, raanDeg: Double, eccentricity: Double,
         argumentOfPerigeeDeg: Double, meanAnomalyDeg: Double,
         meanMotionRevPerDay: Double, bstar: Double = 0) {
        self.name = name
        self.norad = norad
        self.internationalDesignator = internationalDesignator
        self.epoch = epoch
        self.inclinationDeg = inclinationDeg
        self.raanDeg = raanDeg
        self.eccentricity = eccentricity
        self.argumentOfPerigeeDeg = argumentOfPerigeeDeg
        self.meanAnomalyDeg = meanAnomalyDeg
        self.meanMotionRevPerDay = meanMotionRevPerDay
        self.bstar = bstar
    }
}
