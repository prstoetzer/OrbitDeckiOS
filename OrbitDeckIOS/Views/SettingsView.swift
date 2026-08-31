import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: OrbitStore
    @StateObject private var locationProvider = LocationProvider()
    @State private var qrzPassword = ""
    @State private var qrzLoaded = false
    @State private var gridEntry = ""
    @State private var gridMessage: String?
    @AppStorage("orbitdeck.keepScreenAwakeHome") private var keepScreenAwakeHome = false
    @AppStorage(FeatureVisibility.recorderKey) private var featureRecorder = FeatureVisibility.auto
    @AppStorage(FeatureVisibility.sstvKey) private var featureSSTV = FeatureVisibility.auto
    @AppStorage(FeatureVisibility.ft4Key) private var featureFT4 = FeatureVisibility.auto
    @AppStorage(PSKReporterSettings.enabledKey) private var pskReporterEnabled = false
    @AppStorage(FT4Settings.dataModeKey) private var ft4DataMode = true
    @AppStorage("orbitdeck.spacetrack.identity") private var spaceTrackIdentity = ""
    @State private var spaceTrackPassword = ""
    @State private var spaceTrackLoaded = false
    @State private var hamsatApiKey = ""
    @State private var hamsatLoaded = false
    @State private var showRigControl = false
    @State private var showRotatorControl = false
    @State private var confirmClearCredentials = false
    @State private var showDiagnostics = false

    var body: some View {
        Form {
            Section {
                Picker("Location source", selection: Binding(
                    get: { store.locationMode },
                    set: { store.setLocationMode($0) }
                )) {
                    Text("Fixed site").tag(LocationMode.fixed)
                    Text("Always use current location").tag(LocationMode.currentLocation)
                }

                let following = store.locationMode == .currentLocation

                TextField("Name", text: Binding(
                    get: { store.preferences.observer.name },
                    set: { store.preferences.observer.name = $0 }
                ))
                .textFieldStyle(.odField)
                .disabled(following)

                HStack {
                    TextField("Latitude", value: Binding(
                        get: { store.preferences.observer.latitude },
                        set: { store.preferences.observer.latitude = max(-90, min(90, $0)) }
                    ), format: .number.precision(.fractionLength(0...6)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text("°").foregroundStyle(ODTheme.muted)
                }
                .disabled(following)

                HStack {
                    TextField("Longitude", value: Binding(
                        get: { store.preferences.observer.longitude },
                        set: { store.preferences.observer.longitude = Self.normalizedLongitude($0) }
                    ), format: .number.precision(.fractionLength(0...6)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text("°").foregroundStyle(ODTheme.muted)
                }
                .disabled(following)

                HStack {
                    TextField("Altitude", value: Binding(
                        get: { store.preferences.observer.altitudeMeters },
                        set: { store.preferences.observer.altitudeMeters = $0 }
                    ), format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text("m").foregroundStyle(ODTheme.muted)
                }
                .disabled(following)

                // Enter a station as a Maidenhead grid square (4/6/8 characters).
                HStack {
                    TextField("Grid square (e.g. FM18lv)", text: $gridEntry)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.odField)
                    Button("Set") { applyGrid() }
                        .buttonStyle(.bordered)
                        .disabled(gridEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .disabled(following)

                LabeledContent("Station grid", value: store.operatorGrid6)
                if let gridMessage {
                    Text(gridMessage).font(.caption).foregroundStyle(ODTheme.muted)
                }

                if following {
                    Label("Following device location. Coordinates update automatically.",
                          systemImage: "location.fill")
                        .font(.caption).foregroundStyle(ODTheme.accent)
                    // Reverse-geocoded DXCC entity and administrative subdivisions
                    // for the current position.
                    CurrentLocationEntityInfo { info in
                        LabeledContent("DXCC", value: info.dxccLabel ?? "—")
                        if let primary = info.primarySubdivision {
                            LabeledContent("Primary subdivision", value: primary)
                        }
                        if let secondary = info.secondarySubdivision {
                            LabeledContent("Secondary subdivision", value: secondary)
                        }
                    }
                } else {
                    Button {
                        locationProvider.requestLocation()
                    } label: {
                        Label("Use Current Location", systemImage: "location")
                    }
                }

                if let error = locationProvider.errorMessage {
                    Text(error).font(.caption).foregroundStyle(ODTheme.warning)
                }
            } header: {
                Text("Observer station")
            } footer: {
                Text("Changes are saved automatically.").font(.caption)
            }

            Section("Operator identity") {
                TextField("Callsign", text: Binding(
                    get: { store.preferences.callsign ?? "" },
                    set: { store.preferences.callsign = $0 }
                ))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.odField)
                LabeledContent("Station grid", value: store.operatorGrid)
                Text("Your callsign and current station grid are used only when you explicitly confirm an attributed AMSAT status report.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("QRZ XML API") {
                TextField("QRZ username", text: Binding(
                    get: { store.preferences.qrzUsername ?? "" },
                    set: { store.preferences.qrzUsername = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.odField)
                SecureField("QRZ password", text: $qrzPassword)
                    .textContentType(.password)
                    .textFieldStyle(.odField)
                Text("The QRZ username is stored with OrbitDeck preferences. The password is stored in the iOS Keychain, not in the preferences JSON.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("hams.at") {
                SecureField("hams.at API key", text: $hamsatApiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.odField)
                Text("From your hams.at Settings page. Used only to post activation alerts you explicitly confirm. Stored in the iOS Keychain, not in the preferences JSON.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Rig control") {
                Button {
                    showRigControl = true
                } label: {
                    Label("CAT / rig control", systemImage: "antenna.radiowaves.left.and.right")
                }
                Text("Doppler-tune your transceiver from OrbitDeck over a BLE serial adapter or an Icom network (Wi-Fi) connection. Control is on the Home screen once a radio is configured.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Rotator control") {
                Button {
                    showRotatorControl = true
                } label: {
                    Label("Antenna rotator", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                Text("Point an az/el rotator at the selected satellite over a BLE serial adapter (GS-232, Easycomm, SPID) or a network connection (rotctld, PstRotator). Control is on the Home screen once a rotator is configured.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Audio features") {
                Picker(selection: $featureRecorder) {
                    ForEach(FeatureVisibility.allCases) { Text($0.label).tag($0) }
                } label: { Label("Pass recording", systemImage: "waveform.badge.mic") }
                .pickerStyle(.menu)
                Picker(selection: $featureSSTV) {
                    ForEach(FeatureVisibility.allCases) { Text($0.label).tag($0) }
                } label: { Label("SSTV decode", systemImage: "photo") }
                .pickerStyle(.menu)
                Picker(selection: $featureFT4) {
                    ForEach(FeatureVisibility.allCases) { Text($0.label).tag($0) }
                } label: { Label("FT4", systemImage: "dot.radiowaves.left.and.right") }
                .pickerStyle(.menu)
                Text("These Home cards normally appear only when a USB or network audio interface is connected. Set one to \u{201C}Always show\u{201D} to use it without an interface (it still prefers USB or network audio, falling back to the built-in microphone — hold the phone near your receiver), or \u{201C}Hidden\u{201D} to keep it off the Home screen even with an interface plugged in.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                Toggle("Use data mode for FT4", isOn: $ft4DataMode)
                Text("When FT4 starts on a data-mode-capable radio, OrbitDeck sets the DATA sub-mode so audio uses the rig's ACC/USB data port, and restores plain SSB when FT4 stops: CI-V USB-D/LSB-D (IC-9700/9100/705/905/7100/7000), Hamlib PKTUSB/PKTLSB via rigctld (any supported radio), and DIG on the Yaesu FT-817/818/857/897. Turn this off if you feed audio through the mic/headphone jack instead.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("PSKReporter") {
                Toggle("Upload FT4 reception reports", isOn: $pskReporterEnabled)
                Text("When on, OrbitDeck sends the FT4 stations you decode through satellites to PSKReporter (pskreporter.info) so they appear on its public spotting map. Reports include your callsign, grid, the decoded station's callsign/grid, the downlink frequency, SNR, and time. Requires your callsign and grid to be set. Off by default; no reports are sent unless you enable this.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Space-Track") {
                TextField("Space-Track identity / email", text: $spaceTrackIdentity)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.odField)
                SecureField("Space-Track password", text: $spaceTrackPassword)
                    .textContentType(.password)
                    .textFieldStyle(.odField)
                Text("Used by Orbital History to fetch archival elements. The identity is stored on-device; the password is kept in the iOS Keychain.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Saved credentials") {
                Button(role: .destructive) { confirmClearCredentials = true } label: {
                    Label("Clear all saved passwords & keys", systemImage: "key.slash")
                }
                Text("Removes every OrbitDeck password and API key (QRZ, hams.at, Space-Track, rig network, LoTW, Cloudlog) from the iOS Keychain. Keychain entries persist even if you delete the app, so use this to wipe them before handing the device on or switching accounts.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Diagnostics") {
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostic logs", systemImage: "doc.text.magnifyingglass")
                }
                Text("Records rig, audio, and network activity so you can share a log file with the developer when troubleshooting.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Pass prediction") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum elevation")
                        Spacer()
                        Text(ODFormat.angle(store.preferences.minElevation)).font(.body.monospacedDigit())
                    }
                    Slider(value: Binding(
                        get: { store.preferences.minElevation },
                        set: { store.preferences.minElevation = $0 }
                    ), in: 0...45, step: 1)
                }

                Picker("Pass alarm lead", selection: Binding(
                    get: { store.preferences.passAlarmLeadMinutes ?? 10 },
                    set: { store.preferences.passAlarmLeadMinutes = $0 }
                )) {
                    Text("At AOS").tag(0)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                }
                Text("Notification permission is requested only when you schedule an alarm from Exports.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section {
                Toggle("Show times in local time", isOn: Binding(
                    get: { store.preferences.useLocalTime ?? false },
                    set: { store.preferences.useLocalTime = $0 }
                ))
                Text("Display all times in your device's local zone instead of UTC. Pass lists also show the other zone. Tiny BASIC always uses UTC.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                Toggle("Keep screen awake on Home", isOn: $keepScreenAwakeHome)
                Text("Prevents auto-lock while the Home screen is showing, so you can leave it up as a live display during a pass. The rest of the app auto-locks normally.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } header: {
                Text("Display")
            }

            Section("GP element source") {
                Picker("Source", selection: Binding(
                    get: { store.preferences.sourceKind },
                    set: { store.preferences.sourceKind = $0 }
                )) {
                    ForEach(GPSourceKind.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }

                switch store.preferences.sourceKind {
                case .amsat:
                    Text("Uses the AMSAT daily bulletin GP JSON feed.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                case .celestrak:
                    Picker("Group", selection: Binding(
                        get: { store.preferences.celestrakGroup },
                        set: { store.preferences.celestrakGroup = $0 }
                    )) {
                        ForEach(GPService.celestrakGroups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                case .custom:
                    TextField("OMM JSON URL", text: Binding(
                        get: { store.preferences.customURL },
                        set: { store.preferences.customURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.odField)
                }

                Button {
                    Task { await store.refreshGP() }
                } label: {
                    HStack {
                        Label("Update GP now", systemImage: "arrow.triangle.2.circlepath")
                        if store.isRefreshingGP {
                            Spacer()
                            ProgressView().accessibilityLabel("Updating GP data")
                        }
                    }
                }
                .disabled(store.isRefreshingGP)

                if !store.statusMessage.isEmpty {
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(store.lastError == nil ? ODTheme.muted : ODTheme.warning)
                }
            }
        }
        .sheet(isPresented: $showRigControl) {
            NavigationStack {
                RigControlSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showRigControl = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showRotatorControl) {
            NavigationStack {
                RotatorSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showRotatorControl = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                DebugLogScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDiagnostics = false }
                        }
                    }
            }
        }
        .task {
            if !qrzLoaded {
                qrzPassword = OrbitSecretStore.get(.qrzPassword)
                qrzLoaded = true
            }
            if !spaceTrackLoaded {
                spaceTrackPassword = OrbitSecretStore.get(.spaceTrackPassword)
                spaceTrackLoaded = true
            }
            if !hamsatLoaded {
                hamsatApiKey = OrbitSecretStore.get(.hamsatApiKey)
                hamsatLoaded = true
            }
        }
        .confirmationDialog("Clear all saved passwords & keys?", isPresented: $confirmClearCredentials, titleVisibility: .visible) {
            Button("Clear credentials", role: .destructive) {
                OrbitSecretStore.clearAll()
                qrzPassword = ""; spaceTrackPassword = ""; hamsatApiKey = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every stored OrbitDeck password and API key from the Keychain. You'll need to re-enter them to use those services.")
        }
        .onChange(of: qrzPassword) { _, newValue in
            if qrzLoaded { OrbitSecretStore.set(newValue, for: .qrzPassword) }
        }
        .onChange(of: spaceTrackPassword) { _, newValue in
            if spaceTrackLoaded { OrbitSecretStore.set(newValue, for: .spaceTrackPassword) }
        }
        .onChange(of: hamsatApiKey) { _, newValue in
            if hamsatLoaded { OrbitSecretStore.set(newValue, for: .hamsatApiKey) }
        }
        .onChange(of: locationProvider.location) { _, _ in
            guard let location = locationProvider.location else { return }
            store.preferences.observer.latitude = location.coordinate.latitude
            store.preferences.observer.longitude = Self.normalizedLongitude(location.coordinate.longitude)
            store.preferences.observer.altitudeMeters = location.altitude
        }
    }

    private func applyGrid() {
        let entry = gridEntry.trimmingCharacters(in: .whitespaces)
        guard let ll = FeatureEngine.gridToLatLon(entry) else {
            gridMessage = "Enter a valid Maidenhead grid (e.g. FM18 or FM18lv)."
            return
        }
        store.preferences.observer.latitude = ll.latitude
        store.preferences.observer.longitude = ll.longitude
        gridMessage = "Station set to \(FeatureEngine.latLonToGrid6(latitude: ll.latitude, longitude: ll.longitude))."
        gridEntry = ""
    }

    private static func normalizedLongitude(_ value: Double) -> Double {
        var lon = value.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return lon
    }
}

/// About screen: credits and a request to support AMSAT, mirroring the
/// OrbitDeck desktop's About panel (Paul Stoetzer, N8HM).
struct AboutView: View {
    private let amsatURL = URL(string: "https://www.amsat.org")!
    private let projectURL = URL(string: "https://orbitdeckios.n8hm.radio")!

    // Read from the bundle so the About page tracks the project's version/build
    // automatically instead of drifting out of sync with a hardcoded string.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OrbitDeck").font(.title2.bold())
                    Text("Version \(appVersion) (\(appBuild)) · iOS").font(.caption).foregroundStyle(ODTheme.muted)
                    Text("A native tracker and orbital-analysis tool for amateur radio satellites.")
                        .font(.subheadline).padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section("Author") {
                LabeledContent("Author", value: "Paul Stoetzer, N8HM")
            }

            Section("Project") {
                Link(destination: projectURL) {
                    Label("orbitdeckios.n8hm.radio", systemImage: "link")
                }
                Text("Features, documentation, and privacy policy.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section("Support AMSAT") {
                Text("If you find OrbitDeck useful, please consider joining and/or donating to AMSAT — the Radio Amateur Satellite Corporation. AMSAT is a volunteer, member-supported non-profit that designs, builds, and helps launch the amateur radio satellites this program is built to track, and works to keep amateur radio in space. Your membership and donations directly fund the next generation of satellites.")
                    .font(.callout)
                Link(destination: amsatURL) {
                    Label("www.amsat.org", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            Section("Build info") {
                LabeledContent("OrbitDeck iOS", value: "\(appVersion) (\(appBuild))")
                LabeledContent("UI", value: "Native SwiftUI")
                LabeledContent("Propagation", value: "SatelliteKit SGP4/SDP4")
                Text("Preferences and the GP cache are stored in the iOS application sandbox. Settings are saved as you change them.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section {
                Text("MIT License · Copyright © 2026 Paul Stoetzer, N8HM")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
    }
}

// MARK: - Per-satellite radio calibrations

/// Bulk editor for the operator's per-satellite radio calibration (Hz). Favorites
/// are listed first; each row edits the downlink/uplink offsets that fold into the
/// receive dial on every Doppler screen. Supports CSV import/export for bulk entry.
struct CalibrationsView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var search = ""
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var status = ""

    private var satellites: [SatelliteRecord] {
        let favorites = store.preferences.favorites
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.satellites
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || String($0.id).contains(q) }
            .sorted { a, b in
                let fa = favorites.contains(a.id), fb = favorites.contains(b.id)
                if fa != fb { return fa }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        List {
            Section {
                Text("Per-satellite transceiver calibration. Both offsets fold into the receive dial on every Doppler screen (uplink sign-flipped for inverting transponders); nothing is added to the transmit dial.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section {
                HStack {
                    Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button { importing = true } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }
                }
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share calibrations.csv", systemImage: "square.and.arrow.up") }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(ODTheme.muted) }
                Text("CSV columns: norad, name, downlink_hz, uplink_hz (name optional).")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }

            Section {
                TextField("Filter by name or NORAD", text: $search)
                    .textInputAutocapitalization(.characters)
                    .textFieldStyle(.odField)
            }

            Section("Satellites (\(satellites.count))") {
                if store.satellites.isEmpty {
                    Text("No catalog loaded.").foregroundStyle(ODTheme.muted)
                } else {
                    ForEach(satellites) { sat in
                        calibrationRow(sat)
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            importCSV(result)
        }
    }

    @ViewBuilder private func calibrationRow(_ sat: SatelliteRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if store.preferences.favorites.contains(sat.id) {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(ODTheme.warning)
                }
                Text(sat.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: "#\(sat.id)").font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
            }
            HStack(spacing: 8) {
                Text("DL").font(.caption).foregroundStyle(ODTheme.muted)
                TextField("Hz", value: dlBinding(sat.id), format: .number)
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    .textFieldStyle(.odField).frame(width: 100)
                Text("UL").font(.caption).foregroundStyle(ODTheme.muted)
                TextField("Hz", value: ulBinding(sat.id), format: .number)
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    .textFieldStyle(.odField).frame(width: 100)
                Text("Hz").font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
        .padding(.vertical, 2)
    }

    private func dlBinding(_ norad: UInt) -> Binding<Double> {
        Binding(get: { store.calibration(for: norad).downlinkHz },
                set: { var c = store.calibration(for: norad); c.downlinkHz = $0; store.setCalibration(c, for: norad) })
    }
    private func ulBinding(_ norad: UInt) -> Binding<Double> {
        Binding(get: { store.calibration(for: norad).uplinkHz },
                set: { var c = store.calibration(for: norad); c.uplinkHz = $0; store.setCalibration(c, for: norad) })
    }

    private func exportCSV() {
        var lines = ["norad,name,downlink_hz,uplink_hz"]
        for sat in store.satellites.sorted(by: { $0.id < $1.id }) {
            let c = store.calibration(for: sat.id)
            guard !c.isZero else { continue }
            let name = sat.name.replacingOccurrences(of: ",", with: " ")
            lines.append("\(sat.id),\(name),\(Int(c.downlinkHz.rounded())),\(Int(c.uplinkHz.rounded()))")
        }
        guard lines.count > 1 else { status = "No non-zero calibrations to export."; return }
        do {
            shareURL = try OrbitExportService.temporaryTextFile(name: "calibrations.csv", text: lines.joined(separator: "\n"))
            status = "Exported \(lines.count - 1) calibration(s)."
        } catch { status = error.localizedDescription }
    }

    private func importCSV(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                status = "Could not read the file."; return
            }
            var count = 0
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 3, let norad = UInt(fields[0]) else { continue } // skip header/blank
                // norad,name,dl,ul  OR  norad,dl,ul
                let dl: Double, ul: Double
                if fields.count >= 4, Double(fields[1]) == nil {
                    dl = Double(fields[2]) ?? 0; ul = Double(fields[3]) ?? 0
                } else {
                    dl = Double(fields[1]) ?? 0; ul = Double(fields[2]) ?? 0
                }
                store.setCalibration(RadioCalibration(downlinkHz: dl, uplinkHz: ul), for: norad)
                count += 1
            }
            status = "Imported \(count) calibration(s)."
        case .failure(let error):
            status = error.localizedDescription
        }
    }
}
