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
    /// jitter by hundreds of meters each second — enough to flip `coarseKey` and
    /// keep canceling multi-second loads before they finish. Passes don't change
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
    /// SatNOGS `alive` flag (status active vs inactive). Optional so transmitter
    /// caches written before it existed still decode; nil (and manual entries)
    /// count as active.
    var alive: Bool? = nil
    /// SatNOGS `uplink_mode` when it differs from or adds to `mode` (e.g. FM down,
    /// AFSK up). Optional for older caches; nil means "same as the downlink".
    var uplinkMode: String? = nil

    var isActive: Bool { alive ?? true }

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
        // SSTV and DUV are received in FM but deserve their own label.
        if haystack.contains("SSTV") { return "SSTV (FM)" }
        if haystack.contains("DUV") { return "FM (DUV)" }
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
    // Mutable so new-launch records can carry SatNOGS's amateur name in place of
    // CelesTrak's interim "OBJECT A" designation.
    var name: String
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

/// One point of a pass's elevation-vs-time profile.
struct ElevationSample: Sendable {
    let date: Date
    let elevation: Double
    let sunlit: Bool
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
    var minElevation = 0.0          // default elevation mask: show the whole visible pass
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
    // Operator overrides of the built-in GP source URLs (nil = default). The
    // CelesTrak override replaces the whole group URL. Optional for old blobs.
    var amsatURLOverride: String?
    /// Metric / US customary display preference (nil = follow the device region).
    var unitSystem: UnitSystem?
    var celestrakURLOverride: String?
    // NOTE: CAT (rig control) configuration is intentionally NOT stored here.
    // It lives in its own UserDefaults key (see RigController) so that evolving
    // its schema can never break decoding of the main preferences blob and reset
    // the user's settings.
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
    // New-launch provenance (extras only). `satnogsID` links the object to its
    // SatNOGS entry, whose transmitters are cached under "satnogs:<id>" because
    // SatNOGS can't yet store six-digit NORAD numbers. `placeholderNorad` means
    // `norad` is SatNOGS's temporary 9xxxx number, so elements refresh from
    // SatNOGS rather than CelesTrak. Optional, so older blobs still decode.
    var satnogsID: String?
    var placeholderNorad: Bool?

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

// MARK: - Automatic satellite switching (SatPC32 Prior.SQF model)

/// Settings for SatPC32-style automatic satellite switching. Stored under its own
/// UserDefaults key (see AutoSwitchController), never inside StorePreferences, and
/// decoded key-by-key so adding a field later can't reset the operator's list.
struct AutoSwitchSettings: Codable, Equatable, Sendable {
    /// SatPC32's Prior.SQF holds at most 9 priority satellites.
    static let maxPriorities = 9

    /// What happens when a higher-priority satellite rises during a lower one's pass.
    enum Preemption: String, Codable, CaseIterable, Identifiable, Sendable {
        case atRise      // SatPC32: switch as soon as it rises (elevation 0)
        case afterPass   // finish the current pass first
        var id: String { rawValue }
    }

    var enabled = false
    /// NORAD IDs, highest priority (1) first.
    var priorities: [UInt] = []
    var useGlobalMinElevation = true
    var minElevation = 10.0
    var preemption: Preemption = .atRise
    /// Elevation at which a rising higher-priority satellite takes over (rule 2).
    /// SatPC32 uses 0° (AOS); a negative value (e.g. −5°) switches a little before
    /// AOS so the rotator and radio are already there when it clears the horizon.
    var preemptElevation = 0.0
    /// Not in SatPC32 (which always re-asserts priority): after a manual pick, hold
    /// that satellite while it's up, or for 15 minutes if it isn't.
    var holdManualSelection = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        priorities = (try? c.decodeIfPresent([UInt].self, forKey: .priorities)) ?? []
        useGlobalMinElevation = (try? c.decodeIfPresent(Bool.self, forKey: .useGlobalMinElevation)) ?? true
        minElevation = (try? c.decodeIfPresent(Double.self, forKey: .minElevation)) ?? 10
        preemption = (try? c.decodeIfPresent(Preemption.self, forKey: .preemption)) ?? .atRise
        preemptElevation = (try? c.decodeIfPresent(Double.self, forKey: .preemptElevation)) ?? 0
        holdManualSelection = (try? c.decodeIfPresent(Bool.self, forKey: .holdManualSelection)) ?? false
    }
}

