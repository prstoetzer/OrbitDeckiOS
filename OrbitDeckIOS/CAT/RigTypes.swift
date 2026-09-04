import Foundation

// ===========================================================================
//  RigTypes.swift — CAT (Computer Aided Transceiver) data model
//
//  Ported from CardSat's radio_profiles.h / settings.h (the bench-validated
//  reference). CardSat speaks three CAT dialect families; OrbitDeck drives the
//  radios that expose a serial CI-V / Yaesu / Kenwood interface over a BLE UART
//  adapter, plus Icom radios with native network (RS-BA1) CAT over Wi-Fi.
//
//  iOS constraint: generic Bluetooth *Classic* (SPP) serial adapters cannot be
//  opened without MFi. Only BLE (Low Energy) UART adapters work here; the Kenwood
//  B.B. Link and BLE CI-V/serial adapters are BLE. USB-only radios (FT-991/991A/
//  FTX-1) are intentionally excluded — they have no serial or network interface a
//  phone can reach.
// ===========================================================================

/// Operating mode, mapped to each family's wire encoding by `CATCodec`.
enum RigMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case lsb, usb, cw, fm, fmn, am, data
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lsb: "LSB"; case .usb: "USB"; case .cw: "CW"
        case .fm: "FM"; case .fmn: "FM-N"; case .am: "AM"; case .data: "Data"
        }
    }
    /// True for both wide and narrow FM (deadband, tone, "is this an FM bird" checks).
    var isFM: Bool { self == .fm || self == .fmn }

    /// Best-effort parse of a transponder/mode string ("USB", "FM", "CW", …).
    static func parse(_ text: String) -> RigMode {
        let t = text.uppercased()
        if t.contains("LSB") { return .lsb }
        if t.contains("USB") { return .usb }
        if t.contains("CW") { return .cw }
        // Narrow FM ("FM-N", "FMN", "NFM") before plain FM (all contain "FM").
        if t.contains("FMN") || t.contains("FM-N") || t.contains("NFM") { return .fmn }
        if t.contains("FM") { return .fm }
        if t.contains("AM") { return .am }
        if t.contains("DATA") || t.contains("DIG") || t.contains("FSK") || t.contains("RTTY") { return .data }
        return .usb
    }
}

/// CAT dialect family. Determines which encoder in `CATCodec` builds the frames.
enum RigFamily: String, Codable, Sendable {
    case civ            // Icom CI-V binary (FE FE … FD)
    case yaesuBinary    // FT-817/818/857/897, FT-847 — 5-byte binary, big-endian BCD
    case yaesuFT100     // FT-100 — 5-byte, little-endian BCD, opcode 0x0A/0x0C
    case yaesuVR5000    // VR-5000 — FT-817 framing, FM = 0x88, no read
    case yaesuFT736     // FT-736R — FT-817 framing, needs CAT-ON, write-only
    case kenwoodBase    // TS-711/811/790/2000 — ASCII FA/FB/MD ';'-terminated
    case kenwoodHandheld // TH-D74/D75 — ASCII "FQ b,hz" / "MD b,m" on band B
    case rigctld        // Hamlib NET rigctl over TCP; Hamlib abstracts the rig
}

/// A radio the app can drive. Fields mirror CardSat's RadioProfile / LegProfile.
struct RadioSpec: Identifiable, Sendable, Hashable {
    let id: String          // stable key, e.g. "IC-9700"
    let name: String
    let family: RigFamily
    let civAddr: UInt8      // CI-V address (Icom only)
    let defaultBaud: Int
    let fullDuplex: Bool    // has MAIN/SUB satellite operation (true sat rigs)
    let rxOnly: Bool        // receive-only; cannot be the uplink radio
    let hasLan: Bool        // native Icom network (RS-BA1) CAT available
    let canReadFreq: Bool
    let modeFilter: Bool    // append filter byte to CI-V cmd 06
    let hasSatMode: Bool
    let satModeCmd: UInt8   // CI-V satmode command (9100/9700 0x16, 910 0x1A)
    let satModeSub: UInt8   // sub (9100/9700 0x5A, 910 0x07)
    let hasTone: Bool
    let toneEncSub: UInt8   // CI-V tone-encoder sub under 0x16 (0x42 / 0x43)
    let selMain: [UInt8]    // CI-V MAIN band-access bytes (07 D0/D1)
    let selSub: [UInt8]     // CI-V SUB band-access bytes
    let canAssignBand: Bool // CI-V 07 D2 band assignment (9100/9700)
    let wideFreq: Bool      // 6-byte CI-V frequency above 5.85 GHz (IC-905)
    /// CI-V filter byte for narrow FM (FM-N), or 0 if the rig can't select it over CAT.
    /// Amateur FM satellites are narrow-band, so FM birds are commanded with `06 05 <this>`
    /// (e.g. IC-910/9100/9700 → 0x02 = FIL2). 0 falls back to plain FM.
    var fmNarrowFilter: UInt8 = 0
}

