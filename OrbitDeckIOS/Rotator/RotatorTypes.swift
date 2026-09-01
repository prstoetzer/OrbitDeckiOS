import Foundation

// ===========================================================================
//  RotatorTypes.swift — antenna rotator (az/el) control data model
//
//  Ported from CardSat's rotator.cpp/.h and settings.h. Mirrors the CAT design:
//  a controller drives a transport (BLE serial for GS-232/EasyComm/SPID, or a
//  network socket for rotctld/PstRotator) and points the antenna at the selected
//  satellite. CardSat's hardware-specific paths (I2C→UART bridge, Yaesu-direct
//  via ADC/GPIO) are not applicable on iOS and are excluded.
// ===========================================================================

/// Rotator control protocol. Serial protocols run over a BLE UART adapter;
/// rotctld/PstRotator are network protocols.
enum RotatorProtocolKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case gs232        // Yaesu GS-232A/B (ASCII, "Waaa eee")
    case easycomm1    // Easycomm I  (integer ASCII)
    case easycomm2    // Easycomm II (decimal ASCII)
    case easycomm3    // Easycomm III (II grammar; velocity ignored)
    case spid         // SPID Rot2Prog / MD-01/02 (binary)
    case saebrtrack   // SAEBRTrack (Arduino/SatPC32 compact ASCII, serial)
    case rotctld      // Hamlib NET rotctl over TCP
    case pstRotator   // PstRotator over UDP
    case urc          // OZ9AAR URC (TCP/JSON)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .gs232: "Yaesu GS-232A/B"
        case .easycomm1: "Easycomm I"
        case .easycomm2: "Easycomm II"
        case .easycomm3: "Easycomm III"
        case .spid: "SPID Rot2Prog (MD-01/02)"
        case .saebrtrack: "SAEBRTrack (serial)"
        case .rotctld: "rotctld (Hamlib NET, TCP)"
        case .pstRotator: "PstRotator (UDP)"
        case .urc: "OZ9AAR URC (TCP/JSON)"
        }
    }
    var isNetwork: Bool { self == .rotctld || self == .pstRotator || self == .urc }
    var isSerial: Bool { !isNetwork }
    var usesTCP: Bool { self == .rotctld || self == .urc }
    var defaultPort: Int {
        switch self { case .rotctld: 4533; case .urc: 1111; default: 12000 }
    }
}

/// Azimuth-axis convention of the rotator (matches Gpredict's rotator setting).
enum RotAzRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case az360   // 0…360°, 0 = North (default)
    case az180   // −180…+180°, centered on North
    case az450   // 0…450°, 90° overlap to avoid a North cable-wrap
    var id: String { rawValue }
    var label: String {
        switch self { case .az360: "0–360°"; case .az180: "−180…+180°"; case .az450: "0–450° (overlap)" }
    }
}

/// Persisted rotator configuration — the full set of CardSat options that apply
/// on iOS. Stored in its own UserDefaults key (see RotatorController).
struct RotatorConfig: Codable, Sendable, Equatable {
    var enabled = false
    var proto: RotatorProtocolKind = .gs232
    // Serial (BLE) transport
    var bleIdentifier = ""
    var bleName = ""
    var baud = 9600                 // informational for BLE (set on the adapter)
    // Network transport (rotctld / PstRotator)
    var host = ""
    var port = 4533
    // Behavior / tuning (CardSat parity)
    var leadSec = 120               // pre-position lead before AOS (s; 0 = off)
    var trackLeadSec = 0            // aim this far ahead while tracking (mechanical slew lag; 0 = off)
    var azLookSec = 3               // 450° overlap az lookahead (s; 0 = off)
    var azRange: RotAzRange = .az360
    var azOffsetDeg = 0             // alignment offset added to commanded azimuth
    var elOffsetDeg = 0             // alignment offset added to commanded elevation
    var deadbandDeg = 3             // suppress smaller moves (anti-chatter)
    var magCorrect = false          // send magnetic instead of true (subtract declination)
    var parkAz = 0                  // park azimuth on LOS / when disconnected
    var parkEl = 0                  // park elevation
    var flip = false                // flip mode (az+180, el=180−el) for overhead passes
    var minElevationDeg = 0.0       // only track above this elevation (0 = whole visible pass)
    var updateMs = 1000             // pointing loop period

