import Foundation

// ===========================================================================
//  RigTypes.swift — CAT (Computer Aided Transceiver) data model
//
//  Ported from CardSat's radio_profiles.h / settings.h (the bench-validated
//  reference). CardSat speaks three CAT dialect families; OrbitDeck drives the
//  radios that expose a serial CI-V / Yaesu / Kenwood interface over a BLE UART
//  adapter, plus Icom radios with native network (RS-BA1) CAT over Wi-Fi
//  and Icom radios with native bluetooth CAT capability (IC-705/IC-905).
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

    /// Receiver mode for a transponder/SatNOGS mode string ("USB", "FM", "SSTV",
    /// "AFSK", "GMSK USP", "BPSK", …). SatNOGS names the *modulation*, not the
    /// receiver mode, so each modulation maps to how it is received on an amateur
    /// rig: SSTV, AFSK/APRS packet, FSK/GMSK/G3RUH data, DUV and APT come out of an
    /// FM receiver, while PSK, LoRa, OFDM and WSJT modes are taken in USB. When a
    /// string names several (e.g. "GFSK/BPSK"), the first one wins. Unrecognized
    /// strings return `fallback`.
    static func parse(_ text: String, fallback: RigMode = .usb) -> RigMode {
        let t = text.uppercased()
        // Narrow FM first: every spelling contains "FM".
        if t.contains("FMN") || t.contains("FM-N") || t.contains("NFM") { return .fmn }
        var best: (position: String.Index, mode: RigMode)?
        func consider(_ token: String, _ mode: RigMode) {
            guard let r = t.range(of: token) else { return }
            if best == nil || r.lowerBound < best!.position { best = (r.lowerBound, mode) }
        }
        consider("LSB", .lsb)
        consider("USB", .usb)
        consider("CW", .cw)
        consider("MORSE", .cw)
        // FM-received modulations.
        for token in ["FM", "SSTV", "AFSK", "APRS", "FSK", "GMSK", "GFSK", "MSK", "G3RUH", "AX.25", "AX.100",
                      "DUV", "APT", "DSTAR", "D-STAR", "SSDV"] { consider(token, .fm) }
        // SSB-received modulations. MFSK is checked so it beats the "FSK" inside it.
        for token in ["BPSK", "QPSK", "PSK", "MFSK", "LORA", "FT8", "FT4", "WSJT", "OFDM", "RTTY", "DSB",
                      "SIDLOC", "CERTO", "DOKA"] { consider(token, .usb) }
        // A bare "AM" word (avoid matching inside other words).
        if t.split(whereSeparator: { !$0.isLetter }).contains("AM") { consider("AM", .am) }
        // Earliest token wins; "MFSK" starts before the "FSK" inside it, so it beats it.
        if let best { return best.mode }
        if t.contains("DATA") || t.contains("DIG") { return .data }
        return fallback
    }

    /// Whether a mode string + baud rate is narrow-band enough for FM-N. Voice FM,
    /// SSTV and 1200-baud AFSK/APRS are; 9600-baud (G3RUH/GMSK/GFSK/FSK) data needs
    /// the wide FM filter or it won't decode, and data with an unknown baud is left wide.
    static func narrowFMSuitable(_ text: String, baud: Double) -> Bool {
        if baud >= 4800 { return false }
        let t = text.uppercased()
        if t.contains("G3RUH") || t.contains("9K6") || t.contains("9600") { return false }
        let narrowFamilies = ["SSTV", "AFSK", "APRS", "DUV", "FMN", "FM-N", "NFM"]
        if narrowFamilies.contains(where: { t.contains($0) }) { return true }
        // Plain "FM" voice (not an FSK data mode, which would contain FSK/MSK).
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains("FM") { return true }
        // No mode on file: treat as voice FM (the FM fallback in `downlink(for:)`).
        return t.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Receiver mode for a transponder's downlink. Unknown/empty modes fall back to
    /// USB on a linear transponder and FM otherwise (most amateur single-channel
    /// downlinks are FM or FM-received data).
    static func downlink(for tp: TransponderRecord) -> RigMode {
        parse(tp.mode, fallback: tp.isLinear ? .usb : .fm)
    }

    /// Receiver mode for a transponder's uplink. SatNOGS's `uplink_mode` wins when
    /// present. Otherwise the uplink mirrors the downlink, sideband-flipped on an
    /// inverting linear transponder.
    static func uplink(for tp: TransponderRecord, downlink dl: RigMode) -> RigMode {
        if let text = tp.uplinkMode, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return parse(text, fallback: dl)
        }
        guard tp.isLinear, tp.invert else { return dl }
        switch dl { case .usb: return .lsb; case .lsb: return .usb; default: return dl }
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
    let hasBluetooth: Bool  // native Icom BT CAT available
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
    /// For rigs without mode filter bytes (`modeFilter == false`) whose CI-V table
    /// still lists CW with one (IC-821H: CW = `06 03 01`, CW-N = `06 03 02`).
    var cwNeedsFilter = false
}

