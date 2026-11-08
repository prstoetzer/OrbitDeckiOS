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
            // SatNOGS lists a separate uplink mode for cross-mode transponders.
            if let up = tp.uplinkMode, !up.isEmpty, adifMode(up) != q.mode { q.uplinkMode = adifMode(up) }
        }
        q.myGrid = myGrid
        q.myCall = myCall
        q.rstSent = LoggingConfig.rst(for: q.mode, base: defaultRst)
        q.rstRcvd = q.rstSent
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

    /// Common satellite modes offered by the editor's mode menus (free text still allowed).
    static let commonModes = ["SSB", "USB", "LSB", "FM", "CW", "AM", "FT4", "FT8", "PKT", "SSTV", "DATA"]
}

// MARK: - Home quick-log card

struct HomeQuickLogCard: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    let satellite: SatelliteRecord

    @State private var call = ""
    @State private var rstSent = ""
    @State private var rstRcvd = ""
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
            // Don't clobber a report the operator typed when they come back to this tab.
            .onAppear { if rstSent.isEmpty && rstRcvd.isEmpty { resetRst() } }
            .onChange(of: satellite.id) { _, _ in resetRst() }
            .onChange(of: rig.config.tuning.linearCW) { _, _ in resetRst() }
        }
    }

    /// The default report for the current transponder's mode (59 voice, 599 CW/data).
    private var defaultRst: String {
        let mode = linearCW ? "CW" : (rig.transponder(for: satellite).map { QSORecord.adifMode($0.mode) } ?? "SSB")
        return qso.config.rst(for: mode)
    }

    /// CW chosen for linear transponders (CAT setting) and this one is linear.
    private var linearCW: Bool {
        rig.config.tuning.linearCW && (rig.transponder(for: satellite)?.isLinear ?? false)
    }

    private func resetRst() { rstSent = defaultRst; rstRcvd = defaultRst }

    private func logIt() {
        var q = QSORecord.prefilled(satellite: satellite, transponder: rig.transponder(for: satellite),
                                    myGrid: store.operatorGrid6, myCall: qso.config.myCall,
                                    defaultRst: qso.config.defaultRst)
        q.call = call.trimmingCharacters(in: .whitespaces).uppercased()
        if linearCW { q.mode = "CW"; q.uplinkMode = nil; q.downlinkMode = nil }
        q.rstSent = rstSent; q.rstRcvd = rstRcvd
        q.grid = theirGrid.trimmingCharacters(in: .whitespaces).uppercased()
        qso.add(q)
        call = ""; theirGrid = ""; resetRst()
        justLogged = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); justLogged = false }
    }
}

// MARK: - Log screen