// MARK: - Radio catalog

enum RadioCatalog {
    /// Full-duplex satellite transceivers (MAIN/SUB), from CardSat RADIOS[].
    static let fullDuplex: [RadioSpec] = [
        civ("IC-820", 0x42, 9600, selMain: [0x07,0xD1], selSub: [0x07,0xD0], sat: false),
        civ("IC-821", 0x4C, 9600, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: false),
        civ("IC-910", 0x60, 19200, selMain: [0x07,0xD1], selSub: [0x07,0xD0], sat: true,
            satCmd: 0x1A, satSub: 0x07, tone: true, toneSub: 0x42, modeFilter: false, fmNarrow: 0x02),
        civ("IC-970", 0x2E, 9600, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: false,
            satCmd: 0x16, satSub: 0x5A),
        civ("IC-9100", 0x7C, 19200, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: true,
            satCmd: 0x16, satSub: 0x5A, tone: true, toneSub: 0x42, assignBand: true, fmNarrow: 0x02),
        civ("IC-9700", 0xA2, 19200, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: true,
            satCmd: 0x16, satSub: 0x5A, tone: true, toneSub: 0x42, assignBand: true, lan: true, fmNarrow: 0x02),
        RadioSpec(id: "FT-847", name: "FT-847", family: .yaesuBinary, civAddr: 0, defaultBaud: 57600,
                  fullDuplex: true, rxOnly: false, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: true, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "FT-736R", name: "FT-736R", family: .yaesuFT736, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: true, rxOnly: false, hasLan: false, canReadFreq: false, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TS-790", name: "TS-790", family: .kenwoodBase, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: true, rxOnly: false, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TS-2000", name: "TS-2000", family: .kenwoodBase, civAddr: 0, defaultBaud: 57600,
                  fullDuplex: true, rxOnly: false, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: true, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
    ]

    /// Single-VFO ("leg") transceivers and receivers, from CardSat LEG_RADIOS[].
    /// Used for a half-duplex single radio (uplink or downlink) or a two-radio
    /// station. Excludes the FT-991/991A/FTX-1 (USB-only, unreachable on iOS).
    static let mono: [RadioSpec] = [
        // Icom CI-V transceivers
        civLeg("IC-705", 0xA4, 19200, lan: true),
        civLeg("IC-905", 0xAC, 19200, lan: true, wide: true),
        civLeg("IC-7100", 0x88, 19200),
        civLeg("IC-7000", 0x70, 19200, modeFilter: false, canRead: true),
        civLeg("IC-706MKIIG", 0x58, 9600),
        civLeg("IC-706MKII", 0x4E, 9600),
        civLeg("IC-706", 0x48, 9600),
        civLeg("IC-275", 0x10, 9600),
        civLeg("IC-475", 0x14, 9600, modeFilter: false),
        civLeg("IC-271", 0x20, 9600),
        civLeg("IC-471", 0x22, 9600),
        civLeg("IC-575", 0x16, 9600),
        civLeg("IC-1275", 0x18, 9600),
        // Icom CI-V receivers (RX only)
        civLeg("IC-R10", 0x52, 9600, rxOnly: true),
        civLeg("IC-R20", 0x6C, 9600, rxOnly: true),
        civLeg("IC-R30", 0x9C, 9600, rxOnly: true),
        civLeg("IC-R7000", 0x08, 1200, rxOnly: true),
        civLeg("IC-R7100", 0x34, 9600, rxOnly: true),
        civLeg("IC-R8500", 0x4A, 9600, rxOnly: true),
        civLeg("IC-R8600", 0x96, 19200, rxOnly: true),
        civLeg("IC-R9000", 0x2A, 1200, rxOnly: true),
        civLeg("IC-R9500", 0x72, 19200, rxOnly: true),
        // Yaesu old binary (FT-817 family)
        yaesuLeg("FT-817", .yaesuBinary, 9600),
        yaesuLeg("FT-818", .yaesuBinary, 9600),
        yaesuLeg("FT-857", .yaesuBinary, 9600),
        yaesuLeg("FT-897", .yaesuBinary, 9600),
        yaesuLeg("FT-100", .yaesuFT100, 9600),
        yaesuLeg("VR-5000", .yaesuVR5000, 9600, rxOnly: true, canRead: false),
        // Kenwood all-mode base stations
        RadioSpec(id: "TS-711", name: "TS-711", family: .kenwoodBase, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: false, rxOnly: false, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TS-811", name: "TS-811", family: .kenwoodBase, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: false, rxOnly: false, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        // Kenwood handhelds via the B.B. Link BLE adapter (all-mode receiver on band B)
        RadioSpec(id: "TH-D74", name: "TH-D74", family: .kenwoodHandheld, civAddr: 0, defaultBaud: 9600,
                  fullDuplex: false, rxOnly: true, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TH-D75", name: "TH-D75", family: .kenwoodHandheld, civAddr: 0, defaultBaud: 9600,
                  fullDuplex: false, rxOnly: true, hasLan: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
    ]

    /// Every radio, full-duplex first.
    static let all: [RadioSpec] = fullDuplex + mono

    /// Synthetic spec for a radio driven through a Hamlib `rigctld` server. Hamlib
    /// abstracts the actual rig, so there is no catalog entry — this stands in so
    /// the controller's per-link plumbing (which expects a `RadioSpec`) works. It
    /// is treated as full-duplex-capable (split VFO) and frequency-readable.
    static let rigctld = RadioSpec(id: "RIGCTLD", name: "rigctld", family: .rigctld, civAddr: 0, defaultBaud: 0,
                                   fullDuplex: true, rxOnly: false, hasLan: false, canReadFreq: true, modeFilter: false,
                                   hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                                   selMain: [], selSub: [], canAssignBand: false, wideFreq: false)

    static func spec(id: String) -> RadioSpec? {
        id == rigctld.id ? rigctld : all.first { $0.id == id }
    }

    // -- builders ----------------------------------------------------------
    private static func civ(_ name: String, _ addr: UInt8, _ baud: Int,
                            selMain: [UInt8], selSub: [UInt8], sat: Bool,
                            satCmd: UInt8 = 0, satSub: UInt8 = 0,
                            tone: Bool = false, toneSub: UInt8 = 0,
                            modeFilter: Bool = true, assignBand: Bool = false,
                            lan: Bool = false, fmNarrow: UInt8 = 0) -> RadioSpec {
        RadioSpec(id: name, name: name, family: .civ, civAddr: addr, defaultBaud: baud,
                  fullDuplex: true, rxOnly: false, hasLan: lan, canReadFreq: true, modeFilter: modeFilter,
                  hasSatMode: sat, satModeCmd: satCmd, satModeSub: satSub, hasTone: tone, toneEncSub: toneSub,
                  selMain: selMain, selSub: selSub, canAssignBand: assignBand, wideFreq: false,
                  fmNarrowFilter: fmNarrow)
    }
    private static func civLeg(_ name: String, _ addr: UInt8, _ baud: Int,
                               rxOnly: Bool = false, lan: Bool = false, wide: Bool = false,
                               modeFilter: Bool = true, canRead: Bool = true) -> RadioSpec {
        RadioSpec(id: name, name: name, family: .civ, civAddr: addr, defaultBaud: baud,
                  fullDuplex: false, rxOnly: rxOnly, hasLan: lan, canReadFreq: canRead, modeFilter: modeFilter,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: wide)
    }
    private static func yaesuLeg(_ name: String, _ family: RigFamily, _ baud: Int,
                                 rxOnly: Bool = false, canRead: Bool = true) -> RadioSpec {
        RadioSpec(id: name, name: name, family: family, civAddr: 0, defaultBaud: baud,
                  fullDuplex: false, rxOnly: rxOnly, hasLan: false, canReadFreq: canRead, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false)
    }
}

// MARK: - Roles / transport

/// Which leg(s) a radio drives.
enum RigRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case both       // one full-duplex radio: uplink + downlink (MAIN/SUB)
    case downlink   // receive leg only
    case uplink     // transmit leg only
    var id: String { rawValue }
    var label: String {
        switch self { case .both: "Uplink + downlink"; case .downlink: "Downlink only"; case .uplink: "Uplink only" }
    }
}

/// How the app reaches the radio.
enum CATTransportKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case ble        // BLE UART adapter (CoreBluetooth)
    case network    // Icom RS-BA1 over Wi-Fi
    case rigctld    // Hamlib rigctld server over TCP
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ble: "BLE serial adapter"
        case .network: "Icom network (Wi-Fi)"
        case .rigctld: "Hamlib rigctld (network)"
        }
    }
}