    var isConfigured: Bool {
        guard enabled else { return false }
        return proto.isNetwork ? !host.isEmpty : !bleIdentifier.isEmpty
    }
}

// MARK: - Tolerant Codable
//
// Decode each field with a default fallback so adding fields later never fails to
// decode a saved config (Swift's synthesized Codable throws on a missing key).

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ def: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
    }
}

extension RotatorConfig {
    enum CK: String, CodingKey {
        case enabled, proto, bleIdentifier, bleName, baud, host, port
        case leadSec, trackLeadSec, azLookSec, azRange, azOffsetDeg, elOffsetDeg, deadbandDeg
        case magCorrect, parkAz, parkEl, flip, minElevationDeg, updateMs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var r = RotatorConfig()
        r.enabled = c.value(Bool.self, .enabled, r.enabled)
        r.proto = c.value(RotatorProtocolKind.self, .proto, r.proto)
        r.bleIdentifier = c.value(String.self, .bleIdentifier, r.bleIdentifier)
        r.bleName = c.value(String.self, .bleName, r.bleName)
        r.baud = c.value(Int.self, .baud, r.baud)
        r.host = c.value(String.self, .host, r.host)
        r.port = c.value(Int.self, .port, r.port)
        r.leadSec = c.value(Int.self, .leadSec, r.leadSec)
        r.trackLeadSec = c.value(Int.self, .trackLeadSec, r.trackLeadSec)
        r.azLookSec = c.value(Int.self, .azLookSec, r.azLookSec)
        r.azRange = c.value(RotAzRange.self, .azRange, r.azRange)
        r.azOffsetDeg = c.value(Int.self, .azOffsetDeg, r.azOffsetDeg)
        r.elOffsetDeg = c.value(Int.self, .elOffsetDeg, r.elOffsetDeg)
        r.deadbandDeg = c.value(Int.self, .deadbandDeg, r.deadbandDeg)
        r.magCorrect = c.value(Bool.self, .magCorrect, r.magCorrect)
        r.parkAz = c.value(Int.self, .parkAz, r.parkAz)
        r.parkEl = c.value(Int.self, .parkEl, r.parkEl)
        r.flip = c.value(Bool.self, .flip, r.flip)
        r.minElevationDeg = c.value(Double.self, .minElevationDeg, r.minElevationDeg)
        r.updateMs = c.value(Int.self, .updateMs, r.updateMs)
        self = r
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(proto, forKey: .proto)
        try c.encode(bleIdentifier, forKey: .bleIdentifier)
        try c.encode(bleName, forKey: .bleName)
        try c.encode(baud, forKey: .baud)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(leadSec, forKey: .leadSec)
        try c.encode(trackLeadSec, forKey: .trackLeadSec)
        try c.encode(azLookSec, forKey: .azLookSec)
        try c.encode(azRange, forKey: .azRange)
        try c.encode(azOffsetDeg, forKey: .azOffsetDeg)
        try c.encode(elOffsetDeg, forKey: .elOffsetDeg)
        try c.encode(deadbandDeg, forKey: .deadbandDeg)
        try c.encode(magCorrect, forKey: .magCorrect)
        try c.encode(parkAz, forKey: .parkAz)
        try c.encode(parkEl, forKey: .parkEl)
        try c.encode(flip, forKey: .flip)
        try c.encode(minElevationDeg, forKey: .minElevationDeg)
        try c.encode(updateMs, forKey: .updateMs)
    }
}
