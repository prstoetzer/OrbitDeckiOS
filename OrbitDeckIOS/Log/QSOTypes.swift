import Foundation

// ===========================================================================
//  QSOTypes.swift — QSO log data model
//
//  Ported from CardSat's PendingQso (src/app.h) with iOS-appropriate types. The
//  log is a flat array of these, persisted as JSON (see QSOStore) — no Core Data.
//  Uploads target LoTW (on-device TQ8 signing) and Cloudlog/Wavelog.
// ===========================================================================

/// Which services a QSO has been uploaded to (bit flags, matching CardSat).
struct UploadFlags: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int
    static let lotw = UploadFlags(rawValue: 1 << 0)
    static let cloudlog = UploadFlags(rawValue: 1 << 1)
}

/// One logged contact. Frequencies are Hz (uplink/downlink dial). `grid` may hold
/// several space/slash-separated grids for a rover (VUCC).
struct QSORecord: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var utc: Date
    var call = ""
    var sat = ""                 // satellite name (also the LoTW SAT_NAME source)
    var mode = "SSB"
    var dlHz: Int64 = 0          // downlink (RX) frequency
    var ulHz: Int64 = 0          // uplink (TX) frequency
    var myGrid = ""
    var myCall = ""
    var rstSent = ""
    var rstRcvd = ""
    var grid = ""                // worked station grid(s)
    var notes = ""
    var uploaded: UploadFlags = []
    // Added in 0.9.14 (tolerant decoding below keeps older logs loading).
    // Per-leg modes for cross-mode contacts (e.g. FM up / SSB down); nil means
    // "same as `mode`", which stays the primary for ADIF MODE, LoTW and Cloudlog.
    var uplinkMode: String?
    var downlinkMode: String?
    var name = ""                // worked operator's first name / nickname (QRZ fill)
    var dxcc: Int?               // ARRL DXCC entity code; nil = not resolved, 0 = none (/MM)
    var country = ""             // DXCC entity name
    // Added in 1.1 (tolerant decoding below). `state` is the worked station's ADIF
    // STATE (US state for WAS; other entities' primary subdivision as given), from the
    // editor, an ADIF import or QRZ. `memoFile` links a voice memo (a file under
    // Recordings) to a QSO stub logged with it. `lotwConfirmed` is LoTW QSL status as
    // imported from an ADIF (LOTW_QSL_RCVD) — the only confirmation source on device.
    var state = ""
    var memoFile: String?
    var lotwConfirmed = false

    /// Worked-station grids split for VUCC (comma/slash/space separated).
    var gridList: [String] {
        grid.split(whereSeparator: { ",/ ".contains($0) }).map { String($0).uppercased() }
    }

    var effectiveUplinkMode: String { uplinkMode ?? mode }
    var effectiveDownlinkMode: String { downlinkMode ?? mode }

    /// A voice-memo stub the operator hasn't completed yet (no callsign). Stubs are
    /// kept out of uploads and award totals until a call is entered.
    var isStub: Bool { call.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Which upload flags an edit from `old` to this record invalidates, so the QSO is
    /// sent again. LoTW signs only the contact fields (call, time, band/frequency, mode,
    /// satellite); Cloudlog gets the whole ADIF record, so any exported field counts.
    func uploadFlagsInvalidated(from old: QSORecord) -> UploadFlags {
        let lotwChanged = call != old.call || utc != old.utc || mode != old.mode || sat != old.sat
            || ulHz != old.ulHz || dlHz != old.dlHz
        if lotwChanged { return [.lotw, .cloudlog] }
        let adifChanged = rstSent != old.rstSent || rstRcvd != old.rstRcvd || grid != old.grid
            || myGrid != old.myGrid || myCall != old.myCall || name != old.name || dxcc != old.dxcc
            || country != old.country || state != old.state || notes != old.notes
            || uplinkMode != old.uplinkMode || downlinkMode != old.downlinkMode
        return adifChanged ? [.cloudlog] : []
    }
}

/// A recorded pass audio clip, listed on the Log screen (Phase 4 populates it).
struct RecordingEntry: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var sat = ""
    var start: Date
    var duration: TimeInterval = 0
    var filename = ""            // file under Application Support/Recordings
    var isMemo: Bool?            // a voice memo rather than pass audio (nil in older saves)
}