/// One configured radio.
struct RigSlot: Codable, Sendable, Equatable {
    var enabled = false
    var radioID = ""                 // RadioSpec.id
    var role: RigRole = .both
    var transport: CATTransportKind = .ble
    var bleIdentifier = ""           // CBPeripheral.identifier UUID string
    var bleName = ""
    var host = ""                    // network host/IP
    var port = 50001
    var username = ""                // Icom Network User1 (password in Keychain)
    var civAddrOverride = 0          // 0 = use radio default
    var baudOverride = 0             // 0 = use radio default (informational; BLE adapters set their own baud)

    /// The driving radio spec. For a rigctld link there is no catalog radio —
    /// Hamlib abstracts it — so return the synthetic rigctld spec.
    var spec: RadioSpec? { transport == .rigctld ? RadioCatalog.rigctld : RadioCatalog.spec(id: radioID) }
}

/// Persisted CAT configuration. Slot 0 is the primary/downlink radio; slot 1 is
/// the uplink radio in a two-radio station.
struct CATConfig: Codable, Sendable, Equatable {
    var enabled = false
    var twoRadios = false            // false = single radio (slot 0), true = dual
    var slots: [RigSlot] = [RigSlot(), RigSlot()]
    var tuning = CATTuning()

    var isConfigured: Bool {
        guard enabled else { return false }
        guard let s = slots.first, s.enabled else { return false }
        // A rigctld link needs only a host; a catalog radio needs a model.
        if s.transport == .rigctld { return !s.host.isEmpty }
        return !s.radioID.isEmpty
    }
}

