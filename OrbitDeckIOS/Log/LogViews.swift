import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// ===========================================================================
//  LogViews.swift — Log screen, QSO editor, Log settings, Home quick-log card
// ===========================================================================

// MARK: - Prefill helper

extension QSORecord {
    /// A new QSO prefilled from the current satellite/transponder/station, like
    /// CardSat's quick-log.
    static func prefilled(satellite: SatelliteRecord?, transponder: TransponderRecord?,
                          myGrid: String, myCall: String, defaultRst: String, now: Date = Date()) -> QSORecord {
        var q = QSORecord(utc: now)
        q.sat = satellite?.name ?? ""
        if let tp = transponder {
            q.dlHz = tp.downlinkCenter
            q.ulHz = tp.uplinkCenter
            q.mode = adifMode(tp.mode)
        }
        q.myGrid = myGrid
        q.myCall = myCall
        q.rstSent = defaultRst
        q.rstRcvd = defaultRst
        return q
    }

    /// Map a transponder mode string to an ADIF MODE.
    static func adifMode(_ raw: String) -> String {
        let t = raw.uppercased()
        if t.contains("FM") { return "FM" }
        if t.contains("CW") { return "CW" }
        if t.contains("USB") || t.contains("LSB") || t.contains("SSB") { return "SSB" }
        if t.contains("FT4") { return "FT4" }
        if t.contains("FT8") { return "FT8" }
        return raw.isEmpty ? "SSB" : raw
    }
}

// MARK: - Home quick-log card

struct HomeQuickLogCard: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    let satellite: SatelliteRecord

    @State private var call = ""
    @State private var rstSent = "59"
    @State private var rstRcvd = "59"
    @State private var theirGrid = ""
    @State private var justLogged = false

    var body: some View {
        if qso.config.enabled {
            SectionCard("Log QSO") {
                MetricRow("Satellite", satellite.name)
                TextField("Call", text: $call)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
                HStack {
                    TextField("RST sent", text: $rstSent).textFieldStyle(.odField).frame(maxWidth: .infinity)
                    TextField("RST rcvd", text: $rstRcvd).textFieldStyle(.odField).frame(maxWidth: .infinity)
                }
                TextField("Their grid (optional)", text: $theirGrid)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.odField)
                Button {
                    logIt()
                } label: {
                    Label(justLogged ? "Logged ✓" : "Log QSO", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(call.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Saved to the Log. Upload to LoTW / Cloudlog from the Log screen.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func logIt() {
        var q = QSORecord.prefilled(satellite: satellite, transponder: rig.transponder(for: satellite),
                                    myGrid: store.operatorGrid6, myCall: qso.config.myCall,
                                    defaultRst: qso.config.defaultRst)
        q.call = call.trimmingCharacters(in: .whitespaces).uppercased()
        q.rstSent = rstSent; q.rstRcvd = rstRcvd
        q.grid = theirGrid.trimmingCharacters(in: .whitespaces).uppercased()
        qso.add(q)
        call = ""; theirGrid = ""; rstSent = qso.config.defaultRst; rstRcvd = qso.config.defaultRst
        justLogged = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); justLogged = false }
    }
}

// MARK: - Log screen

struct LogScreen: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore

    @State private var editing: QSORecord?
    @State private var showingNew = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var status: String?
    @State private var working = false
    @StateObject private var player = RecordingPlayer()

    var body: some View {
        List {
            if qso.qsos.isEmpty && qso.recordings.isEmpty {
                ContentUnavailableView("No log entries yet", systemImage: "book",
                                       description: Text("Log a QSO from the Home card or the + button; pass recordings appear here too. (SSTV images have their own screen.)"))
            }
            if !qso.qsos.isEmpty {
                Section("Contacts (\(qso.qsos.count))") {
                    ForEach(qso.qsos) { q in
                        Button { editing = q } label: { qsoRow(q) }.buttonStyle(.plain)
                    }
                    .onDelete { qso.delete(at: $0) }
                }
            }
            if !qso.recordings.isEmpty {
                Section("Pass recordings") {
                    ForEach(qso.recordings) { r in recordingRow(r) }
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingNew = true } label: { Label("New QSO", systemImage: "plus") }
                    Button { exportADIF() } label: { Label("Export ADIF", systemImage: "square.and.arrow.up") }
                    Button { importing = true } label: { Label("Import ADIF", systemImage: "square.and.arrow.down") }
                    Divider()
                    Button { Task { await upload(lotw: true) } } label: {
                        Label("Upload to LoTW (\(qso.countUnuploaded(.lotw)))", systemImage: "checkmark.seal")
                    }
                    Button { Task { await upload(lotw: false) } } label: {
                        Label("Upload to Cloudlog (\(qso.countUnuploaded(.cloudlog)))", systemImage: "cloud")
                    }
                    Divider()
                    Button { showSettings = true } label: { Label("Log settings", systemImage: "gearshape") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .overlay { if working { ProgressView().controlSize(.large) } }
        .sheet(item: $editing) { rec in QSOEditView(existing: rec) }
        .sheet(isPresented: $showingNew) { QSOEditView(existing: nil) }
        .sheet(isPresented: $showSettings) { NavigationStack { LogSettingsView() } }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "adi") ?? .plainText, .plainText, .data]) { result in
            if case .success(let url) = result { importADIF(url) }
        }
        .alert("Log", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(status ?? "") }
    }

    private func qsoRow(_ q: QSORecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(q.call.isEmpty ? "—" : q.call).font(.headline)
                Spacer()
                if q.uploaded.contains(.lotw) { badge("L", ODTheme.good) }
                if q.uploaded.contains(.cloudlog) { badge("C", ODTheme.accent) }
            }
            Text("\(q.sat) · \(q.mode) · \(ODFormat.primaryClock(q.utc))")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.25)).foregroundStyle(c).clipShape(Capsule())
    }

    private func recordingRow(_ r: RecordingEntry) -> some View {
        HStack {
            Button { togglePlay(r) } label: {
                Image(systemName: player.playingID == r.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2).foregroundStyle(ODTheme.accent)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.sat.isEmpty ? "Recording" : r.sat).font(.subheadline.weight(.semibold))
                Text("\(ODFormat.primaryClock(r.start)) · \(ODFormat.duration(r.duration))")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Spacer()
            ShareLink(item: QSOStore.recordingsDir.appendingPathComponent(r.filename)) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .swipeActions { Button(role: .destructive) { qso.deleteRecording(r) } label: { Label("Delete", systemImage: "trash") } }
    }

    private func togglePlay(_ r: RecordingEntry) {
        let url = QSOStore.recordingsDir.appendingPathComponent(r.filename)
        player.toggle(id: r.id, url: url)
    }

    private func exportADIF() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbitdeck-log.adi")
        try? qso.adifExport().data(using: .utf8)?.write(to: url)
        exportURL = url
    }

    private func importADIF(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { status = "Could not read the file."; return }
        let n = qso.adifImport(text)
        status = "Imported \(n) QSO(s)."
    }

    private func upload(lotw: Bool) async {
        working = true
        status = lotw ? await qso.uploadLoTW() : await qso.uploadCloudlog()
        working = false
    }
}