/// A decoded SSTV image, listed on the Log screen (Phase 5b populates it).
struct SSTVImageEntry: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var sat = ""
    var date: Date
    var mode = ""
    var filename = ""            // file under Application Support/SSTV
    // The pass audio captured during the live decode, so the image can be re-decoded
    // later with different slant/tuning (a full demod-domain fix, unlike the raster
    // editor). Optional keeps older saved blobs decodable. `audioRate` is the capture
    // rate the file was recorded at.
    var audioFile: String?
    var audioRate: Double?
    // Seconds into the recording where this image's transmission began, so a session
    // that decoded several images re-decodes the right one.
    var audioStartSec: Double?
}

/// One line of FT4 activity (a decode or our own transmission), persisted so the
/// full pass traffic can be reviewed later on the Log screen.
struct FT4TrafficEntry: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var date: Date               // UTC start of the slot
    var sat = ""
    var text = ""
    var snr = 0
    var freqHz = 0
    var sent = false             // true = our transmission
}

/// Station-location fields LoTW needs beyond the per-QSO data (see LoTW.swift).
/// US path: set `usState` (+ optional `usCounty` name). Non-US primary
/// subdivision: set `subdivField` (e.g. "CA_PROVINCE") and `subdiv` (the code).
struct LoTWStation: Codable, Sendable, Equatable {
    var call = ""
    var dxcc = ""
    var grid = ""
    var cqz = ""
    var ituz = ""
    var usState = ""             // US_STATE
    var usCounty = ""            // US_COUNTY — county NAME alone
    var subdivField = ""         // e.g. "CA_PROVINCE"
    var subdiv = ""              // subdivision code/value
    var iota = ""
    // Secondary subdivision other than the US county (today only JA_CITY_GUN_KU).
    var subdiv2Field = ""
    var subdiv2 = ""
}

/// Cloudlog / Wavelog JSON-API target (self-hosted). API key lives in the Keychain.
struct CloudlogConfig: Codable, Sendable, Equatable {
    var url = ""                 // base URL, e.g. https://host/index.php
    var stationProfileId = ""
}

/// Persisted logging settings (own UserDefaults key). Secrets (LoTW .p12
/// passphrase, Cloudlog key) are in the Keychain, never here.
struct LoggingConfig: Codable, Sendable, Equatable {
    var enabled = false
    var myCall = ""
    var defaultRst = "59"           // phone report; CW/data add the tone digit (see rst(for:))
    var station = LoTWStation()
    var cloudlog = CloudlogConfig()
    var hasLoTWCredential = false   // a .p12 has been imported into the app
    var qrzNameLookup = true        // fill empty names from QRZ (only when credentials are set)

    /// Default report for a mode: RS (59) for voice, RST (599) for CW and data,
    /// and empty for the WSJT modes, which log a dB report instead.
    func rst(for mode: String) -> String { Self.rst(for: mode, base: defaultRst) }

    static func rst(for mode: String, base: String) -> String {
        let m = mode.uppercased()
        if ["FT4", "FT8", "JS8", "MFSK", "Q65", "MSK144", "JT65", "JT9"].contains(m) { return "" }
        // Only reshape a plain RS/RST default; leave anything else (e.g. "-10") alone.
        let digits = base.filter(\.isNumber)
        guard digits == base, (2...3).contains(digits.count) else { return base }
        let rs = String(digits.prefix(2))
        let usesTone = ["CW", "PKT", "PACKET", "RTTY", "PSK", "PSK31", "PSK63", "BPSK", "FSK", "DATA",
                        "AFSK", "GMSK", "BPSK1200", "OLIVIA", "HELL", "DIGI"].contains(m)
        return usesTone ? rs + (digits.count == 3 ? String(digits.suffix(1)) : "9") : rs
    }
}

// MARK: - Tolerant Codable for the config structs (add fields without breaking saves)

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ def: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
    }
}