/// All Doppler/tuning options, ported from CardSat settings.h.
struct CATTuning: Codable, Sendable, Equatable {
    var trackDoppler = true          // run the Doppler tuning loop
    var updateMs = 500               // CAT/Doppler update period
    var commandDelayMs = 70          // pause after each CAT frame
    var mainIsUplink = true          // VFO_MAIN_UP_SUB_DOWN default
    var satMode = false              // command the rig's own satellite mode
    var assignBands = false          // send CI-V 07 D2 band assignment at engage
    var fmDeadbandHz = 300           // FM write deadband
    var linearDeadbandHz = 20        // SSB/CW write deadband (tight for FT4/CW tracking)
    var narrowFM = true              // command narrow FM (FM-N) on FM satellites (they're narrow-band)
    var leadMs = 100                 // predictive-lead atop the auto interval-centering
    var calDownlinkHz = 0            // extra global downlink oscillator trim
    var calUplinkHz = 0              // extra global uplink oscillator trim
    var xvtrDownlinkHz: Int64 = 0    // downlink transverter LO (real - this = rig IF)
    var xvtrUplinkHz: Int64 = 0      // uplink transverter LO
    var uplinkToneHz = 0.0           // CTCSS (PL) on the FM uplink; 0 = off
    var passbandOffsetHz = 0.0       // linear-transponder passband offset
    // "One True Rule" read-back: follow the operator's dial on one leg and keep
    // the other leg mapped through the transponder. Downlink is the usual master.
    var followRadio = false
    var followLeg: RigRole = .downlink
    // After the operator moves the dial, pause CAT Doppler on the followed leg briefly so
    // reads settle before we resume tracking (a short window — much tighter than the
    // ~800/2500 ms desktop trackers use — since a phone loop is faster and operators expect
    // snappy resume). Uplink gets a little longer so a quick dial nudge isn't fought mid-QSO.
    var followSettleMs = 250
    var followUplinkResumeMs = 700
    // rigctld: for a full-duplex single radio (role .both), track uplink on the
    // split/TX VFO (rigctl `S 1 VFOB` + `I`/`X`). Turn off for backends without a
    // usable split.
    var rigctldUseSplit = true
}

// MARK: - CTCSS

// MARK: - Tolerant Codable
//
// Decode each field with a default fallback so ADDING fields in a later release
// never fails to decode a saved config (Swift's synthesized Codable throws on a
// missing key). This keeps a user's rig setup across upgrades.

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ def: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
    }
}

