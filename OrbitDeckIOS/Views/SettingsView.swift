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
    @AppStorage("orbitdeck.spacetrack.identity") private var spaceTrackIdentity = ""
    @State private var spaceTrackPassword = ""
    @State private var spaceTrackLoaded = false

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
        .task {
            if !qrzLoaded {
                qrzPassword = OrbitSecretStore.get(.qrzPassword)
                qrzLoaded = true
            }
            if !spaceTrackLoaded {
                spaceTrackPassword = OrbitSecretStore.get(.spaceTrackPassword)
                spaceTrackLoaded = true
            }
        }
        .onChange(of: qrzPassword) { _, newValue in
            if qrzLoaded { OrbitSecretStore.set(newValue, for: .qrzPassword) }
        }
        .onChange(of: spaceTrackPassword) { _, newValue in
            if spaceTrackLoaded { OrbitSecretStore.set(newValue, for: .spaceTrackPassword) }
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
