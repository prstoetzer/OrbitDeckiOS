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
        let slot = rig.config.slots[index]
        let catalogSpec = RadioCatalog.spec(id: slot.radioID)   // real radio; nil for rigctld/none
        Section(title) {
            Toggle("Use this radio", isOn: slotBind.enabled)
            if slot.enabled {
                // Radio model first (user preference). rigctld ignores it — Hamlib
                // abstracts the rig — so the picker is hidden for that transport.
                if slot.transport != .rigctld {
                    Picker("Radio", selection: slotBind.radioID) {
                        Text("Select…").tag("")
                        ForEach(radioChoices(index)) { r in
                            Text(r.name).tag(r.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Connection type. Icom network only appears for LAN-capable radios.
                Picker("Connection", selection: transportBinding(index)) {
                    Text(CATTransportKind.ble.label).tag(CATTransportKind.ble)
                    if catalogSpec?.hasLan == true { Text(CATTransportKind.network.label).tag(CATTransportKind.network) }
                    Text(CATTransportKind.rigctld.label).tag(CATTransportKind.rigctld)
                }

                if slot.transport == .rigctld {
                    rigctldSlotFields(index: index)
                } else {
                    radioSlotFields(index: index, spec: catalogSpec)
                }
            }
        }
    }

    /// Fields for a Hamlib rigctld link: role (single-radio), host and port, and
    /// the split-VFO toggle for full duplex. No catalog radio — Hamlib abstracts it.
    @ViewBuilder private func rigctldSlotFields(index: Int) -> some View {
        let slotBind = bindSlot(index)
        let slot = rig.config.slots[index]
        if !rig.config.twoRadios {
            Picker("Controls", selection: slotBind.role) {
                ForEach(RigRole.allCases) { Text($0.label).tag($0) }
            }
        }
        TextField("rigctld host / IP", text: slotBind.host)
            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.odField)
        portField(index, label: "Port")
        if rig.config.twoRadios == false, slot.role == .both {
            Toggle("Use split VFO for full duplex", isOn: bindTuning(\.rigctldUseSplit))
        }
        Text("Drives any radio through a Hamlib rigctld server on your network (default port 4532). Run rigctld on a computer connected to the radio; full duplex uses the radio's split/TX VFO.")
            .font(.caption).foregroundStyle(ODTheme.muted)
    }

    /// Fields for a catalog radio over BLE or Icom network (the original flow).
    @ViewBuilder private func radioSlotFields(index: Int, spec: RadioSpec?) -> some View {
        let slotBind = bindSlot(index)
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
                        portField(index, label: "Control port")
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

    /// Transport picker binding that fills in the right default port when switching
    /// to a network protocol (Icom 50001, rigctld 4532), so the Stepper starts sane.
    private func transportBinding(_ i: Int) -> Binding<CATTransportKind> {
        Binding(get: { rig.config.slots[i].transport }, set: { newT in
            rig.config.slots[i].transport = newT
            // Fill the standard port for the chosen protocol unless the user has
            // set a non-default one. Icom network = 50001, rigctld = 4532.
            let p = rig.config.slots[i].port
            switch newT {
            case .rigctld: if p == 0 || p == 50001 { rig.config.slots[i].port = 4532 }
            case .network: if p == 0 || p == 4532 { rig.config.slots[i].port = 50001 }
            case .ble: break
            }
        })
    }

    /// Numeric port entry via keyboard. The default is pre-filled when the
    /// connection type changes (see transportBinding), so this starts sane.
    @ViewBuilder private func portField(_ i: Int, label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("Port", value: bindSlot(i).port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.odField)
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
                Stepper("Dial settle: \(rig.config.tuning.followSettleMs) ms", value: bindTuning(\.followSettleMs), in: 0...1500, step: 50)
                Stepper("Uplink resume: \(rig.config.tuning.followUplinkResumeMs) ms", value: bindTuning(\.followUplinkResumeMs), in: 0...3000, step: 100)
                Text("How long Doppler pauses on the leg you just tuned so it doesn't fight you mid-turn, then resumes.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Stepper("Update rate: \(rig.config.tuning.updateMs) ms", value: bindTuning(\.updateMs), in: 100...2000, step: 50)
            Stepper("Command delay: \(rig.config.tuning.commandDelayMs) ms", value: bindTuning(\.commandDelayMs), in: 0...500, step: 10)
            Toggle("MAIN = uplink, SUB = downlink", isOn: bindTuning(\.mainIsUplink))
            Toggle("Command radio satellite mode", isOn: bindTuning(\.satMode))
            Toggle("Assign MAIN/SUB bands (IC-9100/9700)", isOn: bindTuning(\.assignBands))
            Stepper("FM deadband: \(rig.config.tuning.fmDeadbandHz) Hz", value: bindTuning(\.fmDeadbandHz), in: 0...2000, step: 50)
            Stepper("Linear deadband: \(rig.config.tuning.linearDeadbandHz) Hz", value: bindTuning(\.linearDeadbandHz), in: 0...500, step: 10)
            Toggle("Narrow FM on FM satellites", isOn: bindTuning(\.narrowFM))
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

/// Shared one-line status header used by the rig and rotator Home cards: a
/// connection dot, a status line (+ optional subtitle), and the connect/disconnect
/// control — keeping both cards visually consistent.
struct ControlStatusHeader: View {
    let title: String
    let subtitle: String?
    let dot: Color
    let connected: Bool
    let connecting: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(ODTheme.muted).lineLimit(1)
                }
            }
            Spacer()
            if connecting {
                ProgressView().controlSize(.small)
            } else {
                Button(connected ? "Disconnect" : "Connect", action: onToggle)
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Live CAT control on the Home screen, shown when a radio is configured.
struct HomeRigControlCard: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    let satellite: SatelliteRecord
    /// The transponder currently selected on the Home transponder card — CAT
    /// always tracks the same one, so there is no separate picker here.
    let selectedTransponderID: String?
    /// The passband offset from the Home Doppler card. A two-way binding so a dial
    /// move followed by the One True Rule (which updates the offset in the rig)
    /// also moves the Home slider and the live Doppler readouts.
    @Binding var passbandOffsetHz: Double

    var body: some View {
        if rig.config.isConfigured {
            SectionCard("Rig control (CAT)") {
                ControlStatusHeader(title: statusTitle, subtitle: statusSubtitle, dot: dotColor,
                                    connected: rig.connected, connecting: rig.connecting,
                                    onToggle: { rig.connected ? rig.disconnect() : rig.connect() })
                // Per-radio rows only for a two-radio station, where each link's
                // state is distinct. A single radio is fully described by the header.
                if rig.config.twoRadios {
                    ForEach(rig.statuses) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(s.connected ? ODTheme.good : (s.error != nil ? ODTheme.warning : ODTheme.muted))
                                .frame(width: 10, height: 10).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.caption.weight(.semibold))
                                Text(s.stateText).font(.caption2)
                                    .foregroundStyle(s.error != nil ? ODTheme.warning : ODTheme.muted)
                            }
                            Spacer()
                            if s.connecting { ProgressView().controlSize(.small) }
                        }
                    }
                }
                if !rig.connected, !rig.errorText.isEmpty {
                    Text(rig.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                if rig.connected {
                    Divider().opacity(0.4)
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
            // Home slider → rig (operator scrubs the passband).
            .onChange(of: passbandOffsetHz) { _, v in
                if abs(rig.config.tuning.passbandOffsetHz - v) > 0.5 { rig.config.tuning.passbandOffsetHz = v }
            }
            // rig → Home slider + Doppler card (One True Rule moved the offset).
            .onChange(of: rig.config.tuning.passbandOffsetHz) { _, v in
                if abs(passbandOffsetHz - v) > 0.5 { passbandOffsetHz = v }
            }
        }
    }

    private var statusTitle: String {
        rig.connecting ? "Connecting…" : (rig.connected ? "Connected" : "Not connected")
    }

    /// One-line description of the configured link(s), shown under the status.
    private var statusSubtitle: String? {
        if rig.config.twoRadios { return "Two radios" }
        guard let slot = rig.config.slots.first, let spec = slot.spec else { return nil }
        return "\(spec.name) · \(slot.transport.label)"
    }

    private var dotColor: Color {
        if rig.connected { return ODTheme.good }
        if rig.connecting { return ODTheme.accent }
        return rig.errorText.isEmpty ? ODTheme.muted : ODTheme.warning
    }
}
