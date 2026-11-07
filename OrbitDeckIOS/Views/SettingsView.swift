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
    @AppStorage(LiveActivityController.enabledKey) private var liveActivityEnabled = true
    @EnvironmentObject private var liveActivity: LiveActivityController
    @AppStorage(FeatureVisibility.recorderKey) private var featureRecorder = FeatureVisibility.auto
    @AppStorage(FeatureVisibility.sstvKey) private var featureSSTV = FeatureVisibility.auto
    @AppStorage(FeatureVisibility.ft4Key) private var featureFT4 = FeatureVisibility.auto
    @AppStorage(FeatureVisibility.packetKey) private var featurePacket = FeatureVisibility.auto
    @AppStorage(FeatureVisibility.remoteAudioKey) private var featureRemoteAudio = FeatureVisibility.auto
    @AppStorage(PSKReporterSettings.enabledKey) private var pskReporterEnabled = false
    @AppStorage(FT4Settings.dataModeKey) private var ft4DataMode = true
    @AppStorage(FT4Settings.autoCalibrateKey) private var ft4AutoCal = false
    @AppStorage("orbitdeck.spacetrack.identity") private var spaceTrackIdentity = ""
    @State private var spaceTrackPassword = ""
    @State private var spaceTrackLoaded = false
    @State private var hamsatApiKey = ""
    @State private var hamsatLoaded = false
    @State private var showRigControl = false
    @State private var showRotatorControl = false
    @State private var confirmClearCredentials = false
    @State private var showDiagnostics = false

    /// Editable source URL for the AMSAT / CelesTrak feeds: shows the default until
    /// edited; an edited value overrides it (HTTPS only) until reset.
    @ViewBuilder private func sourceURLField(_ key: WritableKeyPath<StorePreferences, String?>) -> some View {
        let override = store.preferences[keyPath: key] ?? ""
        let shown = override.isEmpty ? GPService.defaultURLString(store.preferences) : override
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Source URL").font(.caption.weight(.semibold))
                Spacer()
                if !override.isEmpty {
                    Button("Reset to default") { store.preferences[keyPath: key] = nil }
                        .font(.caption).buttonStyle(.borderless)
                }
            }
            TextField("https://…", text: Binding(
                get: { shown },
                set: { new in
                    let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.preferences[keyPath: key] = (t.isEmpty || t == GPService.defaultURLString(store.preferences)) ? nil : t
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textFieldStyle(.odField)
            .font(.caption.monospaced())
            if !override.isEmpty {
                Text(URL(string: override)?.scheme?.lowercased() == "https"
                     ? "Using your URL instead of the built-in one. It must return OMM/GP JSON."
                     : "The URL must start with https://.")
                    .font(.caption2)
                    .foregroundStyle(URL(string: override)?.scheme?.lowercased() == "https" ? ODTheme.muted : ODTheme.warning)
            }
        }
    }

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
                    // Stored in meters; entered in the chosen unit (m or ft).
                    TextField("Altitude", value: Binding(
                        get: { ODFormat.usesCustomary ? store.preferences.observer.altitudeMeters * UnitConversion.ftPerM
                                                      : store.preferences.observer.altitudeMeters },
                        set: { store.preferences.observer.altitudeMeters = ODFormat.usesCustomary ? $0 / UnitConversion.ftPerM : $0 }
                    ), format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text(ODFormat.heightUnit).foregroundStyle(ODTheme.muted)
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
                Picker(selection: $featurePacket) {
                    ForEach(FeatureVisibility.allCases) { Text($0.label).tag($0) }
                } label: { Label("Packet / APRS", systemImage: "envelope.badge") }
                .pickerStyle(.menu)
                Picker(selection: $featureRemoteAudio) {
                    ForEach(FeatureVisibility.allCases) { Text($0.label).tag($0) }
                } label: { Label("Remote audio (voice)", systemImage: "mic.and.signal.meter") }
                .pickerStyle(.menu)
                Text("These Home cards normally appear only when a USB or network audio interface is connected. Set one to \u{201C}Always show\u{201D} to use it without an interface (it still prefers USB or network audio, falling back to the built-in microphone — hold the phone near your receiver), or \u{201C}Hidden\u{201D} to keep it off the Home screen even with an interface plugged in.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                Toggle("Use data mode for FT4", isOn: $ft4DataMode)
                Text("When FT4 starts on a data-mode-capable radio, OrbitDeck sets the DATA sub-mode so audio uses the rig's ACC/USB data port, and restores plain SSB when FT4 stops: CI-V USB-D/LSB-D (IC-9700/9100/705/905/7100/7000), Hamlib PKTUSB/PKTLSB via rigctld (any supported radio), and DIG on the Yaesu FT-817/818/857/897. Turn this off if you feed audio through the mic/headphone jack instead.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                Toggle("Auto-calibrate transponder from FT4", isOn: $ft4AutoCal)
                Text("While transmitting FT4 full duplex, OrbitDeck measures where your own decoded signal lands versus your TX audio frequency and folds the difference into this satellite's saved calibration, refining it on every decode of your own signal. Linear transponders only; off by default. Edits the per-satellite calibration you can see on the Calibrations screen.")
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
                Picker("Units", selection: Binding(
                    get: { store.preferences.unitSystem ?? .system },
                    set: { store.preferences.unitSystem = $0 }
                )) {
                    ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
                }
                Text("Distances, altitudes, speeds, lengths and temperatures throughout the app, including the Tools calculators. Automatic follows your iPhone's region (US customary in the United States). Exported files (CSV, JSON, ADIF and PDF reports) stay metric, with the units in their column names, so other software reads them consistently.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                Toggle("Show times in local time", isOn: Binding(
                    get: { store.preferences.useLocalTime ?? false },
                    set: { store.preferences.useLocalTime = $0 }
                ))
                Text("Display all times in your device's local zone instead of UTC. Pass lists also show the other zone. Tiny BASIC always uses UTC.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                Toggle("Next pass on Lock Screen and Dynamic Island", isOn: $liveActivityEnabled)
                    .onChange(of: liveActivityEnabled) { _, _ in Task { await liveActivity.refresh() } }
                Text("A Live Activity counts down to the next AOS, then to LOS. With auto switching on it shows the next satellite from your priority list and when it switches in; otherwise the next pass of any favorite. It refreshes whenever OrbitDeck runs. iOS ends Live Activities after about 8 hours, and opening the app starts a new one.")
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
                    sourceURLField(\.amsatURLOverride)
                case .celestrak:
                    Picker("Group", selection: Binding(
                        get: { store.preferences.celestrakGroup },
                        set: { store.preferences.celestrakGroup = $0 }
                    )) {
                        ForEach(GPService.celestrakGroups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                    .disabled(!(store.preferences.celestrakURLOverride ?? "").isEmpty)
                    sourceURLField(\.celestrakURLOverride)
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

// MARK: - Auto Switching

/// Configuration for SatPC32-style automatic satellite switching: a ranked list
/// of up to 9 priority satellites, the switch-in elevation, the conflict rule, and
/// a simulated 12-hour plan showing which satellite wins each overlap.
struct AutoSwitchView: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var auto: AutoSwitchController
    @State private var adding = false
    @State private var planPasses: [TimelinePass] = []
    @State private var planSpans: [TimelineSpan] = []
    @State private var planEvents: [AutoSwitchEvent] = []
    @State private var planning = false

    private static let planHours = 12.0

    var body: some View {
        List {
            Section {
                Toggle("Automatic satellite switching", isOn: $auto.settings.enabled)
                if auto.settings.enabled {
                    Label(auto.status, systemImage: "arrow.triangle.swap")
                        .font(.subheadline)
                        .foregroundStyle(ODTheme.good)
                    if let event = auto.lastEvent {
                        Text("Last switch: \(name(event.norad)) at \(ODFormat.primaryClock(event.date)) · \(reasonText(event.reason))")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            } footer: {
                Text("Modeled on SatPC32's automatic satellite change. When no priority satellite is being tracked, OrbitDeck selects the highest-priority one as soon as it reaches the switch-in elevation (\(ODFormat.angle(auto.threshold(for: store), decimals: 0))). \(preemptionSummary) When the tracked satellite sets, OrbitDeck falls back to a lower-priority one that is still up. CAT Doppler and the rotator follow the selection.")
            }

            Section {
                if auto.settings.priorities.isEmpty {
                    Text("No priority satellites yet.").foregroundStyle(ODTheme.muted)
                }
                ForEach(Array(auto.settings.priorities.enumerated()), id: \.element) { index, norad in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .frame(width: 22)
                            .foregroundStyle(PassTimeline.color(index))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name(norad))
                            Text(verbatim: "NORAD \(norad)").font(.caption2).foregroundStyle(ODTheme.muted)
                        }
                    }
                }
                .onMove { auto.settings.priorities.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { auto.settings.priorities.remove(atOffsets: $0) }
                if auto.settings.priorities.count < AutoSwitchSettings.maxPriorities {
                    Button { adding = true } label: { Label("Add satellite", systemImage: "plus.circle") }
                }
            } header: {
                Text("Priority order")
            } footer: {
                Text("1 is the highest priority. Drag to reorder (or tap Edit); swipe to remove. Up to \(AutoSwitchSettings.maxPriorities), as in SatPC32.")
            }

            Section {
                Toggle("Use pass-prediction minimum (\(ODFormat.angle(store.preferences.minElevation, decimals: 0)))",
                       isOn: $auto.settings.useGlobalMinElevation)
                if !auto.settings.useGlobalMinElevation {
                    Stepper(value: $auto.settings.minElevation, in: -10...60, step: 1) {
                        Text("Switch-in elevation: \(ODFormat.angle(auto.settings.minElevation, decimals: 0))")
                    }
                }
                Picker("Higher priority rises", selection: $auto.settings.preemption) {
                    Text("Switch immediately").tag(AutoSwitchSettings.Preemption.atRise)
                    Text("Finish current pass").tag(AutoSwitchSettings.Preemption.afterPass)
                }
                if auto.settings.preemption == .atRise {
                    Stepper(value: $auto.settings.preemptElevation, in: -10...10, step: 1) {
                        Text("Take over at: \(ODFormat.angle(auto.settings.preemptElevation, decimals: 0))")
                    }
                }
                Toggle("Pause after a manual selection", isOn: $auto.settings.holdManualSelection)
            } header: {
                Text("Rules")
            } footer: {
                Text("\"Take over at\" is the elevation a rising higher-priority satellite must reach: SatPC32 uses 0° (AOS); a negative value such as −5° switches early so the rotator and radio are already on it when it clears the horizon. \"Switch immediately\" is SatPC32's behavior. SatPC32 also overrides a manual pick whenever a higher-priority satellite is up; turn on \"Pause after a manual selection\" to keep your pick while it's above the horizon (or for 15 minutes if it isn't).")
            }

            if !auto.settings.priorities.isEmpty {
                Section {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        PassTimelineChart(passes: planPasses,
                                          start: context.date.addingTimeInterval(-900),
                                          end: context.date.addingTimeInterval(Self.planHours * 3600),
                                          now: context.date,
                                          minElevation: auto.threshold(for: store),
                                          spans: planSpans,
                                          highlighted: store.selectedSatellite?.id)
                            .task(id: planKey(context.date)) { await plan(from: context.date) }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    if planning && planEvents.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if planEvents.isEmpty {
                        Text("No switches in the next \(Int(Self.planHours)) hours.").foregroundStyle(ODTheme.muted)
                    }
                    ForEach(planEvents) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(ODFormat.primaryClock(event.date))
                                .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                                .frame(width: 92, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name(event.norad)).font(.subheadline.weight(.semibold))
                                Text(reasonText(event.reason)).font(.caption).foregroundStyle(reasonColor(event.reason))
                            }
                        }
                    }
                } header: {
                    Text("Planned switching · next \(Int(Self.planHours)) h")
                } footer: {
                    Text("Simulated with the current rules. The strip under the curves shows which satellite would be selected while it is up; orange entries are conflicts resolved by priority.")
                }
            }
        }
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) {
            AutoSwitchAddSheet(excluded: Set(auto.settings.priorities)) { norad in
                if auto.settings.priorities.count < AutoSwitchSettings.maxPriorities,
                   !auto.settings.priorities.contains(norad) {
                    auto.settings.priorities.append(norad)
                }
            }
        }
    }

    private func name(_ norad: UInt) -> String {
        store.satellites.first { $0.id == norad }?.name ?? "NORAD \(norad)"
    }

    /// The take-over rule as currently configured, for the footer.
    private var preemptionSummary: String {
        let s = auto.settings
        guard s.preemption == .atRise else {
            return "If a higher-priority satellite rises during another's pass, OrbitDeck finishes the current pass first."
        }
        let lost = s.preemptElevation > 0 ? "" : " so none of its pass is lost"
        return "If a higher-priority satellite rises during another's pass, it takes over \(s.takeOverPhrase)\(lost)."
    }

    private func reasonText(_ reason: AutoSwitchReason) -> String {
        switch reason {
        case .reachedMinimum:
            return "reaches \(ODFormat.angle(auto.threshold(for: store), decimals: 0))"
        case .preempted(let other):
            return "takes over from \(name(other)) \(auto.settings.takeOverPhrase) (higher priority)"
        case .fellBack(let other):
            return "\(name(other)) set; still in range"
        }
    }

    private func reasonColor(_ reason: AutoSwitchReason) -> Color {
        if case .preempted = reason { return ODTheme.warn }
        return ODTheme.muted
    }

    private func planKey(_ now: Date) -> String {
        let s = auto.settings
        let slot = Int(now.timeIntervalSince1970 / 600)   // re-plan every 10 minutes
        return "\(s.priorities)-\(auto.threshold(for: store))-\(s.preemption.rawValue)-\(s.preemptElevation)-\(store.preferences.observer.stableKey)-\(slot)"
    }

    @MainActor
    private func plan(from now: Date) async {
        let records = auto.settings.priorities.compactMap { id in store.satellites.first { $0.id == id } }
        guard !records.isEmpty else { planPasses = []; planSpans = []; planEvents = []; return }
        let observer = store.preferences.observer
        let threshold = auto.threshold(for: store)
        let preemption = auto.settings.preemption
        let preemptElevation = auto.settings.preemptElevation
        let initial = store.preferences.selectedNorad
        let start = now.addingTimeInterval(-900)
        // Look-back (15 min) + span + one 10-minute re-plan slot of headroom.
        let hours = Self.planHours + 0.25 + 1.0 / 6
        planning = true
        let result = await Task.detached(priority: .utility) {
            AutoSwitchController.plan(priorities: records, observer: observer, from: start,
                                      hours: hours, threshold: threshold,
                                      preemption: preemption, preemptElevation: preemptElevation,
                                      initial: initial)
        }.value
        planning = false
        planPasses = result.passes
        planSpans = result.spans
        // Only list switches from now on; the look-back is just for the chart.
        planEvents = result.events.filter { $0.date >= now }
    }
}

/// Searchable catalog picker for adding a priority satellite (favorites first).
private struct AutoSwitchAddSheet: View {
    @EnvironmentObject private var store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<UInt>
    let onPick: (UInt) -> Void
    @State private var search = ""

    private var satellites: [SatelliteRecord] {
        let favorites = store.preferences.favorites
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.satellites
            .filter { !excluded.contains($0.id) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || String($0.id).contains(q) }
            .sorted { a, b in
                let fa = favorites.contains(a.id), fb = favorites.contains(b.id)
                if fa != fb { return fa }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            List(satellites) { sat in
                Button {
                    onPick(sat.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(sat.name).foregroundStyle(.primary)
                        Spacer()
                        if store.preferences.favorites.contains(sat.id) {
                            Image(systemName: "star.fill").foregroundStyle(ODTheme.warn)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Name or NORAD")
            .navigationTitle("Add priority satellite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
