import SwiftUI

// ===========================================================================
//  CATViews.swift — CAT configuration screen + Home control card
// ===========================================================================

/// Full CAT setup screen (reached from Settings). Configure one or two radios,
/// their transport (BLE adapter or Icom network), and every tuning option.
struct RigControlSettingsView: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @State private var blePickerSlot: SlotRef?

    /// Identifiable wrapper so `.sheet(item:)` can present the BLE picker per slot.
    private struct SlotRef: Identifiable { let id: Int }

    var body: some View {
        Form {
            Section {
                Toggle("Enable CAT control", isOn: bind(\.enabled))
                Text("Drive your transceiver's frequency (Doppler tuning) from OrbitDeck over a BLE serial adapter or an Icom network (Wi-Fi) connection. Bluetooth Classic (SPP) adapters are not supported on iOS.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            if rig.config.enabled {
                Section("Station") {
                    Toggle("Two radios (separate uplink + downlink)", isOn: bind(\.twoRadios))
                    Text(rig.config.twoRadios
                         ? "Radio 1 controls the downlink, Radio 2 the uplink."
                         : "One radio. A full-duplex satellite rig can drive both the uplink and downlink; a single half-duplex radio controls only the uplink or the downlink.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }

                slotSection(index: 0, title: rig.config.twoRadios ? "Radio 1 — downlink" : "Radio")
                if rig.config.twoRadios { slotSection(index: 1, title: "Radio 2 — uplink") }

                tuningSection
            }
        }
        .navigationTitle("Rig Control (CAT)")
        .navigationBarTitleDisplayMode(.inline)
        // Persist once on exit — writing store.preferences on every keystroke
        // rebuilds the root/detail and would reset this navigation stack.
        .onDisappear { rig.persist() }
        .sheet(item: $blePickerSlot) { ref in
            NavigationStack {
                BLEPickerView(selectedID: rig.config.slots[ref.id].bleIdentifier) { dev in
                    rig.config.slots[ref.id].bleIdentifier = dev.id.uuidString
                    rig.config.slots[ref.id].bleName = dev.name
                }
            }
        }
    }

    // MARK: Slot configuration

    @ViewBuilder private func slotSection(index: Int, title: String) -> some View {
        let slotBind = bindSlot(index)
        let spec = rig.config.slots[index].spec
        Section(title) {
            Toggle("Use this radio", isOn: slotBind.enabled)
            if rig.config.slots[index].enabled {
                Picker("Radio", selection: slotBind.radioID) {
                    Text("Select…").tag("")
                    ForEach(radioChoices(index)) { r in
                        Text(r.name).tag(r.id)
                    }
                }
                .pickerStyle(.menu)

                if !rig.config.twoRadios, let spec, spec.fullDuplex {
                    Picker("Controls", selection: slotBind.role) {
                        ForEach(RigRole.allCases) { Text($0.label).tag($0) }
                    }
                } else if !rig.config.twoRadios {
                    Picker("Controls", selection: slotBind.role) {
                        Text(RigRole.downlink.label).tag(RigRole.downlink)
                        Text(RigRole.uplink.label).tag(RigRole.uplink)
                    }
                }

                if let spec {
                    Picker("Connection", selection: slotBind.transport) {
                        Text(CATTransportKind.ble.label).tag(CATTransportKind.ble)
                        if spec.hasLan { Text(CATTransportKind.network.label).tag(CATTransportKind.network) }
                    }

                    if rig.config.slots[index].transport == .ble {
                        Button {
                            blePickerSlot = SlotRef(id: index)
                        } label: {
                            HStack {
                                Text("BLE adapter")
                                Spacer()
                                Text(rig.config.slots[index].bleName.isEmpty ? "Choose…" : rig.config.slots[index].bleName)
                                    .foregroundStyle(ODTheme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("For CI-V/Yaesu/Kenwood radios, wire a BLE UART adapter to the radio's CAT/CI-V port. Kenwood TH-D74/D75 use the B.B. Link adapter.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    } else {
                        TextField("Radio IP / hostname", text: slotBind.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.odField)
                        Stepper("Control port: \(rig.config.slots[index].port)",
                                value: slotBind.port, in: 1...65535)
                        TextField("Network username", text: slotBind.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.odField)
                        NetworkPasswordField(index: index)
                        Text("The radio's Network Control must be enabled with a User1 login. The password is stored in the iOS Keychain.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }

                    // CI-V address (Icom, any transport) and serial rate (BLE).
                    if spec.family == .civ {
                        HStack {
                            Text("CI-V address (hex)")
                            Spacer()
                            TextField(String(format: "%02X", spec.civAddr), text: civAddrHex(index))
                                .frame(width: 72).multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .textFieldStyle(.odField)
                        }
                    }
                    if rig.config.slots[index].transport == .ble {
                        Picker("Serial rate", selection: baudBinding(index)) {
                            Text(verbatim: "Default (\(spec.defaultBaud))").tag(0)
                            ForEach([1200, 4800, 9600, 19200, 38400, 57600, 115200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        Text("Set your BLE adapter's serial rate to match the radio's CAT rate.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }
            }
        }
    }

    private func civAddrHex(_ i: Int) -> Binding<String> {
        Binding(get: {
            let v = rig.config.slots[i].civAddrOverride
            return v > 0 ? String(format: "%02X", v) : ""
        }, set: { newVal in
            let hex = newVal.trimmingCharacters(in: .whitespaces)
            if hex.isEmpty { rig.config.slots[i].civAddrOverride = 0 }
            else if let v = Int(hex, radix: 16), v > 0, v < 256 { rig.config.slots[i].civAddrOverride = v }
        })
    }
    private func baudBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { rig.config.slots[i].baudOverride },
                set: { rig.config.slots[i].baudOverride = $0 })
    }

    /// Radios offered for a slot. Two-radio uplink (slot 1) excludes RX-only sets;
    /// single-radio mode offers full-duplex sat rigs and single-band radios.
    private func radioChoices(_ index: Int) -> [RadioSpec] {
        if rig.config.twoRadios {
            return index == 1 ? RadioCatalog.mono.filter { !$0.rxOnly } : RadioCatalog.mono
        }
        return RadioCatalog.all
    }

    // MARK: Tuning

    private var tuningSection: some View {
        Section("Tuning") {
            Toggle("Track Doppler", isOn: bindTuning(\.trackDoppler))
            Toggle("Follow radio tuning (One True Rule)", isOn: bindTuning(\.followRadio))
            if rig.config.tuning.followRadio {
                Picker("Follow", selection: bindTuning(\.followLeg)) {
                    Text("Downlink").tag(RigRole.downlink)
                    Text("Uplink").tag(RigRole.uplink)
                }
                Text("Reads the radio so tuning you do on the dial is honored: the followed leg leads and the other leg stays mapped through the transponder, both Doppler-corrected. Requires a radio that reports its frequency (most supported radios do).")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Stepper("Update rate: \(rig.config.tuning.updateMs) ms", value: bindTuning(\.updateMs), in: 100...2000, step: 50)
            Stepper("Command delay: \(rig.config.tuning.commandDelayMs) ms", value: bindTuning(\.commandDelayMs), in: 0...500, step: 10)
            Toggle("MAIN = uplink, SUB = downlink", isOn: bindTuning(\.mainIsUplink))
            Toggle("Command radio satellite mode", isOn: bindTuning(\.satMode))
            Toggle("Assign MAIN/SUB bands (IC-9100/9700)", isOn: bindTuning(\.assignBands))
            Stepper("FM deadband: \(rig.config.tuning.fmDeadbandHz) Hz", value: bindTuning(\.fmDeadbandHz), in: 0...2000, step: 50)
            Stepper("Linear deadband: \(rig.config.tuning.linearDeadbandHz) Hz", value: bindTuning(\.linearDeadbandHz), in: 0...500, step: 10)
            Stepper("Predictive lead: \(rig.config.tuning.leadMs) ms", value: bindTuning(\.leadMs), in: 0...500, step: 10)
            HStack {
                Text("Downlink transverter LO")
                Spacer()
                TextField("Hz", value: bindTuning(\.xvtrDownlinkHz), format: .number).multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation).frame(width: 130).textFieldStyle(.odField)
            }
            HStack {
                Text("Uplink transverter LO")
                Spacer()
                TextField("Hz", value: bindTuning(\.xvtrUplinkHz), format: .number).multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation).frame(width: 130).textFieldStyle(.odField)
            }
            Picker("Uplink CTCSS", selection: bindTuning(\.uplinkToneHz)) {
                Text("Off").tag(0.0)
                ForEach(CTCSS.availableHz, id: \.self) { Text(String(format: "%.1f Hz", $0)).tag($0) }
            }
            Text("Transverter LO offsets, deadbands and lead mirror CardSat. Per-satellite oscillator calibration comes from the Calibrations screen.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    // MARK: Bindings

    private func bind<T>(_ key: WritableKeyPath<CATConfig, T>) -> Binding<T> {
        Binding(get: { rig.config[keyPath: key] },
                set: { rig.config[keyPath: key] = $0 })
    }
    private func bindTuning<T>(_ key: WritableKeyPath<CATTuning, T>) -> Binding<T> {
        Binding(get: { rig.config.tuning[keyPath: key] },
                set: { rig.config.tuning[keyPath: key] = $0 })
    }
    private struct SlotBindings {
        let enabled: Binding<Bool>
        let radioID: Binding<String>
        let role: Binding<RigRole>
        let transport: Binding<CATTransportKind>
        let host: Binding<String>
        let username: Binding<String>
        let port: Binding<Int>
    }
    private func bindSlot(_ i: Int) -> SlotBindings {
        func b<T>(_ key: WritableKeyPath<RigSlot, T>) -> Binding<T> {
            Binding(get: { rig.config.slots[i][keyPath: key] },
                    set: { rig.config.slots[i][keyPath: key] = $0 })
        }
        return SlotBindings(enabled: b(\.enabled), radioID: b(\.radioID), role: b(\.role),
                            transport: b(\.transport), host: b(\.host), username: b(\.username), port: b(\.port))
    }
}

/// SecureField that stores an Icom network password in the Keychain, per slot.
private struct NetworkPasswordField: View {
    let index: Int
    @State private var password = ""
    @State private var loaded = false
    private var secret: OrbitSecret { index == 0 ? .rigPassword0 : .rigPassword1 }

    var body: some View {
        SecureField("Network password", text: $password)
            .textContentType(.password).textFieldStyle(.odField)
            .task { if !loaded { password = OrbitSecretStore.get(secret); loaded = true } }
            .onChange(of: password) { _, v in if loaded { OrbitSecretStore.set(v, for: secret) } }
    }
}

/// BLE device picker backed by a live scan.
struct BLEPickerView: View {
    let selectedID: String
    let onSelect: (BLEDevice) -> Void
    @StateObject private var scanner = BLEScanner()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if !scanner.poweredOn {
                    Text("Turn on Bluetooth to scan for adapters.").foregroundStyle(ODTheme.warning)
                } else if scanner.devices.isEmpty {
                    HStack { ProgressView(); Text("Scanning for BLE adapters…").foregroundStyle(ODTheme.muted) }
                }
                ForEach(scanner.devices) { dev in
                    Button {
                        onSelect(dev); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(dev.name)
                                Text(dev.id.uuidString).font(.caption2.monospaced()).foregroundStyle(ODTheme.muted).lineLimit(1)
                            }
                            Spacer()
                            if dev.id.uuidString == selectedID { Image(systemName: "checkmark").foregroundStyle(ODTheme.accent) }
                            Text("\(dev.rssi)").font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                        }
                    }
                }
            } footer: {
                Text("Pick the BLE UART adapter wired to your radio. Bluetooth Classic (SPP) adapters do not appear — iOS cannot use them.")
            }
        }
        .navigationTitle("BLE adapter")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }
}

// MARK: - Home control card

/// Live CAT control on the Home screen, shown when a radio is configured.
struct HomeRigControlCard: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    let satellite: SatelliteRecord
    /// The transponder currently selected on the Home transponder card — CAT
    /// always tracks the same one, so there is no separate picker here.
    let selectedTransponderID: String?
    /// The passband offset from the Home Doppler card, so CAT tunes to the same
    /// spot the operator scrubbed to.
    let passbandOffsetHz: Double

    var body: some View {
        if rig.config.isConfigured {
            SectionCard("Rig control (CAT)") {
                HStack {
                    Circle().fill(rig.connected ? ODTheme.good : ODTheme.muted).frame(width: 10, height: 10)
                    Text(rig.statusText).font(.caption).foregroundStyle(ODTheme.muted)
                    Spacer()
                    if rig.connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(rig.connected ? "Disconnect" : "Connect") {
                            rig.connected ? rig.disconnect() : rig.connect()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if !rig.errorText.isEmpty {
                    Text(rig.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                if rig.connected {
                    MetricRow("Downlink", ODFormat.frequency(rig.downlinkDialHz), valueColor: ODTheme.good)
                    if rig.uplinkDialHz > 0 {
                        MetricRow("Uplink", ODFormat.frequency(rig.uplinkDialHz), valueColor: ODTheme.warning)
                    }
                    Toggle("Track Doppler", isOn: Binding(
                        get: { rig.config.tuning.trackDoppler },
                        set: { rig.config.tuning.trackDoppler = $0; rig.persist() }
                    ))
                }
                Text("CAT works only while OrbitDeck is in the foreground. Keep the Home screen awake during a pass (Settings ▸ Display).")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
            .onAppear {
                rig.transponderID = selectedTransponderID
                rig.config.tuning.passbandOffsetHz = passbandOffsetHz
            }
            .onChange(of: selectedTransponderID) { _, v in rig.transponderID = v }
            .onChange(of: passbandOffsetHz) { _, v in rig.config.tuning.passbandOffsetHz = v }
        }
    }
}