struct LogScreen: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    @EnvironmentObject private var audio: AudioHub
    @ObservedObject private var memo = PassRecorder.memo

    @State private var editing: QSORecord?
    @State private var showingNew = false
    @State private var showSettings = false
    @State private var showAwards = false
    @State private var showReport = false
    @State private var reportIDs: Set<UUID>?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var status: String?
    @State private var working = false
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmResend: UploadFlags?
    @StateObject private var player = RecordingPlayer()

    /// Selected QSO ids (the list's selection can also hold recording rows).
    private var selectedQSOs: Set<UUID> { selection.intersection(qso.qsos.map(\.id)) }

    var body: some View {
        List(selection: $selection) {
            if memo.isRecording || !memo.errorText.isEmpty {
                Section("Voice memo") { VoiceMemoControl() }
            }
            if qso.qsos.isEmpty && qso.recordings.isEmpty && qso.ft4Traffic.isEmpty {
                ContentUnavailableView("No log entries yet", systemImage: "book",
                                       description: Text("Log a QSO from the Home card or the + button; pass recordings and FT4 activity appear here too. (SSTV images have their own screen.)"))
            }
            if !qso.qsos.isEmpty {
                Section("Contacts (\(qso.qsos.count))") {
                    ForEach(qso.qsos) { q in
                        HStack {
                            if selecting {
                                qsoRow(q)
                            } else {
                                Button { editing = q } label: { qsoRow(q) }.buttonStyle(.plain)
                            }
                            if let memoFile = q.memoFile { memoButton(q.id, memoFile) }
                        }
                    }
                    .onDelete { qso.delete(at: $0) }
                }
            }
            if !qso.recordings.isEmpty && !selecting {
                Section("Pass recordings & voice memos") {
                    ForEach(qso.recordings) { r in recordingRow(r) }
                }
            }
            if !qso.ft4Traffic.isEmpty && !selecting {
                Section("FT4 activity") {
                    NavigationLink { FT4TrafficScreen() } label: {
                        HStack {
                            Label("FT4 traffic log", systemImage: "waveform.badge.magnifyingglass")
                            Spacer()
                            Text("\(qso.ft4Traffic.count) lines").font(.caption).foregroundStyle(ODTheme.muted)
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .navigationTitle("Log")
        .navigationDestination(isPresented: $showAwards) { AwardsScreen() }
        .toolbar {
            if selecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { selecting = false; selection.removeAll() }
                }
                ToolbarItemGroup(placement: .bottomBar) { selectionActions }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        VoiceMemoControl.toggle(satellite: store.selectedSatellite, audio: audio, store: store, rig: rig, qso: qso)
                    } label: {
                        Image(systemName: memo.isRecording ? "stop.circle.fill" : "mic.circle")
                            .foregroundStyle(memo.isRecording ? ODTheme.warning : ODTheme.accent)
                    }
                    .accessibilityLabel(memo.isRecording ? "Stop voice memo" : "Record voice memo")
                }
                ToolbarItem(placement: .primaryAction) { mainMenu }
            }
        }
        .overlay { if working { ProgressView().controlSize(.large) } }
        .sheet(item: $editing) { rec in QSOEditView(existing: rec) }
        .sheet(isPresented: $showingNew) { QSOEditView(existing: nil) }
        .sheet(isPresented: $showSettings) { NavigationStack { LogSettingsView() } }
        .sheet(isPresented: $showReport) { NavigationStack { LogReportView(onlyIDs: reportIDs) } }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "adi") ?? .plainText, .plainText, .data]) { result in
            if case .success(let url) = result { importADIF(url) }
        }
        .confirmationDialog(confirmResend == .lotw ? "Re-send every QSO to LoTW?" : "Re-send every QSO to Cloudlog?",
                            isPresented: Binding(get: { confirmResend != nil }, set: { if !$0 { confirmResend = nil } }),
                            titleVisibility: .visible) {
            Button("Re-send all") {
                let lotw = confirmResend == .lotw
                Task { await upload(lotw: lotw, ids: Set(qso.qsos.map(\.id))) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uploads the whole log again, including QSOs already marked as sent. LoTW ignores exact duplicates.")
        }
        .alert("Log", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(status ?? "") }
    }

    private var mainMenu: some View {
        Menu {
            Button { showingNew = true } label: { Label("New QSO", systemImage: "plus") }
            Button { showAwards = true } label: { Label("Awards", systemImage: "rosette") }
            Button { reportIDs = nil; showReport = true } label: { Label("Log report (PDF)", systemImage: "doc.richtext") }
            Button { exportADIF() } label: { Label("Export ADIF", systemImage: "square.and.arrow.up") }
            Button { importing = true } label: { Label("Import ADIF", systemImage: "square.and.arrow.down") }
            Divider()
            Button { Task { await upload(lotw: true) } } label: {
                Label("Upload to LoTW (\(qso.countUnuploaded(.lotw)))", systemImage: "checkmark.seal")
            }
            Button { Task { await upload(lotw: false) } } label: {
                Label("Upload to Cloudlog (\(qso.countUnuploaded(.cloudlog)))", systemImage: "cloud")
            }
            Menu {
                Button { confirmResend = .lotw } label: { Label("Re-send all to LoTW", systemImage: "checkmark.seal") }
                Button { confirmResend = .cloudlog } label: { Label("Re-send all to Cloudlog", systemImage: "cloud") }
                Button { selecting = true } label: { Label("Select QSOs to re-send…", systemImage: "checklist") }
            } label: { Label("Re-send", systemImage: "arrow.clockwise") }
            .disabled(qso.qsos.isEmpty)
            Divider()
            Button { showSettings = true } label: { Label("Log settings", systemImage: "gearshape") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    @ViewBuilder private var selectionActions: some View {
        let ids = selectedQSOs
        Menu {
            Button { Task { await upload(lotw: true, ids: ids) } } label: { Label("Re-send to LoTW", systemImage: "checkmark.seal") }
            Button { Task { await upload(lotw: false, ids: ids) } } label: { Label("Re-send to Cloudlog", systemImage: "cloud") }
        } label: { Label("Re-send (\(ids.count))", systemImage: "arrow.clockwise") }
        .disabled(ids.isEmpty)
        Spacer()
        Button { reportIDs = ids; showReport = true } label: { Label("PDF", systemImage: "doc.richtext") }
            .disabled(ids.isEmpty)
        Spacer()
        Button(selectedQSOs.count == qso.qsos.count ? "Select none" : "Select all") {
            if selectedQSOs.count == qso.qsos.count { selection.removeAll() } else { selection = Set(qso.qsos.map(\.id)) }
        }
    }

    private func qsoRow(_ q: QSORecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(q.isStub ? "Memo stub" : q.call).font(.headline)
                    .foregroundStyle(q.isStub ? ODTheme.warning : .primary)
                if !q.name.isEmpty { Text(q.name).font(.subheadline) }
                if !q.grid.isEmpty { Text(q.gridList.first ?? q.grid).font(.caption).foregroundStyle(ODTheme.muted) }
                Spacer()
                if q.lotwConfirmed { badge("QSL", ODTheme.good) }
                if q.uploaded.contains(.lotw) { badge("L", ODTheme.good) }
                if q.uploaded.contains(.cloudlog) { badge("C", ODTheme.accent) }
            }
            // Logs are UTC by convention — always, regardless of the local-time setting.
            Text("\(q.sat) · \(modeLabel(q)) · \(ODFormat.utcStamp(q.utc))")
                .font(.caption).foregroundStyle(ODTheme.muted)
            let rst = (q.rstSent.isEmpty && q.rstRcvd.isEmpty) ? nil
                : "Sent \(q.rstSent.isEmpty ? "—" : q.rstSent) · Rcvd \(q.rstRcvd.isEmpty ? "—" : q.rstRcvd)"
            let place = [q.state.isEmpty ? nil : q.state, q.country.isEmpty ? nil : q.country].compactMap { $0 }
            let detail = [rst, place.isEmpty ? nil : place.joined(separator: ", ")].compactMap { $0 }
            if !detail.isEmpty {
                Text(detail.joined(separator: " · ")).font(.caption2).foregroundStyle(ODTheme.muted)
            }
            if q.isStub {
                Text("Tap to add the callsign and complete this contact.").font(.caption2).foregroundStyle(ODTheme.warning)
            }
        }
    }

    /// Play/stop for a QSO's linked voice memo (hidden if the file was deleted).
    @ViewBuilder private func memoButton(_ id: UUID, _ file: String) -> some View {
        let url = QSOStore.recordingsDir.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            Button { player.toggle(id: id, url: url) } label: {
                Image(systemName: player.playingID == id ? "stop.circle.fill" : "waveform.circle")
                    .font(.title2).foregroundStyle(ODTheme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.playingID == id ? "Stop voice memo" : "Play voice memo")
        }
    }

    /// "SSB", or "FM↑ SSB↓" when the uplink and downlink modes differ.
    private func modeLabel(_ q: QSORecord) -> String {
        let up = q.effectiveUplinkMode, down = q.effectiveDownlinkMode
        return up == down ? up : "\(up)↑ \(down)↓"
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
                HStack(spacing: 4) {
                    if r.isMemo == true { Image(systemName: "mic.fill").font(.caption).foregroundStyle(ODTheme.muted) }
                    Text(r.sat.isEmpty ? (r.isMemo == true ? "Voice memo" : "Recording") : r.sat)
                        .font(.subheadline.weight(.semibold))
                }
                Text("\(ODFormat.utcStamp(r.start)) · \(ODFormat.duration(r.duration))")
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
        let r = qso.adifImport(text)
        var parts = ["Added \(r.added) QSO(s)", "updated \(r.updated) already in the log"]
        if r.unchanged > 0 { parts.append("\(r.unchanged) matched with nothing new") }
        status = parts.joined(separator: ", ") + "."
    }

    /// Upload the pending QSOs, or re-send exactly `ids` when given.
    private func upload(lotw: Bool, ids: Set<UUID>? = nil) async {
        working = true
        status = lotw ? await qso.uploadLoTW(ids: ids) : await qso.uploadCloudlog(ids: ids)
        working = false
        if ids != nil { selecting = false; selection.removeAll() }
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
    /// The upload toggles were changed by hand, so Save keeps them as set instead of
    /// clearing the flags an edited field invalidates.
    @State private var flagsTouched = false
    @StateObject private var player = RecordingPlayer()

    init(existing: QSORecord?) {
        self.existing = existing
        _record = State(initialValue: existing ?? QSORecord(utc: Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let memoFile = record.memoFile { memoSection(memoFile) }
                Section("Contact") {
                    labeledField("Call", text: $record.call, caps: true)
                    TextField("Name", text: $record.name)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                    labeledField("Their grid", text: $record.grid, caps: true)
                    HStack {
                        labeledField("RST sent", text: $record.rstSent)
                        labeledField("RST rcvd", text: $record.rstRcvd)
                    }
                    // Log times are UTC: without the zone override the picker shows and
                    // edits device-local time while the label says UTC.
                    DatePicker("Time (UTC)", selection: $record.utc)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    HStack {
                        TextField("Country", text: $record.country)
                        TextField("DXCC", value: $record.dxcc, format: .number.grouping(.never))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 70)
                    }
                    stateField
                }
                Section {
                    labeledField("Satellite", text: $record.sat)
                    modeField("Mode", text: $record.mode)
                    modeField("Uplink mode", text: legBinding(\.uplinkMode), placeholder: "Same as mode")
                    modeField("Downlink mode", text: legBinding(\.downlinkMode), placeholder: "Same as mode")
                    HStack { Text("Downlink"); Spacer(); TextField("Hz", value: $record.dlHz, format: .number).multilineTextAlignment(.trailing) }
                    HStack { Text("Uplink"); Spacer(); TextField("Hz", value: $record.ulHz, format: .number).multilineTextAlignment(.trailing) }
                } header: {
                    Text("Satellite")
                } footer: {
                    Text("Set the uplink or downlink mode only for a cross-mode contact; Mode is what LoTW and ADIF MODE use.")
                }
                Section("Station") {
                    labeledField("My call", text: $record.myCall, caps: true)
                    labeledField("My grid", text: $record.myGrid, caps: true)
                    labeledField("Notes", text: $record.notes)
                }
                if existing != nil {
                    Section {
                        Toggle("Uploaded to LoTW", isOn: flagBinding(.lotw))
                        Toggle("Uploaded to Cloudlog", isOn: flagBinding(.cloudlog))
                        Toggle("Confirmed in LoTW", isOn: Binding(get: { record.lotwConfirmed },
                                                                  set: { record.lotwConfirmed = $0 }))
                    } header: {
                        Text("Uploads")
                    } footer: {
                        Text("Editing the call, time, satellite, mode or frequencies clears both upload marks (any other field clears Cloudlog's) so the corrected QSO is sent again. Turn a mark off to re-send this QSO on the next upload.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New QSO" : (existing?.isStub == true ? "Complete QSO" : "Edit QSO"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                // A memo stub can be saved before it has a call; a new QSO needs one.
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(record.call.isEmpty && existing == nil) }
            }
            .onAppear { if existing == nil { prefill() } }
            .onDisappear { player.stop() }
            .onChange(of: record.mode) { old, new in
                // Follow the mode with the default report while it hasn't been edited.
                let wasDefault = qso.config.rst(for: old), nowDefault = qso.config.rst(for: new)
                if record.rstSent == wasDefault { record.rstSent = nowDefault }
                if record.rstRcvd == wasDefault { record.rstRcvd = nowDefault }
            }
            .onChange(of: record.call) { old, new in
                // Re-resolve the entity for a new call unless it was typed in by hand.
                let oldMatch = DXCCLookup.entity(for: old)
                guard record.dxcc == oldMatch?.code, record.country == (oldMatch?.name ?? "") else { return }
                let match = DXCCLookup.entity(for: new)
                record.dxcc = match?.code
                record.country = match?.name ?? ""
            }
        }
    }

    /// ADIF STATE: a US-state menu for US contacts (WAS), free text otherwise.
    private var stateField: some View {
        HStack {
            Text("State")
            TextField("State / province", text: $record.state)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
            if QSOStore.usEntities.contains(record.dxcc ?? -1) {
                Menu {
                    Button("None") { record.state = "" }
                    ForEach(LoTWSubdivisions.usStates) { s in Button("\(s.name) (\(s.code))") { record.state = s.code } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
            }
        }
    }

    private func memoSection(_ file: String) -> some View {
        let url = QSOStore.recordingsDir.appendingPathComponent(file)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return Section {
            if exists {
                Button { player.toggle(id: record.id, url: url) } label: {
                    Label(player.playingID == record.id ? "Stop memo" : "Play voice memo",
                          systemImage: player.playingID == record.id ? "stop.circle.fill" : "play.circle.fill")
                }
            } else {
                Text("The memo recording was deleted.").foregroundStyle(ODTheme.muted)
            }
        } header: {
            Text("Voice memo")
        } footer: {
            if record.isStub { Text("Logged from a voice memo — add the callsign and anything else you noted, then save.") }
        }
    }

    private func flagBinding(_ flag: UploadFlags) -> Binding<Bool> {
        Binding(get: { record.uploaded.contains(flag) },
                set: { on in
                    if on { record.uploaded.insert(flag) } else { record.uploaded.remove(flag) }
                    flagsTouched = true
                })
    }

    private func labeledField(_ label: String, text: Binding<String>, caps: Bool = false) -> some View {
        TextField(label, text: text)
            .textInputAutocapitalization(caps ? .characters : .sentences)
            .autocorrectionDisabled(caps)
    }

    /// Free-text mode with a menu of the common ones.
    private func modeField(_ label: String, text: Binding<String>, placeholder: String? = nil) -> some View {
        HStack {
            Text(label)
            TextField(placeholder ?? label, text: text)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
            Menu {
                if placeholder != nil { Button("Same as mode") { text.wrappedValue = "" } }
                ForEach(QSORecord.commonModes, id: \.self) { m in Button(m) { text.wrappedValue = m } }
            } label: { Image(systemName: "chevron.up.chevron.down") }
        }
    }

    /// An optional per-leg mode as text: empty means "same as Mode" (nil).
    private func legBinding(_ kp: WritableKeyPath<QSORecord, String?>) -> Binding<String> {
        Binding(get: { record[keyPath: kp] ?? "" },
                set: { let v = $0.trimmingCharacters(in: .whitespaces).uppercased(); record[keyPath: kp] = v.isEmpty ? nil : v })
    }

    private func prefill() {
        let sat = store.selectedSatellite
        let base = QSORecord.prefilled(satellite: sat, transponder: sat.flatMap { rig.transponder(for: $0) },
                                       myGrid: store.operatorGrid6, myCall: qso.config.myCall,
                                       defaultRst: qso.config.defaultRst)
        // Keep the fresh id/utc from `record`, fill the rest.
        record.sat = base.sat; record.mode = base.mode; record.dlHz = base.dlHz; record.ulHz = base.ulHz
        record.uplinkMode = base.uplinkMode
        record.myGrid = base.myGrid; record.myCall = base.myCall
        record.rstSent = base.rstSent; record.rstRcvd = base.rstRcvd
    }

    private func save() {
        record.call = record.call.uppercased()
        record.state = record.state.trimmingCharacters(in: .whitespaces).uppercased()
        if existing == nil { qso.add(record) } else { qso.update(record, keepUploadFlags: flagsTouched) }
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
                Text("Used as given for voice (59); CW and data modes add the tone digit (599). FT4/FT8 log a dB report.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Section("QRZ") {
                Toggle("Fill in names and states from QRZ", isOn: binding(\.qrzNameLookup))
                Text(qso.qrzCredentials() == nil
                     ? "Add your QRZ XML username and password in Settings to look up the operator's first name (and a US station's state) for new QSOs."
                     : "Looks up the operator's first name (or QRZ nickname) in the background when a QSO is logged without one, and a US station's state for WAS.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Section {
                field("Callsign (cert)", stationBinding(\.call), caps: true)
                NavigationLink {
                    LoTWOptionPicker(title: "DXCC entity", groups: Self.entityGroups, selected: qso.config.station.dxcc) { pickEntity($0) }
                } label: {
                    pickerRow("DXCC entity", stationEntity.map { $0.name.capitalized + " (\($0.id))" } ?? qso.config.station.dxcc)
                }
                if let e = stationEntity, !e.primaryField.isEmpty {
                    NavigationLink {
                        LoTWOptionPicker(title: LoTWSubdivisions.label(e.primaryField),
                                         groups: [("", LoTWSubdivisions.primaryOptions(for: e))],
                                         selected: primaryCode(e)) { pickPrimary($0, entity: e) }
                    } label: {
                        pickerRow(LoTWSubdivisions.label(e.primaryField),
                                  optionLabel(primaryCode(e), LoTWSubdivisions.primaryOptions(for: e)))
                    }
                    if !e.secondaryField.isEmpty, !primaryCode(e).isEmpty {
                        let options = LoTWSubdivisions.secondaryOptions(for: e, primary: primaryCode(e))
                        NavigationLink {
                            LoTWOptionPicker(title: LoTWSubdivisions.label(e.secondaryField), groups: [("", options)],
                                             selected: secondaryCode(e)) { pickSecondary($0, entity: e) }
                        } label: {
                            pickerRow(LoTWSubdivisions.label(e.secondaryField), optionLabel(secondaryCode(e), options))
                        }
                        .disabled(options.isEmpty)
                    }
                }
                field("Grid", stationBinding(\.grid), caps: true)
                field("CQ zone", stationBinding(\.cqz))
                field("ITU zone", stationBinding(\.ituz))
                field("IOTA", Binding(get: { qso.config.station.iota },
                                      set: { qso.config.station.iota = $0.uppercased(); qso.persistConfig() }), caps: true)
            } header: {
                Text("LoTW station location")
            } footer: {
                Text("Pick your DXCC entity, then its subdivision (US state and county, Canadian province, Japanese prefecture and city/gun/ku, Russian oblast, …) as LoTW lists them; US, Alaska and Hawaii stations must set a state. IOTA is optional (e.g. NA-005). These are signed into every upload, so set them before uploading.")
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

    // MARK: LoTW location picker

    /// Entities with a subdivision first (as CardSat/TQSL list them), then the rest.
    private static let entityGroups: [(String, [LoTWSubdivisions.Option])] = {
        func opts(_ list: [LoTWSubdivisions.Entity]) -> [LoTWSubdivisions.Option] {
            list.map { LoTWSubdivisions.Option(code: String($0.id), name: $0.name.capitalized) }
        }
        let all = LoTWSubdivisions.entities
        return [("Entities with subdivisions", opts(all.filter { !$0.primaryField.isEmpty })),
                ("All other entities", opts(all.filter { $0.primaryField.isEmpty }))]
    }()

    /// The configured entity. A setup from before the picker existed may have a US state
    /// but no DXCC typed in; treat that as the USA so its state/county stay visible.
    private var stationEntity: LoTWSubdivisions.Entity? {
        let st = qso.config.station
        if let code = Int(st.dxcc.trimmingCharacters(in: .whitespaces)) { return LoTWSubdivisions.entity(code) }
        return st.dxcc.isEmpty && !st.usState.isEmpty ? LoTWSubdivisions.entity(291) : nil
    }

    private func primaryCode(_ e: LoTWSubdivisions.Entity) -> String {
        let st = qso.config.station
        if e.primaryField == "US_STATE" { return st.usState.uppercased() }
        return st.subdivField == e.primaryField ? st.subdiv : ""
    }

    private func secondaryCode(_ e: LoTWSubdivisions.Entity) -> String {
        let st = qso.config.station
        if e.secondaryField == "US_COUNTY" {
            // Older setups may hold "ST,County"; the picker works with the county alone.
            guard let comma = st.usCounty.firstIndex(of: ",") else { return st.usCounty }
            return String(st.usCounty[st.usCounty.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        return st.subdiv2Field == e.secondaryField ? st.subdiv2 : ""
    }

    /// Set the entity and drop any subdivision that doesn't belong to it.
    private func pickEntity(_ code: String) {
        var st = qso.config.station
        st.dxcc = code
        let e = Int(code).flatMap { LoTWSubdivisions.entity($0) }
        if e?.primaryField != "US_STATE" { st.usState = ""; st.usCounty = "" }
        if st.subdivField != e?.primaryField || e?.primaryField == "US_STATE" { st.subdivField = ""; st.subdiv = "" }
        if st.subdiv2Field != e?.secondaryField { st.subdiv2Field = ""; st.subdiv2 = "" }
        // Alaska and Hawaii have exactly one state: fill it in.
        if let e, e.primaryField == "US_STATE" {
            let states = LoTWSubdivisions.primaryOptions(for: e)
            if states.count == 1, st.usState.uppercased() != states[0].code { st.usState = states[0].code; st.usCounty = "" }
            if !states.contains(where: { $0.code == st.usState.uppercased() }) { st.usState = ""; st.usCounty = "" }
        }
        qso.config.station = st
        qso.persistConfig()
    }

    private func pickPrimary(_ code: String, entity e: LoTWSubdivisions.Entity) {
        var st = qso.config.station
        if e.primaryField == "US_STATE" {
            if st.usState.uppercased() != code { st.usCounty = "" }
            st.usState = code
        } else {
            if st.subdiv != code { st.subdiv2Field = ""; st.subdiv2 = "" }
            st.subdivField = code.isEmpty ? "" : e.primaryField
            st.subdiv = code
        }
        if st.dxcc.isEmpty { st.dxcc = String(e.id) }
        qso.config.station = st
        qso.persistConfig()
    }

    private func pickSecondary(_ code: String, entity e: LoTWSubdivisions.Entity) {
        if e.secondaryField == "US_COUNTY" {
            qso.config.station.usCounty = code
        } else {
            qso.config.station.subdiv2Field = code.isEmpty ? "" : e.secondaryField
            qso.config.station.subdiv2 = code
        }
        qso.persistConfig()
    }

    private func optionLabel(_ code: String, _ options: [LoTWSubdivisions.Option]) -> String {
        guard !code.isEmpty else { return "" }
        return options.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }?.name ?? code
    }

    private func pickerRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.isEmpty ? "Not set" : value).foregroundStyle(ODTheme.muted).lineLimit(1)
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

// MARK: - LoTW subdivision picker

/// Searchable single-choice list for the LoTW location chain (entity, primary and
/// secondary subdivision). Matches on code or name; "None" clears the choice.
struct LoTWOptionPicker: View {
    let title: String
    let groups: [(String, [LoTWSubdivisions.Option])]
    let selected: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                Button { onPick(""); dismiss() } label: { row(LoTWSubdivisions.Option(code: "", name: "None")) }
            }
            ForEach(groups.indices, id: \.self) { i in
                let items = filtered(groups[i].1)
                if !items.isEmpty {
                    Section(groups[i].0) {
                        ForEach(items) { o in
                            Button { onPick(o.code); dismiss() } label: { row(o) }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func filtered(_ list: [LoTWSubdivisions.Option]) -> [LoTWSubdivisions.Option] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q) }
    }

    private func row(_ o: LoTWSubdivisions.Option) -> some View {
        HStack {
            Text(o.name).foregroundStyle(.primary)
            Spacer()
            // Codes that are just the name again (US counties) aren't repeated.
            if !o.code.isEmpty, o.code != o.name, !o.name.hasPrefix(o.code) {
                Text(o.code).font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
            }
            if o.code.caseInsensitiveCompare(selected) == .orderedSame {
                Image(systemName: "checkmark").foregroundStyle(ODTheme.accent)
            }
        }
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

// MARK: - FT4 activity log

/// Full, persisted FT4 traffic (every decode + our transmissions), newest first,
/// with text export and a clear action. Reached from the Log screen's FT4 section.
struct FT4TrafficScreen: View {
    @EnvironmentObject private var qso: QSOStore
    @State private var confirmClear = false
    @State private var shareURL: URL?

    private static let utc: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    var body: some View {
        Group {
            if qso.ft4Traffic.isEmpty {
                ContentUnavailableView("No FT4 activity", systemImage: "waveform",
                                       description: Text("Run FT4 from the Home FT4 card — every decode and transmission is logged here."))
            } else {
                List {
                    Section("\(qso.ft4Traffic.count) lines (UTC)") {
                        ForEach(qso.ft4Traffic.reversed()) { e in row(e) }
                    }
                }
            }
        }
        .navigationTitle("FT4 Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !qso.ft4Traffic.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { shareURL = exportText() } label: { Label("Share as text", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear log", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Clear the entire FT4 activity log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { qso.clearFT4Traffic() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
    }

    private func row(_ e: FT4TrafficEntry) -> some View {
        let color: Color = e.sent ? .orange : ((FT4Engine.parse(e.text)?.isCQ == true) ? ODTheme.good : .primary)
        return HStack(spacing: 8) {
            Text(Self.utc.string(from: e.date))
                .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.text).font(.callout.monospaced()).foregroundStyle(color).lineLimit(1)
                Text("\(e.sat.isEmpty ? "" : e.sat + " · ")\(e.sent ? "TX" : "\(e.snr) dB") · \(e.freqHz) Hz")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func exportText() -> URL? {
        var s = "OrbitDeck FT4 activity log (UTC)\n"
        for e in qso.ft4Traffic {
            let dB = e.sent ? " TX" : String(format: "%3d", e.snr)
            s += "\(Self.utc.string(from: e.date))  \(dB)  \(String(format: "%5d", e.freqHz)) Hz  \(e.sat)  \(e.text)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FT4_activity.txt")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Simple one-at-a-time player for pass recordings on the Log screen.
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @Published var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(id: UUID, url: URL) {
        if playingID == id { stop(); return }
        stop()
        do {
            // While a capture runs (recording, memo, FT4…) the session is already
            // play-and-record; switching it to .playback would cut the capture off.
            if !AudioActivity.isActive {
                try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
            }
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

// MARK: - Awards

/// Worked-award summary for the log (QSOs, satellites, VUCC grids, WAS, DXCC), with
/// lists, a per-satellite drill-down and CSV/PDF export. Confirmed counts appear only
/// when the log carries LoTW QSL status (imported via ADIF).
struct AwardsScreen: View {
    @EnvironmentObject private var qso: QSOStore
    @State private var shareURL: URL?
    @State private var status: String?

    var body: some View {
        let awards = LogAwards(qso.qsos)
        List {
            Section {
                AwardTotalsView(tally: awards.all, satellites: awards.satellites.count, confirmed: awards.hasConfirmations)
            } header: {
                Text("All satellites")
            } footer: {
                Text(footer(awards))
            }
            if awards.usWithoutState > 0, qso.qrzCredentials() != nil, qso.config.qrzNameLookup {
                Section {
                    Button {
                        let n = qso.fillMissingStatesFromQRZ()
                        status = n > 0 ? "Looking up \(n) US contact(s) on QRZ — states fill in at about one per second." : "Nothing to look up."
                    } label: {
                        Label("Fill \(awards.usWithoutState) missing US state(s) from QRZ", systemImage: "magnifyingglass")
                    }
                }
            }
            AwardListsSection(tally: awards.all, confirmed: awards.hasConfirmations, scope: "All satellites")
            if !awards.satellites.isEmpty {
                Section("By satellite") {
                    ForEach(awards.satellites) { s in
                        NavigationLink {
                            SatelliteAwardsScreen(sat: s, confirmed: awards.hasConfirmations)
                        } label: {
                            HStack {
                                Text(s.name)
                                Spacer()
                                Text("\(s.tally.qsos) QSO · \(s.tally.grids.count) grids")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Awards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { shareURL = exportCSV(awards) } label: { Label("Export CSV", systemImage: "tablecells") }
                    Button { shareURL = exportPDF(awards) } label: { Label("Export PDF / Print", systemImage: "doc.richtext") }
                } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(awards.all.qsos == 0)
            }
        }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .alert("Awards", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(status ?? "") }
    }

    private func footer(_ a: LogAwards) -> String {
        var s = "Grids count each 4-character VUCC field (every grid of a rover or grid-line QSO). States come from each QSO's State field (editable, ADIF STATE or QRZ) — never guessed from a grid. DXCC uses the entity resolved from the call."
        s += a.hasConfirmations
            ? " Confirmed counts use the LoTW QSL status imported with your ADIF log."
            : " Worked totals only: there's no LoTW confirmation data in this log (import your QSL download from LoTW — matching QSOs already in the log are marked confirmed rather than added again)."
        if a.usWithoutState > 0 { s += " \(a.usWithoutState) US QSO(s) have no state yet." }
        s += " A working estimate for your own tracking, not an official award check."
        return s
    }

    private func exportCSV(_ a: LogAwards) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbitdeck-awards.csv")
        do { try a.csv().write(to: url, atomically: true, encoding: .utf8) } catch { status = error.localizedDescription; return nil }
        return url
    }

    private func exportPDF(_ a: LogAwards) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbitdeck-awards.pdf")
        do { try LogPDF.awards(a, myCall: qso.config.myCall).write(to: url) } catch { status = error.localizedDescription; return nil }
        return url
    }
}

/// The five headline totals, with confirmed counts when available.
struct AwardTotalsView: View {
    let tally: LogAwards.Tally
    let satellites: Int?
    let confirmed: Bool

    var body: some View {
        row("QSOs", tally.qsos, tally.confirmedQSOs)
        if let satellites { row("Satellites", satellites, nil) }
        row("Grids (VUCC)", tally.grids.count, tally.confirmedGrids.count)
        row("US states (WAS)", tally.states.count, tally.confirmedStates.count, of: LogAwards.wasTotal)
        row("DXCC entities", tally.dxcc.count, tally.confirmedDXCC.count)
    }

    private func row(_ label: String, _ worked: Int, _ conf: Int?, of total: Int? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(total.map { "\(worked) / \($0)" } ?? "\(worked)").font(.body.monospacedDigit().weight(.semibold))
            if confirmed, let conf {
                Text("\(conf) cfm").font(.caption.monospacedDigit()).foregroundStyle(ODTheme.good)
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
    }
}

/// One row of an award list: code, display name, confirmed.
struct AwardItem: Identifiable {
    let code: String
    let name: String
    let confirmed: Bool
    var id: String { code }
}

/// Links to the worked grid / state / DXCC lists for a tally.
struct AwardListsSection: View {
    let tally: LogAwards.Tally
    let confirmed: Bool
    let scope: String

    var body: some View {
        Section("Lists") {
            NavigationLink("Grids (\(tally.grids.count))") {
                AwardItemList(title: "Grids — \(scope)",
                              items: tally.grids.sorted().map { AwardItem(code: $0, name: "", confirmed: tally.confirmedGrids.contains($0)) },
                              confirmed: confirmed)
            }
            NavigationLink("US states (\(tally.states.count) of \(LogAwards.wasTotal))") {
                AwardItemList(title: "States — \(scope)",
                              items: LoTWSubdivisions.usStates.map { AwardItem(code: $0.code, name: $0.name, confirmed: tally.confirmedStates.contains($0.code)) },
                              confirmed: confirmed, worked: tally.states)
            }
            NavigationLink("DXCC entities (\(tally.dxcc.count))") {
                AwardItemList(title: "DXCC — \(scope)",
                              items: tally.dxcc.map { AwardItem(code: String($0), name: LogAwards.entityName($0), confirmed: tally.confirmedDXCC.contains($0)) }
                                  .sorted { $0.name < $1.name },
                              confirmed: confirmed)
            }
        }
    }
}

/// A list of award items. With `worked`, every item is listed and the unworked ones
/// are dimmed (the WAS checklist); otherwise only worked items are given.
struct AwardItemList: View {
    let title: String
    let items: [AwardItem]
    let confirmed: Bool
    var worked: Set<String>?

    var body: some View {
        List {
            if items.isEmpty { Text("None worked yet.").foregroundStyle(ODTheme.muted) }
            ForEach(items) { item in
                let isWorked = worked?.contains(item.code) ?? true
                HStack {
                    Text(item.code).font(.body.monospaced()).frame(minWidth: 56, alignment: .leading)
                    Text(item.name)
                    Spacer()
                    if !isWorked {
                        Text("needed").font(.caption).foregroundStyle(ODTheme.muted)
                    } else if confirmed {
                        Text(item.confirmed ? "confirmed" : "worked").font(.caption)
                            .foregroundStyle(item.confirmed ? ODTheme.good : ODTheme.muted)
                    } else {
                        Image(systemName: "checkmark").foregroundStyle(ODTheme.good)
                    }
                }
                .opacity(isWorked ? 1 : 0.45)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One satellite's QSOs, grids, states and entities.
struct SatelliteAwardsScreen: View {
    @EnvironmentObject private var qso: QSOStore
    let sat: LogAwards.SatelliteTally
    let confirmed: Bool

    private var contacts: [QSORecord] {
        qso.qsos.filter { !$0.isStub && $0.sat.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(sat.name) == .orderedSame }
    }

    var body: some View {
        List {
            Section("Totals") { AwardTotalsView(tally: sat.tally, satellites: nil, confirmed: confirmed) }
            AwardListsSection(tally: sat.tally, confirmed: confirmed, scope: sat.name)
            Section("QSOs") {
                ForEach(contacts) { q in
                    HStack {
                        Text(q.call).font(.subheadline.weight(.semibold))
                        Text(q.gridList.first ?? "").font(.caption).foregroundStyle(ODTheme.muted)
                        Spacer()
                        Text(ODFormat.utcStamp(q.utc)).font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        }
        .navigationTitle(sat.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Log report (PDF)

/// A printable/shareable PDF of the log, filtered by UTC date range and satellite
/// (or limited to the QSOs selected on the Log screen). The share sheet offers Print.
struct LogReportView: View {
    @EnvironmentObject private var qso: QSOStore
    @Environment(\.dismiss) private var dismiss
    /// Restrict to these QSOs (the Log screen's selection); nil = the whole log.
    let onlyIDs: Set<UUID>?

    @State private var useDates = false
    @State private var from = Date().addingTimeInterval(-30 * 86_400)
    @State private var to = Date()
    @State private var sat = ""                 // "" = all satellites
    @State private var shareURL: URL?
    @State private var error: String?

    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    private var satellites: [String] {
        Array(Set(qso.qsos.filter { !$0.isStub && !$0.sat.isEmpty }.map(\.sat))).sorted()
    }

    private var filtered: [QSORecord] {
        let start = Self.utcCal.startOfDay(for: min(from, to))
        let end = Self.utcCal.date(byAdding: .day, value: 1, to: Self.utcCal.startOfDay(for: max(from, to))) ?? to
        return qso.qsos.filter { q in
            guard !q.isStub else { return false }
            if let onlyIDs, !onlyIDs.contains(q.id) { return false }
            if !sat.isEmpty, q.sat != sat { return false }
            if useDates, q.utc < start || q.utc >= end { return false }
            return true
        }
        .sorted { $0.utc < $1.utc }
    }

    var body: some View {
        Form {
            if let onlyIDs {
                Section { Text("\(onlyIDs.count) selected QSO(s)") }
            }
            Section("Filter") {
                Toggle("Limit to dates (UTC)", isOn: $useDates)
                if useDates {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                Picker("Satellite", selection: $sat) {
                    Text("All satellites").tag("")
                    ForEach(satellites, id: \.self) { Text($0).tag($0) }
                }
            }
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            Section {
                Button { makePDF() } label: { Label("Create PDF (\(filtered.count) QSOs)", systemImage: "doc.richtext") }
                    .disabled(filtered.isEmpty)
            } footer: {
                Text("Opens the share sheet — choose Print for AirPrint, or save or send the PDF. Times are UTC. Voice-memo stubs without a callsign are left out.")
            }
        }
        .navigationTitle("Log report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .alert("Log report", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func makePDF() {
        var scope: [String] = []
        if onlyIDs != nil { scope.append("selected QSOs") }
        scope.append(sat.isEmpty ? "all satellites" : sat)
        if useDates {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            scope.append("\(f.string(from: min(from, to))) to \(f.string(from: max(from, to))) UTC")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbitdeck-log.pdf")
        do {
            try LogPDF.log(filtered, myCall: qso.config.myCall, scope: scope.joined(separator: " · ")).write(to: url)
            shareURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - PDF rendering

/// Minimal paginated table renderer (UIGraphicsPDFRenderer) for the log report and
/// the awards summary. Text is truncated to its column; pages carry a footer.
enum LogPDF {
    struct Column { let title: String; let width: CGFloat }
    struct Table { var heading: String?; var columns: [Column]; var rows: [[String]] }

    static func log(_ qsos: [QSORecord], myCall: String, scope: String) -> Data {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "UTC")
        func mhz(_ hz: Int64) -> String { hz > 0 ? String(format: "%.3f", Double(hz) / 1e6) : "" }
        let cols = [Column(title: "UTC", width: 70), Column(title: "Call", width: 60), Column(title: "Satellite", width: 68),
                    Column(title: "Mode", width: 44), Column(title: "Up MHz", width: 48), Column(title: "Down MHz", width: 48),
                    Column(title: "Sent", width: 28), Column(title: "Rcvd", width: 28), Column(title: "Grid", width: 60),
                    Column(title: "St", width: 22), Column(title: "Country", width: 90), Column(title: "Name", width: 120),
                    Column(title: "Flags", width: 34)]
        let rows = qsos.map { q -> [String] in
            let mode = q.effectiveUplinkMode == q.effectiveDownlinkMode ? q.mode : "\(q.effectiveUplinkMode)/\(q.effectiveDownlinkMode)"
            let flags = [q.uploaded.contains(.lotw) ? "L" : nil, q.uploaded.contains(.cloudlog) ? "C" : nil,
                         q.lotwConfirmed ? "Q" : nil].compactMap { $0 }.joined()
            return [f.string(from: q.utc), q.call, q.sat, mode, mhz(q.ulHz), mhz(q.dlHz), q.rstSent, q.rstRcvd,
                    q.gridList.joined(separator: ","), q.state, q.country, q.name, flags]
        }
        let title = "OrbitDeck satellite log" + (myCall.isEmpty ? "" : " — \(myCall.uppercased())")
        let sub = "\(qsos.count) QSOs · \(scope) · Flags: L = sent to LoTW, C = sent to Cloudlog, Q = LoTW confirmed"
        return render(title: title, subtitle: sub, tables: [Table(heading: nil, columns: cols, rows: rows)], landscape: true)
    }

    static func awards(_ a: LogAwards, myCall: String) -> Data {
        let cfm = a.hasConfirmations
        func c(_ n: Int) -> String { cfm ? String(n) : "" }
        func mark(_ on: Bool) -> String { cfm && on ? "Y" : "" }
        func sats(_ has: (LogAwards.Tally) -> Bool) -> String {
            a.satellites.filter { has($0.tally) }.map(\.name).joined(separator: ", ")
        }
        var tables: [Table] = []
        tables.append(Table(heading: "Totals",
                            columns: [Column(title: "Award", width: 220), Column(title: "Worked", width: 80), Column(title: "Confirmed", width: 80)],
                            rows: [["QSOs", String(a.all.qsos), c(a.all.confirmedQSOs)],
                                   ["Satellites", String(a.satellites.count), ""],
                                   ["Grids (VUCC)", String(a.all.grids.count), c(a.all.confirmedGrids.count)],
                                   ["US states (WAS, of \(LogAwards.wasTotal))", String(a.all.states.count), c(a.all.confirmedStates.count)],
                                   ["DXCC entities", String(a.all.dxcc.count), c(a.all.confirmedDXCC.count)]]))
        tables.append(Table(heading: "By satellite",
                            columns: [Column(title: "Satellite", width: 200), Column(title: "QSOs", width: 70), Column(title: "Grids", width: 70),
                                      Column(title: "States", width: 70), Column(title: "DXCC", width: 70)],
                            rows: a.satellites.map { [$0.name, String($0.tally.qsos), String($0.tally.grids.count),
                                                      String($0.tally.states.count), String($0.tally.dxcc.count)] }))
        let stateRows: [[String]] = LoTWSubdivisions.usStates.map { s in
            guard a.all.states.contains(s.code) else { return [s.code, s.name, "", "(needed)"] }
            return [s.code, s.name, mark(a.all.confirmedStates.contains(s.code)), sats { $0.states.contains(s.code) }]
        }
        tables.append(Table(heading: "US states",
                            columns: [Column(title: "State", width: 40), Column(title: "Name", width: 150), Column(title: "Cfm", width: 34),
                                      Column(title: "Satellites", width: 316)],
                            rows: stateRows))
        let dxccRows: [[String]] = a.all.dxcc.sorted { LogAwards.entityName($0) < LogAwards.entityName($1) }.map { d in
            [String(d), LogAwards.entityName(d), mark(a.all.confirmedDXCC.contains(d)), sats { $0.dxcc.contains(d) }]
        }
        tables.append(Table(heading: "DXCC entities",
                            columns: [Column(title: "DXCC", width: 40), Column(title: "Entity", width: 150), Column(title: "Cfm", width: 34),
                                      Column(title: "Satellites", width: 316)],
                            rows: dxccRows))
        let gridRows: [[String]] = a.all.grids.sorted().map { g in [g, mark(a.all.confirmedGrids.contains(g)), sats { $0.grids.contains(g) }] }
        tables.append(Table(heading: "Grids",
                            columns: [Column(title: "Grid", width: 50), Column(title: "Cfm", width: 34), Column(title: "Satellites", width: 456)],
                            rows: gridRows))
        let title = "OrbitDeck awards summary" + (myCall.isEmpty ? "" : " — \(myCall.uppercased())")
        let sub = cfm ? "Worked and LoTW-confirmed (from imported QSL status). A working estimate, not an official award check."
                      : "Worked only — the log has no LoTW confirmation data. A working estimate, not an official award check."
        return render(title: title, subtitle: sub, tables: tables, landscape: false)
    }

    static func render(title: String, subtitle: String, tables: [Table], landscape: Bool) -> Data {
        let page = landscape ? CGRect(x: 0, y: 0, width: 792, height: 612) : CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36, rowH: CGFloat = 12
        let bottom = page.height - margin - 14
        let width = page.width - 2 * margin
        let titleFont = UIFont.boldSystemFont(ofSize: 15), subFont = UIFont.systemFont(ofSize: 9)
        let headFont = UIFont.boldSystemFont(ofSize: 8), cellFont = UIFont.systemFont(ofSize: 8)
        let sectionFont = UIFont.boldSystemFont(ofSize: 11), footFont = UIFont.systemFont(ofSize: 7)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        func attrs(_ f: UIFont, _ c: UIColor = .black) -> [NSAttributedString.Key: Any] {
            [.font: f, .foregroundColor: c, .paragraphStyle: para]
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"; df.timeZone = TimeZone(identifier: "UTC")
        let stamp = df.string(from: Date())
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            var y: CGFloat = 0
            var pageNo = 0
            func newPage() {
                ctx.beginPage()
                pageNo += 1
                y = margin
                if pageNo == 1 {
                    (title as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 20), withAttributes: attrs(titleFont))
                    y += 20
                    (subtitle as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 13), withAttributes: attrs(subFont, .darkGray))
                    y += 20
                }
                let footer = "\(title) · generated \(stamp) · page \(pageNo)"
                (footer as NSString).draw(in: CGRect(x: margin, y: page.height - margin, width: width, height: 12),
                                          withAttributes: attrs(footFont, .gray))
            }
            func drawRow(_ cells: [String], _ cols: [Column], font: UIFont, shade: Bool) {
                let w = cols.reduce(0) { $0 + $1.width }
                if shade {
                    UIColor(white: 0.94, alpha: 1).setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: w, height: rowH))
                }
                var x = margin
                for (i, col) in cols.enumerated() {
                    let text = i < cells.count ? cells[i] : ""
                    (text as NSString).draw(in: CGRect(x: x + 2, y: y + 1.5, width: col.width - 4, height: rowH), withAttributes: attrs(font))
                    x += col.width
                }
                y += rowH
            }
            func header(_ cols: [Column]) {
                drawRow(cols.map(\.title), cols, font: headFont, shade: false)
                UIColor.gray.setFill()
                UIRectFill(CGRect(x: margin, y: y - 0.5, width: cols.reduce(0) { $0 + $1.width }, height: 0.5))
            }
            newPage()
            for table in tables {
                // Keep a heading together with its column header and a few rows.
                if y + 22 + rowH * 3 > bottom { newPage() }
                if let h = table.heading {
                    y += 6
                    (h as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 15), withAttributes: attrs(sectionFont))
                    y += 16
                }
                header(table.columns)
                if table.rows.isEmpty { drawRow(["None"], table.columns, font: cellFont, shade: false) }
                for (i, row) in table.rows.enumerated() {
                    if y + rowH > bottom { newPage(); header(table.columns) }
                    drawRow(row, table.columns, font: cellFont, shade: i % 2 == 1)
                }
                y += 6
            }
        }
    }
}