extension RigSlot {
    enum CK: String, CodingKey {
        case enabled, radioID, role, transport, bleIdentifier, bleName, host, port, username, civAddrOverride, baudOverride
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var s = RigSlot()
        s.enabled = c.value(Bool.self, .enabled, s.enabled)
        s.radioID = c.value(String.self, .radioID, s.radioID)
        s.role = c.value(RigRole.self, .role, s.role)
        s.transport = c.value(CATTransportKind.self, .transport, s.transport)
        s.bleIdentifier = c.value(String.self, .bleIdentifier, s.bleIdentifier)
        s.bleName = c.value(String.self, .bleName, s.bleName)
        s.host = c.value(String.self, .host, s.host)
        s.port = c.value(Int.self, .port, s.port)
        s.username = c.value(String.self, .username, s.username)
        s.civAddrOverride = c.value(Int.self, .civAddrOverride, s.civAddrOverride)
        s.baudOverride = c.value(Int.self, .baudOverride, s.baudOverride)
        self = s
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(radioID, forKey: .radioID)
        try c.encode(role, forKey: .role)
        try c.encode(transport, forKey: .transport)
        try c.encode(bleIdentifier, forKey: .bleIdentifier)
        try c.encode(bleName, forKey: .bleName)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(civAddrOverride, forKey: .civAddrOverride)
        try c.encode(baudOverride, forKey: .baudOverride)
    }
}

extension CATTuning {
    enum CK: String, CodingKey {
        case trackDoppler, updateMs, commandDelayMs, mainIsUplink, satMode, assignBands
        case fmDeadbandHz, linearDeadbandHz, narrowFM, leadMs, calDownlinkHz, calUplinkHz
        case xvtrDownlinkHz, xvtrUplinkHz, uplinkToneHz, passbandOffsetHz, followRadio, followLeg
        case followSettleMs, followUplinkResumeMs, rigctldUseSplit
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var t = CATTuning()
        t.trackDoppler = c.value(Bool.self, .trackDoppler, t.trackDoppler)
        t.updateMs = c.value(Int.self, .updateMs, t.updateMs)
        t.commandDelayMs = c.value(Int.self, .commandDelayMs, t.commandDelayMs)
        t.mainIsUplink = c.value(Bool.self, .mainIsUplink, t.mainIsUplink)
        t.satMode = c.value(Bool.self, .satMode, t.satMode)
        t.assignBands = c.value(Bool.self, .assignBands, t.assignBands)
        t.fmDeadbandHz = c.value(Int.self, .fmDeadbandHz, t.fmDeadbandHz)
        t.linearDeadbandHz = c.value(Int.self, .linearDeadbandHz, t.linearDeadbandHz)
        t.narrowFM = c.value(Bool.self, .narrowFM, t.narrowFM)
        t.leadMs = c.value(Int.self, .leadMs, t.leadMs)
        t.calDownlinkHz = c.value(Int.self, .calDownlinkHz, t.calDownlinkHz)
        t.calUplinkHz = c.value(Int.self, .calUplinkHz, t.calUplinkHz)
        t.xvtrDownlinkHz = c.value(Int64.self, .xvtrDownlinkHz, t.xvtrDownlinkHz)
        t.xvtrUplinkHz = c.value(Int64.self, .xvtrUplinkHz, t.xvtrUplinkHz)
        t.uplinkToneHz = c.value(Double.self, .uplinkToneHz, t.uplinkToneHz)
        t.passbandOffsetHz = c.value(Double.self, .passbandOffsetHz, t.passbandOffsetHz)
        t.followRadio = c.value(Bool.self, .followRadio, t.followRadio)
        t.followLeg = c.value(RigRole.self, .followLeg, t.followLeg)
        t.followSettleMs = c.value(Int.self, .followSettleMs, t.followSettleMs)
        t.followUplinkResumeMs = c.value(Int.self, .followUplinkResumeMs, t.followUplinkResumeMs)
        t.rigctldUseSplit = c.value(Bool.self, .rigctldUseSplit, t.rigctldUseSplit)
        self = t
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(trackDoppler, forKey: .trackDoppler)
        try c.encode(updateMs, forKey: .updateMs)
        try c.encode(commandDelayMs, forKey: .commandDelayMs)
        try c.encode(mainIsUplink, forKey: .mainIsUplink)
        try c.encode(satMode, forKey: .satMode)
        try c.encode(assignBands, forKey: .assignBands)
        try c.encode(fmDeadbandHz, forKey: .fmDeadbandHz)
        try c.encode(linearDeadbandHz, forKey: .linearDeadbandHz)
        try c.encode(narrowFM, forKey: .narrowFM)
        try c.encode(leadMs, forKey: .leadMs)
        try c.encode(calDownlinkHz, forKey: .calDownlinkHz)
        try c.encode(calUplinkHz, forKey: .calUplinkHz)
        try c.encode(xvtrDownlinkHz, forKey: .xvtrDownlinkHz)
        try c.encode(xvtrUplinkHz, forKey: .xvtrUplinkHz)
        try c.encode(uplinkToneHz, forKey: .uplinkToneHz)
        try c.encode(passbandOffsetHz, forKey: .passbandOffsetHz)
        try c.encode(followRadio, forKey: .followRadio)
        try c.encode(followLeg, forKey: .followLeg)
        try c.encode(followSettleMs, forKey: .followSettleMs)
        try c.encode(followUplinkResumeMs, forKey: .followUplinkResumeMs)
        try c.encode(rigctldUseSplit, forKey: .rigctldUseSplit)
    }
}

