import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: OrbitStore
    @StateObject private var locationProvider = LocationProvider()
    @State private var qrzPassword = ""
    @State private var qrzLoaded = false
    @AppStorage("orbitdeck.spacetrack.identity") private var spaceTrackIdentity = ""
    @State private var spaceTrackPassword = ""
    @State private var spaceTrackLoaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: Binding(
                    get: { store.preferences.observer.name },
                    set: { store.preferences.observer.name = $0 }
                ))
                .textFieldStyle(.odField)

                HStack {
                    TextField("Latitude", value: Binding(
                        get: { store.preferences.observer.latitude },
                        set: { store.preferences.observer.latitude = max(-90, min(90, $0)) }
                    ), format: .number.precision(.fractionLength(0...6)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text("°").foregroundStyle(ODTheme.muted)
                }

                HStack {
                    TextField("Longitude", value: Binding(
                        get: { store.preferences.observer.longitude },
                        set: { store.preferences.observer.longitude = Self.normalizedLongitude($0) }
                    ), format: .number.precision(.fractionLength(0...6)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text("°").foregroundStyle(ODTheme.muted)
                }

                HStack {
                    TextField("Altitude", value: Binding(
                        get: { store.preferences.observer.altitudeMeters },
                        set: { store.preferences.observer.altitudeMeters = $0 }
                    ), format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.odField)
                    Text("m").foregroundStyle(ODTheme.muted)
                }

                Button {
                    locationProvider.requestLocation()
                } label: {
                    Label("Use Current Location", systemImage: "location")
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

            Section("About this port") {
                LabeledContent("OrbitDeck iOS", value: "0.9.7")
                LabeledContent("UI", value: "Native SwiftUI")
                LabeledContent("Propagation", value: "SatelliteKit SGP4/SDP4")
                Text("Preferences and the GP cache are stored in the iOS application sandbox. Settings are saved as you change them.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
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

    private static func normalizedLongitude(_ value: Double) -> Double {
        var lon = value.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return lon
    }
}