// MARK: - QSO editor

struct QSOEditView: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    @Environment(\.dismiss) private var dismiss

    let existing: QSORecord?
    @State private var record: QSORecord

    init(existing: QSORecord?) {
        self.existing = existing
        _record = State(initialValue: existing ?? QSORecord(utc: Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    labeledField("Call", text: $record.call, caps: true)
                    labeledField("Their grid", text: $record.grid, caps: true)
                    HStack {
                        labeledField("RST sent", text: $record.rstSent)
                        labeledField("RST rcvd", text: $record.rstRcvd)
                    }
                    DatePicker("Time (UTC)", selection: $record.utc)
                }
                Section("Satellite") {
                    labeledField("Satellite", text: $record.sat)
                    labeledField("Mode", text: $record.mode, caps: true)
                    HStack { Text("Downlink"); Spacer(); TextField("Hz", value: $record.dlHz, format: .number).multilineTextAlignment(.trailing) }
                    HStack { Text("Uplink"); Spacer(); TextField("Hz", value: $record.ulHz, format: .number).multilineTextAlignment(.trailing) }
                }
                Section("Station") {
                    labeledField("My call", text: $record.myCall, caps: true)
                    labeledField("My grid", text: $record.myGrid, caps: true)
                    labeledField("Notes", text: $record.notes)
                }
            }
            .navigationTitle(existing == nil ? "New QSO" : "Edit QSO")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(record.call.isEmpty) }
            }
            .onAppear { if existing == nil { prefill() } }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, caps: Bool = false) -> some View {
        TextField(label, text: text)
            .textInputAutocapitalization(caps ? .characters : .sentences)
            .autocorrectionDisabled(caps)
    }

    private func prefill() {
        let sat = store.selectedSatellite
        let base = QSORecord.prefilled(satellite: sat, transponder: sat.flatMap { rig.transponder(for: $0) },
                                       myGrid: store.operatorGrid6, myCall: qso.config.myCall,
                                       defaultRst: qso.config.defaultRst)
        // Keep the fresh id/utc from `record`, fill the rest.
        record.sat = base.sat; record.mode = base.mode; record.dlHz = base.dlHz; record.ulHz = base.ulHz
        record.myGrid = base.myGrid; record.myCall = base.myCall
        record.rstSent = base.rstSent; record.rstRcvd = base.rstRcvd
    }

    private func save() {
        record.call = record.call.uppercased()
        if existing == nil { qso.add(record) } else { qso.update(record) }
        dismiss()
    }
}