extension CATConfig {
    enum CK: String, CodingKey { case enabled, twoRadios, slots, tuning }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var cfg = CATConfig()
        cfg.enabled = c.value(Bool.self, .enabled, cfg.enabled)
        cfg.twoRadios = c.value(Bool.self, .twoRadios, cfg.twoRadios)
        cfg.slots = c.value([RigSlot].self, .slots, cfg.slots)
        if cfg.slots.count < 2 { cfg.slots += Array(repeating: RigSlot(), count: 2 - cfg.slots.count) }
        cfg.tuning = c.value(CATTuning.self, .tuning, cfg.tuning)
        self = cfg
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(twoRadios, forKey: .twoRadios)
        try c.encode(slots, forKey: .slots)
        try c.encode(tuning, forKey: .tuning)
    }
}

enum CTCSS {
    /// The 39-tone list (standard 38 EIA tones plus 69.3 Hz), in tenths of Hz, ascending —
    /// the order the Yaesu FT-847 code table (`ft847CTCSS`) is aligned to. The Kenwood tone
    /// number uses `kenwoodTenths` (38 tones, no 69.3 Hz) instead — see below.
    static let tenths: [Int] = [
        670, 693, 719, 744, 770, 797, 825, 854, 885, 915,
        948, 974, 1000, 1035, 1072, 1109, 1148, 1188, 1230, 1273,
        1318, 1365, 1413, 1462, 1514, 1567, 1622, 1679, 1738, 1799,
        1862, 1928, 2035, 2107, 2181, 2257, 2336, 2418, 2503
    ]

    /// Nearest standard tone index for a frequency, or nil if none within ~1 Hz.
    static func index(hz: Double) -> Int? {
        guard hz > 0 else { return nil }
        let target = Int((hz * 10).rounded())
        var best = -1, bestErr = 9999
        for (i, t) in tenths.enumerated() {
            let e = abs(t - target)
            if e < bestErr { bestErr = e; best = i }
        }
        return bestErr <= 10 ? best : nil
    }

    static let availableHz: [Double] = tenths.map { Double($0) / 10.0 }

    /// The Kenwood TS-2000/790 `TN`/`CN` tone list — the standard 38 EIA tones, which do
    /// NOT include 69.3 Hz. The shared 39-tone list above carries 69.3 Hz (index 1) for the
    /// Yaesu code table; using that list's index for the Kenwood tone *number* shifted every
    /// tone at/above 71.9 Hz by one (e.g. 141.3 Hz was commanded as the next tone up), so the
    /// wrong sub-audible tone went out on FM uplinks. Matches Hamlib's ts2000_ctcss_list.
    static let kenwoodTenths: [Int] = tenths.filter { $0 != 693 }

    /// 1-based Kenwood `TN`/`CN` tone number for a frequency (nearest within ~1 Hz), or nil.
    static func kenwoodIndex(hz: Double) -> Int? {
        guard hz > 0 else { return nil }
        let target = Int((hz * 10).rounded())
        var best = -1, bestErr = 9999
        for (i, t) in kenwoodTenths.enumerated() {
            let e = abs(t - target)
            if e < bestErr { bestErr = e; best = i }
        }
        return bestErr <= 10 ? best + 1 : nil
    }
}