extension LoTWStation {
    enum CK: String, CodingKey { case call, dxcc, grid, cqz, ituz, usState, usCounty, subdivField, subdiv, iota, subdiv2Field, subdiv2 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var s = LoTWStation()
        s.call = c.value(String.self, .call, s.call)
        s.dxcc = c.value(String.self, .dxcc, s.dxcc)
        s.grid = c.value(String.self, .grid, s.grid)
        s.cqz = c.value(String.self, .cqz, s.cqz)
        s.ituz = c.value(String.self, .ituz, s.ituz)
        s.usState = c.value(String.self, .usState, s.usState)
        s.usCounty = c.value(String.self, .usCounty, s.usCounty)
        s.subdivField = c.value(String.self, .subdivField, s.subdivField)
        s.subdiv = c.value(String.self, .subdiv, s.subdiv)
        s.iota = c.value(String.self, .iota, s.iota)
        s.subdiv2Field = c.value(String.self, .subdiv2Field, s.subdiv2Field)
        s.subdiv2 = c.value(String.self, .subdiv2, s.subdiv2)
        self = s
    }
}

extension CloudlogConfig {
    enum CK: String, CodingKey { case url, stationProfileId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var s = CloudlogConfig()
        s.url = c.value(String.self, .url, s.url)
        s.stationProfileId = c.value(String.self, .stationProfileId, s.stationProfileId)
        self = s
    }
}

extension QSORecord {
    // Every field tolerant: QSOLog.json written by any earlier build (which lacks
    // the 0.9.14 fields) must keep loading, and one odd record must not sink the log.
    enum CK: String, CodingKey {
        case id, utc, call, sat, mode, dlHz, ulHz, myGrid, myCall, rstSent, rstRcvd, grid, notes, uploaded
        case uplinkMode, downlinkMode, name, dxcc, country
        case state, memoFile, lotwConfirmed
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var q = QSORecord(utc: c.value(Date.self, .utc, Date(timeIntervalSince1970: 0)))
        q.id = c.value(UUID.self, .id, q.id)
        q.call = c.value(String.self, .call, q.call)
        q.sat = c.value(String.self, .sat, q.sat)
        q.mode = c.value(String.self, .mode, q.mode)
        q.dlHz = c.value(Int64.self, .dlHz, q.dlHz)
        q.ulHz = c.value(Int64.self, .ulHz, q.ulHz)
        q.myGrid = c.value(String.self, .myGrid, q.myGrid)
        q.myCall = c.value(String.self, .myCall, q.myCall)
        q.rstSent = c.value(String.self, .rstSent, q.rstSent)
        q.rstRcvd = c.value(String.self, .rstRcvd, q.rstRcvd)
        q.grid = c.value(String.self, .grid, q.grid)
        q.notes = c.value(String.self, .notes, q.notes)
        q.uploaded = c.value(UploadFlags.self, .uploaded, q.uploaded)
        q.uplinkMode = (try? c.decodeIfPresent(String.self, forKey: .uplinkMode)) ?? nil
        q.downlinkMode = (try? c.decodeIfPresent(String.self, forKey: .downlinkMode)) ?? nil
        q.name = c.value(String.self, .name, q.name)
        q.dxcc = (try? c.decodeIfPresent(Int.self, forKey: .dxcc)) ?? nil
        q.country = c.value(String.self, .country, q.country)
        q.state = c.value(String.self, .state, q.state)
        q.memoFile = (try? c.decodeIfPresent(String.self, forKey: .memoFile)) ?? nil
        q.lotwConfirmed = c.value(Bool.self, .lotwConfirmed, q.lotwConfirmed)
        self = q
    }
}

extension LoggingConfig {
    enum CK: String, CodingKey { case enabled, myCall, defaultRst, station, cloudlog, hasLoTWCredential, qrzNameLookup }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var s = LoggingConfig()
        s.enabled = c.value(Bool.self, .enabled, s.enabled)
        s.myCall = c.value(String.self, .myCall, s.myCall)
        s.defaultRst = c.value(String.self, .defaultRst, s.defaultRst)
        s.station = c.value(LoTWStation.self, .station, s.station)
        s.cloudlog = c.value(CloudlogConfig.self, .cloudlog, s.cloudlog)
        s.hasLoTWCredential = c.value(Bool.self, .hasLoTWCredential, s.hasLoTWCredential)
        s.qrzNameLookup = c.value(Bool.self, .qrzNameLookup, s.qrzNameLookup)
        self = s
    }
}