extension AutoSwitchSettings {
    /// Where a rising higher-priority satellite takes over, for display:
    /// "at AOS (0°)", "at −5°, before AOS" or "at 5°".
    var takeOverPhrase: String {
        let el = ODFormat.angle(preemptElevation, decimals: 0)
        if preemptElevation == 0 { return "at AOS (0°)" }
        return preemptElevation < 0 ? "at \(el), before AOS" : "at \(el)"
    }
}

/// A priority satellite's state at one instant, as the rules see it.
struct AutoSwitchCandidate: Sendable {
    let norad: UInt
    /// 0 = highest priority.
    let rank: Int
    let elevation: Double
    /// Elevation increasing (approaching AOS/TCA). The pre-AOS margin applies only
    /// to a rising satellite, so a setting one still hands over at LOS.
    var rising = true
}

enum AutoSwitchReason: Equatable, Sendable {
    /// No priority satellite was being tracked in range; this one reached the
    /// switch-in elevation.
    case reachedMinimum
    /// This higher-priority satellite rose during the given one's pass.
    case preempted(UInt)
    /// The given satellite set (LOS); this one was still in range.
    case fellBack(UInt)
}

struct AutoSwitchDecision: Equatable, Sendable {
    let norad: UInt
    let reason: AutoSwitchReason
}

/// SatPC32's automatic-switching rules (manual, "Prior.SQF"):
/// 1. No priority satellite in range: switch to a priority satellite as soon as
///    its elevation reaches the minimum elevation.
/// 2. A higher-priority satellite rises during a priority pass: switch to it at
///    elevation 0, so none of its pass is lost (or, optionally, after the pass).
/// 3. The tracked priority satellite reaches LOS: switch to a lower-priority
///    satellite that is still in range.
/// Pure, so the live controller and the schedule simulator share it exactly.
enum AutoSwitchRules {
    /// `preemptElevation` is where a rising higher-priority satellite takes over
    /// (SatPC32: 0°). When it's negative, a satellite at or above it also counts as
    /// "in range" for the current one, so a bird switched to just before AOS isn't
    /// immediately dropped again for being below the horizon.
    nonisolated static func decide(current: UInt?,
                                   currentWasInRange: Bool,
                                   candidates: [AutoSwitchCandidate],
                                   threshold: Double,
                                   preemption: AutoSwitchSettings.Preemption,
                                   preemptElevation: Double = 0) -> AutoSwitchDecision? {
        let ranked = candidates.sorted { $0.rank < $1.rank }
        let rangeFloor = min(0, preemptElevation)
        func inRange(_ c: AutoSwitchCandidate) -> Bool { c.elevation >= 0 || (c.rising && c.elevation >= rangeFloor) }
        if let cur = ranked.first(where: { $0.norad == current }) {
            if inRange(cur) {
                // Rule 2: only a higher-priority satellite that has risen (to the
                // preempt elevation) takes over.
                guard preemption == .atRise,
                      let higher = ranked.first(where: { $0.rank < cur.rank && $0.elevation >= preemptElevation
                                                         && ($0.elevation >= 0 || $0.rising) }) else { return nil }
                return AutoSwitchDecision(norad: higher.norad, reason: .preempted(cur.norad))
            }
            // Rule 3: on the LOS transition, hand over to whatever is still up.
            if currentWasInRange, let next = ranked.first(where: { $0.norad != cur.norad && $0.elevation >= 0 }) {
                return AutoSwitchDecision(norad: next.norad, reason: .fellBack(cur.norad))
            }
        }
        // Rule 1: nothing (priority) in range is being tracked.
        guard let pick = ranked.first(where: { $0.elevation >= threshold && $0.norad != current }) else { return nil }
        return AutoSwitchDecision(norad: pick.norad, reason: .reachedMinimum)
    }
}
