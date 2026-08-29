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
        qsos = load([QSORecord].self, "QSOLog.json") ?? []
        recordings = load([RecordingEntry].self, "Recordings.json") ?? []
        sstvImages = load([SSTVImageEntry].self, "SSTVImages.json") ?? []
        ft4Traffic = load([FT4TrafficEntry].self, "FT4Traffic.json") ?? []
    }

    func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: QSOs

    func add(_ q: QSORecord) { qsos.insert(q, at: 0); saveQSOs() }
    func update(_ q: QSORecord) {
        if let i = qsos.firstIndex(where: { $0.id == q.id }) { qsos[i] = q; saveQSOs() }
    }
    func delete(_ q: QSORecord) { qsos.removeAll { $0.id == q.id }; saveQSOs() }
    func delete(at offsets: IndexSet) { qsos.remove(atOffsets: offsets); saveQSOs() }

    func countUnuploaded(_ flag: UploadFlags) -> Int { qsos.filter { !$0.uploaded.contains(flag) }.count }

    private func saveQSOs() { save(qsos, "QSOLog.json") }

    // MARK: Media indexes (populated by Phase 4 / 5b)

    func addRecording(_ r: RecordingEntry) { recordings.insert(r, at: 0); save(recordings, "Recordings.json") }
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
        save(sstvImages, "SSTVImages.json")
    }

    // MARK: ADIF import/export

    func adifExport() -> String { ADIF.export(qsos) }

    @discardableResult
    func adifImport(_ text: String) -> Int {
        let parsed = ADIF.parse(text)
        guard !parsed.isEmpty else { return 0 }
        qsos.insert(contentsOf: parsed, at: 0)
        saveQSOs()
        return parsed.count
    }

    // MARK: Uploads

    /// Sign + upload all not-yet-LoTW'd QSOs; mark them on success. Returns a
    /// human-readable status.
    func uploadLoTW() async -> String {
        let pending = qsos.filter { !$0.uploaded.contains(.lotw) }
        guard !pending.isEmpty else { return "Nothing to upload — all QSOs already sent to LoTW." }
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

    /// Upload all not-yet-Cloudlog'd QSOs; mark them on success.
    func uploadCloudlog() async -> String {
        let pending = qsos.filter { !$0.uploaded.contains(.cloudlog) }
        guard !pending.isEmpty else { return "Nothing to upload — all QSOs already sent to Cloudlog." }
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
        let url = Self.appSupport.appendingPathComponent(name)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
