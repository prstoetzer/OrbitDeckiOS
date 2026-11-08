import Foundation
import Combine

// ===========================================================================
//  QSOStore.swift — the QSO log + recordings/SSTV index + uploads
//
//  A @MainActor ObservableObject holding the log (JSON file), the recording and
//  SSTV image indexes, and the logging configuration (own UserDefaults key).
//  Orchestrates LoTW and Cloudlog uploads, marking each QSO's upload flags on
//  success. Secrets stay in the Keychain (OrbitSecretStore).
// ===========================================================================

@MainActor
final class QSOStore: ObservableObject {
    @Published var qsos: [QSORecord] = []
    @Published var recordings: [RecordingEntry] = []
    @Published var sstvImages: [SSTVImageEntry] = []
    @Published var ft4Traffic: [FT4TrafficEntry] = []
    @Published var config = LoggingConfig()

    /// Cap on the persisted FT4 activity log (oldest lines drop off).
    private static let ft4TrafficCap = 4000

    private static let configKey = "orbitdeck.loggingConfig"

    // MARK: Lifecycle

    func attach() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(LoggingConfig.self, from: data) {
            config = saved
        }
        // Keep the credential flag honest with what's actually on disk.
        config.hasLoTWCredential = LoTW.hasCredential()
        // A station location set up before the entity picker existed may have a US state
        // but no DXCC; it was always meant as the USA, so store that (the picker showed it
        // as the USA, and the LoTW upload needs the entity, not just the display).
        if config.station.dxcc.trimmingCharacters(in: .whitespaces).isEmpty,
           !config.station.usState.trimmingCharacters(in: .whitespaces).isEmpty {
            config.station.dxcc = "291"
            persistConfig()
        }
        qsos = load([QSORecord].self, "QSOLog.json") ?? []
        recordings = load([RecordingEntry].self, "Recordings.json") ?? []
        sstvImages = load([SSTVImageEntry].self, "SSTVImages.json") ?? []
        ft4Traffic = load([FT4TrafficEntry].self, "FT4Traffic.json") ?? []
        backfillDXCCOnce()
    }

    func persistConfig() {
        guard !FactoryResetService.didReset else { return }
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: QSOs

    // Every logging path (Home card, editor, FT4 and packet auto-log) goes through
    // add/update, so the DXCC fill and QRZ name lookup live here (ADIF import fills
    // DXCC itself and deliberately skips QRZ, which would flood it for a big file).
    func add(_ q: QSORecord) {
        var q = q
        Self.fillDXCC(&q)
        qsos.insert(q, at: 0); saveQSOs()
        requestName(for: q)
    }
    /// Replace a QSO. Unless `keepUploadFlags` (the editor's flag toggles were set by
    /// hand), changing a field an upload carries clears that service's uploaded flag so
    /// the corrected QSO is sent again.
    func update(_ q: QSORecord, keepUploadFlags: Bool = false) {
        var q = q
        Self.fillDXCC(&q)
        guard let i = qsos.firstIndex(where: { $0.id == q.id }) else { return }
        if !keepUploadFlags { q.uploaded.subtract(q.uploadFlagsInvalidated(from: qsos[i])) }
        qsos[i] = q; saveQSOs(); requestName(for: q)
    }
    func delete(_ q: QSORecord) { qsos.removeAll { $0.id == q.id }; saveQSOs() }
    func delete(at offsets: IndexSet) { qsos.remove(atOffsets: offsets); saveQSOs() }
    func delete(ids: Set<UUID>) { qsos.removeAll { ids.contains($0.id) }; saveQSOs() }

    /// Clear an upload flag on the given QSOs (all when nil) so the next upload re-sends them.
    func clearUploaded(_ flag: UploadFlags, ids: Set<UUID>? = nil) {
        for i in qsos.indices where ids?.contains(qsos[i].id) ?? true { qsos[i].uploaded.remove(flag) }
        saveQSOs()
    }

    // Stubs (voice-memo QSOs without a call yet) are never uploaded.
    func countUnuploaded(_ flag: UploadFlags) -> Int { qsos.filter { !$0.isStub && !$0.uploaded.contains(flag) }.count }

    private func saveQSOs() { save(qsos, "QSOLog.json") }

    // MARK: Media indexes (populated by Phase 4 / 5b)

    func addRecording(_ r: RecordingEntry) { recordings.insert(r, at: 0); save(recordings, "Recordings.json") }

    /// Register a finished voice memo and log the QSO stub that goes with it (the stub
    /// carries the memo's filename; the operator completes the contact later).
    func addVoiceMemo(_ r: RecordingEntry, stub: QSORecord) {
        addRecording(r)
        var q = stub
        q.memoFile = r.filename
        if q.notes.isEmpty { q.notes = "Voice memo" }
        add(q)
    }
    func deleteRecording(_ r: RecordingEntry) {
        recordings.removeAll { $0.id == r.id }
        try? FileManager.default.removeItem(at: Self.recordingsDir.appendingPathComponent(r.filename))
        save(recordings, "Recordings.json")
    }
    /// Append a batch of FT4 activity lines (once per slot) and persist, oldest-first
    /// with a cap. Batched so we write the JSON at most once per 7.5 s slot.
    func addFT4Traffic(_ entries: [FT4TrafficEntry]) {
        guard !entries.isEmpty else { return }
        ft4Traffic.append(contentsOf: entries)
        if ft4Traffic.count > Self.ft4TrafficCap { ft4Traffic.removeFirst(ft4Traffic.count - Self.ft4TrafficCap) }
        save(ft4Traffic, "FT4Traffic.json")
    }
    func clearFT4Traffic() { ft4Traffic.removeAll(); save(ft4Traffic, "FT4Traffic.json") }

    func addSSTVImage(_ s: SSTVImageEntry) { sstvImages.insert(s, at: 0); save(sstvImages, "SSTVImages.json") }
    func deleteSSTVImage(_ s: SSTVImageEntry) {
        sstvImages.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: Self.sstvDir.appendingPathComponent(s.filename))
        // Remove the captured re-decode audio unless another image still references it
        // (multiple images from one listening session share the recording).
        if let audio = s.audioFile, !sstvImages.contains(where: { $0.audioFile == audio }) {
            try? FileManager.default.removeItem(at: Self.sstvDir.appendingPathComponent(audio))
        }
        save(sstvImages, "SSTVImages.json")
    }

    // MARK: ADIF import/export

    // Memo stubs without a call would be invalid ADIF records; they stay on device.
    func adifExport() -> String { ADIF.export(qsos.filter { !$0.isStub }) }

    /// Outcome of an ADIF import: records added as new QSOs, existing QSOs updated
    /// (LoTW confirmation or empty fields filled) and records that matched an existing
    /// QSO with nothing new to add.
    struct ImportResult: Equatable {
        var added = 0
        var updated = 0
        var unchanged = 0
    }

    /// Import an ADIF file. A record that matches a QSO already in the log (same base
    /// call, same satellite, same mode family, within ±2 min) is merged instead of
    /// inserted — so importing a LoTW confirmations download marks the logged QSOs
    /// confirmed rather than duplicating them. Unmatched records are added.
    @discardableResult
    func adifImport(_ text: String) -> ImportResult {
        var parsed = ADIF.parse(text)
        var result = ImportResult()
        guard !parsed.isEmpty else { return result }
        for i in parsed.indices { Self.fillDXCC(&parsed[i]) }

        // Index the existing log by base call so matching stays linear-ish for big files.
        var byCall: [String: [Int]] = [:]
        for (i, q) in qsos.enumerated() where !q.isStub {
            byCall[DXCCLookup.baseCall(q.call), default: []].append(i)
        }
        var added: [QSORecord] = []
        for record in parsed {
            let call = DXCCLookup.baseCall(record.call)
            let match = call.isEmpty ? nil : (byCall[call] ?? [])
                .filter { Self.importMatches(qsos[$0], record) }
                .min { abs(qsos[$0].utc.timeIntervalSince(record.utc)) < abs(qsos[$1].utc.timeIntervalSince(record.utc)) }
            guard let i = match else { added.append(record); continue }
            if Self.merge(record, into: &qsos[i]) { result.updated += 1 } else { result.unchanged += 1 }
        }
        result.added = added.count
        if !added.isEmpty { qsos.insert(contentsOf: added, at: 0) }
        if result.added > 0 || result.updated > 0 { saveQSOs() }
        return result
    }

    /// Whether an imported record is the same contact as a logged QSO (base call is
    /// compared by the caller).
    private static func importMatches(_ q: QSORecord, _ r: QSORecord) -> Bool {
        abs(q.utc.timeIntervalSince(r.utc)) <= 120
            && normalizedSat(q.sat) == normalizedSat(r.sat)
            && modeFamily(q.mode) == modeFamily(r.mode)
    }

    /// Satellite name in LoTW's naming (so "FOX-1B (AO-91)" matches "AO-91"), without
    /// case, spaces or hyphens.
    private static func normalizedSat(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return LoTWSatName.resolve(trimmed).uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// LoTW's mode groups: phone, CW and data (everything else).
    private static func modeFamily(_ mode: String) -> String {
        let m = mode.uppercased()
        if m == "CW" { return "CW" }
        if ["SSB", "USB", "LSB", "FM", "FM-N", "FMN", "AM", "DV", "PHONE", "C4FM", "DSTAR"].contains(m) { return "PHONE" }
        return "DATA"
    }

    /// Merge an imported record into a matching QSO: take the LoTW confirmation and
    /// fill fields the log doesn't have yet. Never overwrites what the operator logged
    /// and keeps the upload flags. Returns whether anything changed.
    private static func merge(_ r: QSORecord, into q: inout QSORecord) -> Bool {
        let before = q
        if r.lotwConfirmed { q.lotwConfirmed = true }
        if q.state.isEmpty { q.state = r.state }
        if q.grid.isEmpty { q.grid = r.grid }
        if q.name.isEmpty { q.name = r.name }
        if q.dxcc == nil, let dxcc = r.dxcc {
            q.dxcc = dxcc
            if q.country.isEmpty { q.country = r.country }
        }
        return q != before
    }

    // MARK: DXCC entity

    /// Resolve the worked station's DXCC entity from its callsign when not yet set
    /// (an ADIF import or the editor may already have supplied one).
    static func fillDXCC(_ q: inout QSORecord) {
        guard q.dxcc == nil, let match = DXCCLookup.entity(for: q.call) else { return }
        q.dxcc = match.code
        if q.country.isEmpty { q.country = match.name }
    }

    private static let dxccBackfillKey = "orbitdeck.qsoDXCCBackfill.v1"

    /// One-time pass giving QSOs logged before the DXCC field existed an entity.
    private func backfillDXCCOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.dxccBackfillKey) else { return }
        var changed = false
        for i in qsos.indices where qsos[i].dxcc == nil {
            Self.fillDXCC(&qsos[i])
            changed = changed || qsos[i].dxcc != nil
        }
        if changed { saveQSOs() }
        UserDefaults.standard.set(true, forKey: Self.dxccBackfillKey)
    }

    // MARK: QRZ name / state lookup

    // Fills an empty `name` (and, for US contacts, an empty `state`) from QRZ XML in the
    // background: one request at a time, at most one per second, results cached in
    // memory for the session (including "nothing"), and a back-off after login/network
    // failures. Logging never waits.
    private struct QRZFill { var name = ""; var state = "" }
    private let qrz = QRZService()
    private var nameCache: [String: QRZFill] = [:]    // base call → QRZ name/state
    private var nameQueue: [UUID] = []
    private var nameWorker: Task<Void, Never>?
    private var lastQRZRequest: Date?
    private var qrzBackoffUntil: Date?

    /// QRZ XML username (Settings, stored in the main preferences blob) and the
    /// Keychain password, or nil when either is missing.
    func qrzCredentials() -> (username: String, password: String)? {
        struct Prefs: Decodable { var qrzUsername: String? }
        guard let data = UserDefaults.standard.data(forKey: "OrbitDeckIOS.preferences.v1"),
              let user = (try? JSONDecoder().decode(Prefs.self, from: data))?.qrzUsername?
                .trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else { return nil }
        let password = OrbitSecretStore.get(.qrzPassword)
        return password.isEmpty ? nil : (user, password)
    }

    /// DXCC entities whose STATE is a US state (WAS): USA, Alaska, Hawaii.
    nonisolated static let usEntities: Set<Int> = [291, 6, 110]

    /// Whether QRZ could still add something to this QSO.
    private func needsLookup(_ q: QSORecord) -> Bool {
        q.name.isEmpty || (q.state.isEmpty && Self.usEntities.contains(q.dxcc ?? -1))
    }

    private func requestName(for q: QSORecord) {
        guard config.qrzNameLookup, needsLookup(q) else { return }
        let call = DXCCLookup.baseCall(q.call)
        guard call.count >= 3 else { return }
        if let cached = nameCache[call] { applyLookup(cached, to: q.id, call: call); return }
        if let until = qrzBackoffUntil, until > Date() { return }
        guard qrzCredentials() != nil else { return }
        if !nameQueue.contains(q.id) { nameQueue.append(q.id) }
        if nameWorker == nil { nameWorker = Task { await drainNameQueue() } }
    }

    /// Queue every US contact without a state for a QRZ lookup (for WAS). Returns how
    /// many were queued; they fill in at one lookup per second.
    @discardableResult
    func fillMissingStatesFromQRZ() -> Int {
        guard config.qrzNameLookup, qrzCredentials() != nil else { return 0 }
        qrzBackoffUntil = nil
        let pending = qsos.filter { !$0.isStub && $0.state.isEmpty && Self.usEntities.contains($0.dxcc ?? -1) }
        for q in pending { requestName(for: q) }
        return pending.count
    }

    private func drainNameQueue() async {
        defer { nameWorker = nil }
        while !nameQueue.isEmpty {
            let id = nameQueue.removeFirst()
            guard let q = qsos.first(where: { $0.id == id }), needsLookup(q), config.qrzNameLookup else { continue }
            let call = DXCCLookup.baseCall(q.call)
            if let cached = nameCache[call] { applyLookup(cached, to: id, call: call); continue }
            guard let creds = qrzCredentials() else { nameQueue.removeAll(); return }
            if let last = lastQRZRequest {
                let wait = 1.0 - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            lastQRZRequest = Date()
            do {
                let info = try await qrz.operatorInfo(username: creds.username, password: creds.password, callsign: call)
                let fill = QRZFill(name: info.name, state: info.state)
                nameCache[call] = fill
                applyLookup(fill, to: id, call: call)
            } catch let error as NSError where error.domain == "QRZ" && error.code == 2 {
                nameCache[call] = QRZFill()              // not on QRZ: don't ask again this session
            } catch {
                // Bad credentials or no network: stop and wait before trying again.
                let ns = error as NSError
                let credentialProblem = ns.domain == "QRZ" && ns.code == 1
                qrzBackoffUntil = Date().addingTimeInterval(credentialProblem ? 600 : 60)
                nameQueue.removeAll()
                return
            }
        }
    }

    /// Store a looked-up name / state unless the operator has since typed one or changed
    /// the call. The state is only taken for a US contact and only when it's a real
    /// US state code (QRZ also returns provinces and free text for other countries).
    private func applyLookup(_ fill: QRZFill, to id: UUID, call: String) {
        guard let i = qsos.firstIndex(where: { $0.id == id }), DXCCLookup.baseCall(qsos[i].call) == call else { return }
        var changed = false
        if !fill.name.isEmpty, qsos[i].name.isEmpty { qsos[i].name = fill.name; changed = true }
        if qsos[i].state.isEmpty, Self.usEntities.contains(qsos[i].dxcc ?? -1), LogAwards.usStateCodes.contains(fill.state) {
            qsos[i].state = fill.state; changed = true
        }
        if changed { saveQSOs() }
    }

    /// Factory reset: stop the QRZ worker and, unless the log is kept, drop the log and
    /// media indexes from memory so nothing on screen or in flight refers to deleted files.
    func prepareForFactoryReset(keepLog: Bool) {
        nameWorker?.cancel(); nameWorker = nil
        nameQueue.removeAll()
        config = LoggingConfig()
        guard !keepLog else { return }
        qsos = []; recordings = []; sstvImages = []; ft4Traffic = []
    }

    // MARK: Uploads

    /// Sign + upload the not-yet-LoTW'd QSOs (or, with `ids`, exactly those QSOs,
    /// already-uploaded or not — the "re-send" path); mark them on success. Stubs
    /// without a callsign are never sent. Returns a human-readable status.
    func uploadLoTW(ids: Set<UUID>? = nil) async -> String {
        let pending = qsos.filter { q in !q.isStub && (ids.map { $0.contains(q.id) } ?? !q.uploaded.contains(.lotw)) }
        guard !pending.isEmpty else {
            return ids == nil ? "Nothing to upload — all QSOs already sent to LoTW." : "No QSOs with a callsign to send."
        }
        let station = config.station
        do {
            // Sign + gzip off the main actor — RSA signing every QSO on the main
            // thread would freeze the UI for a large log.
            let tq8 = try await Task.detached(priority: .userInitiated) {
                try LoTW.buildTQ8(pending, station: station)
            }.value
            let result = try await LoTW.upload(tq8)
            if result.ok {
                mark(pending, flag: .lotw)
                return "Uploaded \(pending.count) QSO(s) to LoTW."
            }
            return "LoTW response: \(result.message)"
        } catch {
            return error.localizedDescription
        }
    }

    /// Upload the not-yet-Cloudlog'd QSOs (or exactly `ids`, re-sending); mark them on success.
    func uploadCloudlog(ids: Set<UUID>? = nil) async -> String {
        let pending = qsos.filter { q in !q.isStub && (ids.map { $0.contains(q.id) } ?? !q.uploaded.contains(.cloudlog)) }
        guard !pending.isEmpty else {
            return ids == nil ? "Nothing to upload — all QSOs already sent to Cloudlog." : "No QSOs with a callsign to send."
        }
        let key = OrbitSecretStore.get(.cloudlogKey)
        do {
            let n = try await Cloudlog.upload(pending, config: config.cloudlog, apiKey: key)
            mark(pending, flag: .cloudlog)
            return "Uploaded \(n) QSO(s) to Cloudlog."
        } catch {
            return error.localizedDescription
        }
    }

    private func mark(_ subset: [QSORecord], flag: UploadFlags) {
        let ids = Set(subset.map(\.id))
        for i in qsos.indices where ids.contains(qsos[i].id) { qsos[i].uploaded.insert(flag) }
        saveQSOs()
    }

    // MARK: File storage

    static var appSupport: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir
    }
    static var recordingsDir: URL { subdir("Recordings") }
    static var sstvDir: URL { subdir("SSTV") }

    private static func subdir(_ name: String) -> URL {
        let url = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = Self.appSupport.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard !FactoryResetService.didReset else { return }
        let url = Self.appSupport.appendingPathComponent(name)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Awards

/// Worked (and, where the log carries LoTW QSL status, confirmed) award totals
/// computed from the log: QSOs, satellites, VUCC grids, WAS states (50 + DC) and
/// DXCC entities, overall and per satellite. Recomputed on demand — it's a pass over
/// an in-memory array. Voice-memo stubs without a call are left out.
///
/// States come only from each QSO's STATE field (editor, ADIF import or QRZ); they
/// are never guessed from a grid, since a grid square can straddle state lines.
struct LogAwards {
    struct Tally {
        var qsos = 0
        var grids: Set<String> = []
        var states: Set<String> = []
        var dxcc: Set<Int> = []
        var confirmedGrids: Set<String> = []
        var confirmedStates: Set<String> = []
        var confirmedDXCC: Set<Int> = []
        var confirmedQSOs = 0
    }

    struct SatelliteTally: Identifiable {
        let name: String
        var tally = Tally()
        var id: String { name }
    }

    var all = Tally()
    var satellites: [SatelliteTally] = []     // most QSOs first
    /// The log has LoTW QSL data (any QSO marked confirmed), so "confirmed" is meaningful.
    var hasConfirmations = false
    /// US contacts with no STATE, which can't count toward WAS until one is set.
    var usWithoutState = 0

    static let wasTotal = 51                  // 50 states + DC
    static let usStateCodes: Set<String> = Set(LoTWSubdivisions.usStates.map(\.code))

    /// VUCC credits the 4-character grid field; anything not shaped like one is skipped.
    static func vuccGrid(_ raw: String) -> String? {
        let g = Array(raw.uppercased().unicodeScalars.prefix(4))
        guard g.count == 4, ("A"..."R").contains(g[0]), ("A"..."R").contains(g[1]),
              ("0"..."9").contains(g[2]), ("0"..."9").contains(g[3]) else { return nil }
        return String(String.UnicodeScalarView(g))
    }

    static func stateName(_ code: String) -> String {
        LoTWSubdivisions.usStates.first { $0.code == code }?.name ?? code
    }

    static func entityName(_ code: Int) -> String {
        DXCCNumericData.nameByCode[code] ?? LoTWSubdivisions.entity(code)?.name.capitalized ?? "DXCC \(code)"
    }

    init(_ qsos: [QSORecord]) {
        var bySat: [String: SatelliteTally] = [:]
        for q in qsos where !q.isStub {
            let sat = q.sat.trimmingCharacters(in: .whitespaces).isEmpty ? "(no satellite)" : q.sat.trimmingCharacters(in: .whitespaces)
            let grids = Set(q.gridList.compactMap(Self.vuccGrid))
            let st = q.state.trimmingCharacters(in: .whitespaces).uppercased()
            // A US state only for a US entity (or an unresolved one), and only a real code.
            let isUS = q.dxcc.map { QSOStore.usEntities.contains($0) } ?? true
            let state: String? = (isUS && Self.usStateCodes.contains(st)) ? st : nil
            if state == nil, st.isEmpty, let d = q.dxcc, QSOStore.usEntities.contains(d) { usWithoutState += 1 }
            let entity: Int? = (q.dxcc ?? 0) > 0 ? q.dxcc : nil
            if q.lotwConfirmed { hasConfirmations = true }

            func add(_ t: inout Tally) {
                t.qsos += 1
                t.grids.formUnion(grids)
                if let state { t.states.insert(state) }
                if let entity { t.dxcc.insert(entity) }
                if q.lotwConfirmed {
                    t.confirmedQSOs += 1
                    t.confirmedGrids.formUnion(grids)
                    if let state { t.confirmedStates.insert(state) }
                    if let entity { t.confirmedDXCC.insert(entity) }
                }
            }
            add(&all)
            let key = sat.uppercased()
            var s = bySat[key] ?? SatelliteTally(name: sat)
            add(&s.tally)
            bySat[key] = s
        }
        satellites = bySat.values.sorted { $0.tally.qsos != $1.tally.qsos ? $0.tally.qsos > $1.tally.qsos : $0.name < $1.name }
    }

    // MARK: Export

    /// CSV: a totals block, then one row per worked grid / state / entity (with the
    /// satellites it was worked on), then the per-satellite tally.
    func csv() -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "Award,Worked,Confirmed\n"
        out += "QSOs,\(all.qsos),\(hasConfirmations ? String(all.confirmedQSOs) : "")\n"
        out += "Satellites,\(satellites.count),\n"
        out += "VUCC grids,\(all.grids.count),\(hasConfirmations ? String(all.confirmedGrids.count) : "")\n"
        out += "WAS states (of \(Self.wasTotal)),\(all.states.count),\(hasConfirmations ? String(all.confirmedStates.count) : "")\n"
        out += "DXCC entities,\(all.dxcc.count),\(hasConfirmations ? String(all.confirmedDXCC.count) : "")\n"
        out += "\nType,Item,Name,Confirmed,Satellites\n"
        func sats(_ has: (Tally) -> Bool) -> String { esc(satellites.filter { has($0.tally) }.map(\.name).joined(separator: "; ")) }
        for g in all.grids.sorted() {
            out += "Grid,\(g),,\(all.confirmedGrids.contains(g) ? "Y" : "N"),\(sats { $0.grids.contains(g) })\n"
        }
        for s in all.states.sorted() {
            out += "State,\(s),\(esc(Self.stateName(s))),\(all.confirmedStates.contains(s) ? "Y" : "N"),\(sats { $0.states.contains(s) })\n"
        }
        for d in all.dxcc.sorted(by: { Self.entityName($0) < Self.entityName($1) }) {
            out += "DXCC,\(d),\(esc(Self.entityName(d))),\(all.confirmedDXCC.contains(d) ? "Y" : "N"),\(sats { $0.dxcc.contains(d) })\n"
        }
        out += "\nSatellite,QSOs,Grids,States,DXCC\n"
        for s in satellites {
            out += "\(esc(s.name)),\(s.tally.qsos),\(s.tally.grids.count),\(s.tally.states.count),\(s.tally.dxcc.count)\n"
        }
        return out
    }
}
