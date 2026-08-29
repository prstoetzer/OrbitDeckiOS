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

    /// Worked-station grids split for VUCC (comma/slash/space separated).
    var gridList: [String] {
        grid.split(whereSeparator: { ",/ ".contains($0) }).map { String($0).uppercased() }
    }
}

/// A recorded pass audio clip, listed on the Log screen (Phase 4 populates it).
struct RecordingEntry: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var sat = ""
    var start: Date
    var duration: TimeInterval = 0
    var filename = ""            // file under Application Support/Recordings
}

/// A decoded SSTV image, listed on the Log screen (Phase 5b populates it).
struct SSTVImageEntry: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var sat = ""
    var date: Date
    var mode = ""
    var filename = ""            // file under Application Support/SSTV
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
    var defaultRst = "59"
    var station = LoTWStation()
    var cloudlog = CloudlogConfig()
    var hasLoTWCredential = false   // a .p12 has been imported into the app
}

// MARK: - Tolerant Codable for the config structs (add fields without breaking saves)

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ def: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
    }
}

extension LoTWStation {
    enum CK: String, CodingKey { case call, dxcc, grid, cqz, ituz, usState, usCounty, subdivField, subdiv, iota }
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

extension LoggingConfig {
    enum CK: String, CodingKey { case enabled, myCall, defaultRst, station, cloudlog, hasLoTWCredential }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        var s = LoggingConfig()
        s.enabled = c.value(Bool.self, .enabled, s.enabled)
        s.myCall = c.value(String.self, .myCall, s.myCall)
        s.defaultRst = c.value(String.self, .defaultRst, s.defaultRst)
        s.station = c.value(LoTWStation.self, .station, s.station)
        s.cloudlog = c.value(CloudlogConfig.self, .cloudlog, s.cloudlog)
        s.hasLoTWCredential = c.value(Bool.self, .hasLoTWCredential, s.hasLoTWCredential)
        self = s
    }
}