// MARK: - Log settings

struct LogSettingsView: View {
    @EnvironmentObject private var qso: QSOStore
    @Environment(\.dismiss) private var dismiss

    @State private var importingP12 = false
    @State private var p12Passphrase = ""
    @State private var pendingP12: Data?
    @State private var cloudlogKey = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable logging", isOn: binding(\.enabled))
                Text("Shows a Log QSO card on Home and the Log screen.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Section("Station") {
                field("My call", binding(\.myCall), caps: true)
                field("Default RST", binding(\.defaultRst))
            }
            Section("LoTW station location") {
                field("Callsign (cert)", stationBinding(\.call), caps: true)
                field("DXCC", stationBinding(\.dxcc))
                field("Grid", stationBinding(\.grid), caps: true)
                field("CQ zone", stationBinding(\.cqz))
                field("ITU zone", stationBinding(\.ituz))
                field("US state", stationBinding(\.usState), caps: true)
                field("US county", stationBinding(\.usCounty))
            }
            Section("LoTW certificate") {
                if qso.config.hasLoTWCredential {
                    Label("Certificate imported", systemImage: "checkmark.seal.fill").foregroundStyle(ODTheme.good)
                    Button(role: .destructive) { LoTW.clearCredential(); qso.config.hasLoTWCredential = false; qso.persistConfig() } label: {
                        Text("Remove certificate")
                    }
                } else {
                    Button { importingP12 = true } label: { Label("Import .p12 certificate", systemImage: "doc.badge.plus") }
                    if pendingP12 != nil {
                        SecureField("Certificate passphrase", text: $p12Passphrase)
                        Button("Import") { importP12() }.disabled(p12Passphrase.isEmpty)
                    }
                    Text("Export your callsign certificate from TQSL as a .p12, then import it here. It stays on this device; the passphrase is stored in the Keychain.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
            Section("Cloudlog / Wavelog") {
                field("Instance URL", cloudBinding(\.url))
                field("Station profile ID", cloudBinding(\.stationProfileId))
                SecureField("API key", text: $cloudlogKey)
                    .onAppear { cloudlogKey = OrbitSecretStore.get(.cloudlogKey) }
                    .onChange(of: cloudlogKey) { _, v in OrbitSecretStore.set(v, for: .cloudlogKey) }
            }
        }
        .navigationTitle("Log settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { qso.persistConfig(); dismiss() } } }
        .onDisappear { qso.persistConfig() }
        .fileImporter(isPresented: $importingP12,
                      allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .pkcs12, .data]) { result in
            if case .success(let url) = result { loadP12(url) }
        }
        .alert("LoTW", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(status ?? "") }
    }

    private func field(_ label: String, _ text: Binding<String>, caps: Bool = false) -> some View {
        HStack {
            Text(label); Spacer()
            TextField(label, text: text).multilineTextAlignment(.trailing)
                .textInputAutocapitalization(caps ? .characters : .never).autocorrectionDisabled()
        }
    }

    private func loadP12(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        pendingP12 = try? Data(contentsOf: url)
        if pendingP12 == nil { status = "Could not read the file." }
    }

    private func importP12() {
        guard let data = pendingP12 else { return }
        do {
            let cn = try LoTW.importP12(data, passphrase: p12Passphrase)
            qso.config.hasLoTWCredential = true
            if qso.config.station.call.isEmpty { qso.config.station.call = cn }
            qso.persistConfig()
            pendingP12 = nil; p12Passphrase = ""
            status = cn.isEmpty ? "Certificate imported." : "Certificate imported for \(cn)."
        } catch {
            status = error.localizedDescription
        }
    }

    // Bindings that persist config on change.
    private func binding<T>(_ kp: WritableKeyPath<LoggingConfig, T>) -> Binding<T> {
        Binding(get: { qso.config[keyPath: kp] }, set: { qso.config[keyPath: kp] = $0; qso.persistConfig() })
    }
    private func stationBinding<T>(_ kp: WritableKeyPath<LoTWStation, T>) -> Binding<T> {
        Binding(get: { qso.config.station[keyPath: kp] }, set: { qso.config.station[keyPath: kp] = $0; qso.persistConfig() })
    }
    private func cloudBinding<T>(_ kp: WritableKeyPath<CloudlogConfig, T>) -> Binding<T> {
        Binding(get: { qso.config.cloudlog[keyPath: kp] }, set: { qso.config.cloudlog[keyPath: kp] = $0; qso.persistConfig() })
    }
}

// MARK: - Share sheet wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable { public var id: String { absoluteString } }

/// Simple one-at-a-time player for pass recordings on the Log screen.
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @Published var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(id: UUID, url: URL) {
        if playingID == id { stop(); return }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingID = id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop(); player = nil; playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}