// MARK: - Radio catalog

enum RadioCatalog {
    /// Full-duplex satellite transceivers (MAIN/SUB), from CardSat RADIOS[].
    static let fullDuplex: [RadioSpec] = [
        civ("IC-820", 0x42, 9600, selMain: [0x07,0xD1], selSub: [0x07,0xD0], sat: false),
        // IC-821H manual p.42: mode bytes carry no filter byte except CW (06 03 01).
        civ("IC-821", 0x4C, 9600, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: false,
            modeFilter: false, cwFilter: true),
        civ("IC-910", 0x60, 19200, selMain: [0x07,0xD1], selSub: [0x07,0xD0], sat: true,
            satCmd: 0x1A, satSub: 0x07, tone: true, toneSub: 0x42, modeFilter: false, fmNarrow: 0x02),
        civ("IC-970", 0x2E, 9600, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: false,
            satCmd: 0x16, satSub: 0x5A),
        civ("IC-9100", 0x7C, 19200, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: true,
            satCmd: 0x16, satSub: 0x5A, tone: true, toneSub: 0x42, assignBand: true, fmNarrow: 0x02),
        civ("IC-9700", 0xA2, 19200, selMain: [0x07,0xD0], selSub: [0x07,0xD1], sat: true,
            satCmd: 0x16, satSub: 0x5A, tone: true, toneSub: 0x42, assignBand: true, lan: true, fmNarrow: 0x02),
        RadioSpec(id: "FT-847", name: "FT-847", family: .yaesuBinary, civAddr: 0, defaultBaud: 57600,
                  fullDuplex: true, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: true, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "FT-736R", name: "FT-736R", family: .yaesuFT736, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: true, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: false, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TS-790", name: "TS-790", family: .kenwoodBase, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: true, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TS-2000", name: "TS-2000", family: .kenwoodBase, civAddr: 0, defaultBaud: 57600,
                  fullDuplex: true, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: true, satModeCmd: 0, satModeSub: 0, hasTone: true, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
    ]

    /// Single-VFO ("leg") transceivers and receivers, from CardSat LEG_RADIOS[].
    /// Used for a half-duplex single radio (uplink or downlink) or a two-radio
    /// station. Excludes the FT-991/991A/FTX-1 (USB-only, unreachable on iOS).
    static let mono: [RadioSpec] = [
        // Icom CI-V transceivers
        civLeg("IC-705", 0xA4, 19200, lan: true, bluetooth: true),
        civLeg("IC-905", 0xAC, 19200, lan: true, bluetooth: true, wide: true),
        civLeg("IC-7100", 0x88, 19200),
        civLeg("IC-7000", 0x70, 19200, modeFilter: false, canRead: true),
        // IC-706 family: the CI-V filter byte is 0-based (00 wide / 01 normal / 02 narrow,
        // MKIIG manual), so the generic FIL1 = 01 isn't "default" there — omit it and let
        // the radio keep its own filter. The 2xx/4xx/575/1275 tables are unverified;
        // omitting the optional byte is the safe choice (Hamlib does for the IC-475).
        civLeg("IC-706MKIIG", 0x58, 9600, modeFilter: false),
        civLeg("IC-706MKII", 0x4E, 9600, modeFilter: false),
        civLeg("IC-706", 0x48, 9600, modeFilter: false),
        civLeg("IC-275", 0x10, 9600, modeFilter: false),
        civLeg("IC-475", 0x14, 9600, modeFilter: false),
        civLeg("IC-271", 0x20, 9600, modeFilter: false),
        civLeg("IC-471", 0x22, 9600, modeFilter: false),
        civLeg("IC-575", 0x16, 9600, modeFilter: false),
        civLeg("IC-1275", 0x18, 9600, modeFilter: false),
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
                  fullDuplex: false, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TS-811", name: "TS-811", family: .kenwoodBase, civAddr: 0, defaultBaud: 4800,
                  fullDuplex: false, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        // Kenwood handhelds via the B.B. Link BLE adapter (all-mode receiver on band B)
        RadioSpec(id: "TH-D74", name: "TH-D74", family: .kenwoodHandheld, civAddr: 0, defaultBaud: 9600,
                  fullDuplex: false, rxOnly: true, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false),
        RadioSpec(id: "TH-D75", name: "TH-D75", family: .kenwoodHandheld, civAddr: 0, defaultBaud: 9600,
                  fullDuplex: false, rxOnly: true, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
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
                                   fullDuplex: true, rxOnly: false, hasLan: false, hasBluetooth: false, canReadFreq: true, modeFilter: false,
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
                            lan: Bool = false, bluetooth: Bool = false, fmNarrow: UInt8 = 0, cwFilter: Bool = false) -> RadioSpec {
        RadioSpec(id: name, name: name, family: .civ, civAddr: addr, defaultBaud: baud,
                  fullDuplex: true, rxOnly: false, hasLan: lan, hasBluetooth: bluetooth, canReadFreq: true, modeFilter: modeFilter,
                  hasSatMode: sat, satModeCmd: satCmd, satModeSub: satSub, hasTone: tone, toneEncSub: toneSub,
                  selMain: selMain, selSub: selSub, canAssignBand: assignBand, wideFreq: false,
                  fmNarrowFilter: fmNarrow, cwNeedsFilter: cwFilter)
    }
    private static func civLeg(_ name: String, _ addr: UInt8, _ baud: Int,
                               rxOnly: Bool = false, lan: Bool = false, bluetooth: Bool = false, wide: Bool = false,
                               modeFilter: Bool = true, canRead: Bool = true) -> RadioSpec {
        RadioSpec(id: name, name: name, family: .civ, civAddr: addr, defaultBaud: baud,
                  fullDuplex: false, rxOnly: rxOnly, hasLan: lan, hasBluetooth: bluetooth, canReadFreq: canRead, modeFilter: modeFilter,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: wide)
    }
    private static func yaesuLeg(_ name: String, _ family: RigFamily, _ baud: Int,
                                 rxOnly: Bool = false, canRead: Bool = true) -> RadioSpec {
        RadioSpec(id: name, name: name, family: family, civAddr: 0, defaultBaud: baud,
                  fullDuplex: false, rxOnly: rxOnly, hasLan: false, hasBluetooth: false, canReadFreq: canRead, modeFilter: false,
                  hasSatMode: false, satModeCmd: 0, satModeSub: 0, hasTone: false, toneEncSub: 0,
                  selMain: [], selSub: [], canAssignBand: false, wideFreq: false)
    }
}

extension RadioSpec {
    /// Whether the radio can run single-radio split (VFO A receive / VFO B transmit
    /// with SPLIT on) over CAT. Per model, from the radios' CI-V/CAT references and
    /// Hamlib (sources listed per family below). rigctld has its own split toggle.
    var supportsSplit: Bool {
        guard !rxOnly else { return false }
        switch family {
        case .civ:          return Self.civSplitModels.contains(id)
        case .yaesuBinary:  return !fullDuplex      // FT-817/818/857/897 (not FT-847: no CAT split)
        case .yaesuFT100:   return true             // split 01, absolute VFO select 05 (Hamlib ft100.c)
        case .kenwoodBase:  return true             // TS-2000 FR/FT; TS-790/711/811 FN + SP
        default:            return false            // FT-736R (no same-band duplex), VR-5000, handhelds
        }
    }

    /// Icoms with CI-V split (`0F 01`) and VFO A/B (`07 00`/`07 01`):
    /// - IC-705, IC-905, IC-9700, IC-7100: CI-V reference guides.
    /// - IC-7000, IC-706MKIIG: manual command tables; IC-706/MKII: Hamlib ic706.c.
    /// - IC-9100, IC-910H: split on the MAIN band only, satellite mode off (manuals).
    /// - IC-821H: manual pp.26/42.
    /// Excluded: IC-275/475/575/1275/271/471 have no CI-V split command (N1MM,
    /// Hamlib); IC-820H/IC-970 are unverified.
    static let civSplitModels: Set<String> = ["IC-705", "IC-905", "IC-9700", "IC-7100", "IC-7000",
                                              "IC-706", "IC-706MKII", "IC-706MKIIG",
                                              "IC-9100", "IC-910", "IC-821"]

    /// CI-V 0x25/0x26: set the *unselected* VFO's frequency/mode directly, so split
    /// Doppler never has to swap VFOs (which would briefly move the receiver, and is
    /// unsafe mid-transmission). Older rigs fall back to 07 01 … 07 00 swaps. The
    /// IC-9700 accepts them on MAIN in VFO mode with satellite mode off.
    var civUnselectedVFO: Bool { ["IC-705", "IC-905", "IC-9700"].contains(id) }
    /// IC-7100: 0x25/0x26 arrived with firmware E4 (v1.10), so it's probed at engage
    /// (Hamlib's `x25x26_possibly`) and falls back to VFO swaps on older firmware.
    var civUnselectedVFOMaybe: Bool { id == "IC-7100" }

    /// Whether the radio accepts CI-V PTT (`1C 00`). The IC-706 family, IC-820/821H,
    /// IC-970 and the IC-2xx/4xx/575/1275 generation have no 1C command, so they key
    /// by VOX/PTT line only.
    var civHasPTT: Bool {
        family == .civ && !["IC-706", "IC-706MKII", "IC-706MKIIG", "IC-820", "IC-821", "IC-970",
                             "IC-275", "IC-475", "IC-271", "IC-471", "IC-575", "IC-1275"].contains(id)
    }

    /// Kenwood split dialect: the TS-2000 uses FR/FT (receive/transmit VFO); the
    /// TS-790/711/811 select the VFO with FN and switch split with SP.
    var kenwoodSplitFRFT: Bool { id == "TS-2000" }
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
    case bleicom    // ICOM rigs with native BT
    case network    // Icom RS-BA1 over Wi-Fi
    case rigctld    // Hamlib rigctld server over TCP
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ble: "BLE serial adapter"
        case .bleicom: "Icom built-in BT"
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
    /// Single-radio split: VFO A receives the downlink and VFO B transmits the uplink
    /// with the radio's SPLIT on, each Doppler-tracked. For same-band / same-frequency
    /// birds (packet digipeaters, ISS APRS) and plain non-satellite transceivers.
    /// Half duplex: the radio can't hear the satellite while transmitting.
    var splitVFO = false

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
    /// Split VFO on radios that must swap VFOs to reach VFO B (older Icoms, the
    /// FT-817 family, FT-100): each uplink write briefly moves the receiver, so the
    /// uplink only retunes once it has drifted this far (at least the normal deadband).
    var splitUplinkDeadbandHz = 500
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
        case splitVFO
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
        s.splitVFO = c.value(Bool.self, .splitVFO, s.splitVFO)
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
        try c.encode(splitVFO, forKey: .splitVFO)
    }
}

extension CATTuning {
    enum CK: String, CodingKey {
        case trackDoppler, updateMs, commandDelayMs, mainIsUplink, satMode, assignBands
        case fmDeadbandHz, linearDeadbandHz, narrowFM, leadMs, calDownlinkHz, calUplinkHz
        case xvtrDownlinkHz, xvtrUplinkHz, uplinkToneHz, passbandOffsetHz, followRadio, followLeg
        case followSettleMs, followUplinkResumeMs, rigctldUseSplit, splitUplinkDeadbandHz
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
        t.splitUplinkDeadbandHz = c.value(Int.self, .splitUplinkDeadbandHz, t.splitUplinkDeadbandHz)
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
        try c.encode(splitUplinkDeadbandHz, forKey: .splitUplinkDeadbandHz)
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
