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
                         : "One radio. A full-duplex satellite rig can drive both the uplink and downlink on MAIN/SUB. Most transceivers can also drive both in split-VFO mode (half duplex, for packet and same-band satellites), or control just one leg.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }

                slotSection(index: 0, title: rig.config.twoRadios ? "Radio 1 — downlink" : "Radio")
                if rig.config.twoRadios { slotSection(index: 1, title: "Radio 2 — uplink") }

                tuningSection
                diagnosticsSection

                RigctldServerSection()
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

                // Connection type. Icom network only appears for LAN-capable radios. Icom BLE only appears for bluetooth-capable radios.
                Picker("Connection", selection: transportBinding(index)) {
                    Text(CATTransportKind.ble.label).tag(CATTransportKind.ble)
                    if catalogSpec?.hasBluetooth == true { Text(CATTransportKind.bleicom.label).tag(CATTransportKind.bleicom)
                    }
                    if catalogSpec?.hasLan == true { Text(CATTransportKind.network.label).tag(CATTransportKind.network)
                    }
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
            Picker("Full duplex", selection: bindTuning(\.rigctldVFOMode)) {
                Text("VFO mode (VFOA/VFOB)").tag(true)
                Text("Split (TX VFO)").tag(false)
            }
            if !rig.config.tuning.rigctldVFOMode {
                Toggle("Use split VFO for full duplex", isOn: bindTuning(\.rigctldUseSplit))
            }
            Text(rig.config.tuning.rigctldVFOMode
                 ? "VFO mode selects VFOA for the downlink and VFOB for the uplink and tunes each with plain frequency/mode commands — what gpredict and CardSat use, and the most portable with Icom satellite rigs. A rigctld started with --vfo is detected at connect. If the active VFO flickers on an Icom in satellite mode, start rigctld with -x 1."
                 : "The split method tunes the uplink with set_split_freq (S 1 VFOB, I/X). Use it if your Hamlib backend doesn't handle VFOA/VFOB.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
        Text("Drives any radio through a Hamlib rigctld server on your network (default port 4532). Run rigctld on a computer connected to the radio.")
            .font(.caption).foregroundStyle(ODTheme.muted)
    }

    /// Fields for a catalog radio over BLE or Icom network (the original flow).
    @ViewBuilder private func radioSlotFields(index: Int, spec: RadioSpec?) -> some View {
        let slotBind = bindSlot(index)
        if !rig.config.twoRadios, let spec {
            Picker("Controls", selection: controlChoice(index)) {
                if spec.fullDuplex { Text("Uplink + downlink (MAIN/SUB)").tag("both") }
                if spec.supportsSplit { Text("Uplink + downlink (split VFO)").tag("split") }
                Text(RigRole.downlink.label).tag("downlink")
                if !spec.rxOnly { Text(RigRole.uplink.label).tag("uplink") }
            }
            if rig.config.slots[index].splitVFO, spec.supportsSplit {
                Text(splitHelp(spec))
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
        }
        if rig.config.twoRadios, let spec, spec.fullDuplex {
            Text("As one leg of a two-radio station the \(spec.name) is driven as a single-VFO radio on whatever band is selected on its front panel: OrbitDeck sends no MAIN/SUB selection, satellite mode or band exchange. Put the \(index == 0 ? "downlink" : "uplink") band on the active VFO before you connect.")
                .font(.caption).foregroundStyle(ODTheme.muted)
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
                    } else if rig.config.slots[index].transport == .bleicom {
                        Button {
                            blePickerSlot = SlotRef(id: index)
                        } label: {
                            HStack {
                                Text("Radio BLE device")
                                Spacer()
                                Text(rig.config.slots[index].bleName.isEmpty ? "Choose…" : rig.config.slots[index].bleName)
                                    .foregroundStyle(ODTheme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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

    /// The single-radio "Controls" choice, folding the leg role and split-VFO flag
    /// into one picker: MAIN/SUB full duplex, split VFO, or one leg.
    private func controlChoice(_ i: Int) -> Binding<String> {
        Binding(get: {
            let slot = rig.config.slots[i]
            if slot.splitVFO, slot.spec?.supportsSplit == true { return "split" }
            switch slot.role {
            case .both:
                // A mono radio can't do MAIN/SUB; show its effective single leg.
                return slot.spec?.fullDuplex == true ? "both" : "downlink"
            case .downlink: return "downlink"
            case .uplink: return "uplink"
            }
        }, set: { choice in
            rig.config.slots[i].splitVFO = (choice == "split")
            switch choice {
            case "both", "split": rig.config.slots[i].role = .both
            case "uplink": rig.config.slots[i].role = .uplink
            default: rig.config.slots[i].role = .downlink
            }
        })
    }

    private func splitHelp(_ spec: RadioSpec) -> String {
        var text = "VFO A receives the downlink and VFO B transmits the uplink with SPLIT on, both Doppler-corrected — for same-band or same-frequency satellites (packet digipeaters, ISS APRS) on any transceiver. Half duplex: you can't hear the satellite while transmitting."
        switch spec.family {
        case .civ:
            if spec.fullDuplex {
                text += " Split runs on the MAIN band with satellite mode off" + (spec.hasSatMode ? " (OrbitDeck turns it off)." : " — turn SATL off on the radio first.")
            }
            if spec.civUnselectedVFO {
                text += " VFO B is tuned directly, so the receiver never moves."
            } else {
                if spec.civUnselectedVFOMaybe {
                    text += " With firmware E4 or later VFO B is tuned directly; older firmware swaps VFOs (detected at connect)."
                } else {
                    text += " This radio reaches VFO B by swapping VFOs, which briefly moves the receiver, so the uplink retunes less often (split uplink deadband below)."
                }
                text += spec.civHasPTT
                    ? " Uplink updates wait while the radio reports it's transmitting."
                    : " This radio can't report transmit over CI-V, so an update could land mid-transmission when keyed by hand or a TNC — keep the split uplink deadband wide."
            }
        case .yaesuBinary:
            text += " These Yaesus can only toggle VFOs: OrbitDeck reads which VFO is active and starts on A (if the radio doesn't answer, leave it on VFO A). The uplink retunes less often to keep the receiver steady."
        case .yaesuFT100:
            text += " VFO B is selected directly for each uplink update."
        case .kenwoodBase:
            text += spec.kenwoodSplitFRFT
                ? " Uses FR0/FT1; satellite (SATL) mode is turned off for split."
                : " Uses FN/SP split on this radio (untested — please report results)."
        default:
            break
        }
        return text
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
            case .ble, .bleicom: break
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

    /// Radios offered for a slot. Two-radio uplink (slot 1) excludes RX-only sets. A
    /// full-duplex sat rig can be either leg of a two-radio station too — it's then driven
    /// as a single-VFO radio on the band its front panel has selected.
    private func radioChoices(_ index: Int) -> [RadioSpec] {
        if rig.config.twoRadios {
            return index == 1 ? RadioCatalog.all.filter { !$0.rxOnly } : RadioCatalog.all
        }
        return RadioCatalog.all
    }

    // MARK: Tuning

    private var tuningSection: some View {
        Section("Tuning") {
            Toggle("Track Doppler", isOn: bindTuning(\.trackDoppler))
            Toggle("Follow radio tuning (One True Rule)", isOn: Binding(
                get: { rig.config.tuning.followRadio },
                set: { on in
                    rig.config.tuning.followRadio = on
                    // Follow-uplink is a tune mode that implies following; turning follow off leaves it.
                    if !on, rig.config.tuning.tuneMode == .fullUplink { rig.config.tuning.tuneMode = .full }
                }))
            if rig.config.tuning.followRadio {
                // The followed leg is the live tune mode (also on the Home rig card).
                Picker("Follow", selection: Binding(
                    get: { rig.config.tuning.effectiveFollowLeg },
                    set: { leg in
                        rig.config.tuning.followLeg = leg
                        rig.config.tuning.tuneMode = leg == .uplink ? .fullUplink : .full
                    })) {
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
            if rig.config.effectiveUpdateMs > rig.config.tuning.updateMs, let baud = rig.config.slowestSerialBaud {
                Text("Effective rate: \(rig.config.effectiveUpdateMs) ms — slowed for the \(baud)-baud serial link so each update's commands fit on the wire. Takes effect at the next connect.")
                    .font(.caption).foregroundStyle(ODTheme.warning)
            }
            Toggle("Follow selection while connected", isOn: bindTuning(\.followSelection))
            Text(rig.config.tuning.followSelection
                 ? "Selecting another satellite retunes the radio and re-points the rotator right away, even mid-pass."
                 : "From shortly before AOS (the rotator's pre-position lead) until LOS, the radio and rotator stay on the satellite they're tracking when you select another one; the Home cards ask before switching. Automatic switching always moves both.")
                .font(.caption).foregroundStyle(ODTheme.muted)
            Stepper("Command delay: \(rig.config.tuning.commandDelayMs) ms", value: bindTuning(\.commandDelayMs), in: 0...500, step: 10)
            Toggle("MAIN = uplink, SUB = downlink", isOn: bindTuning(\.mainIsUplink))
            Toggle("Command radio satellite mode", isOn: bindTuning(\.satMode))
            Toggle("Assign MAIN/SUB bands (IC-9100/9700)", isOn: bindTuning(\.assignBands))
            Stepper("FM deadband: \(rig.config.tuning.fmDeadbandHz) Hz", value: bindTuning(\.fmDeadbandHz), in: 0...2000, step: 50)
            Stepper("Linear deadband: \(rig.config.tuning.linearDeadbandHz) Hz", value: bindTuning(\.linearDeadbandHz), in: 0...500, step: 10)
            if !rig.config.twoRadios, rig.config.slots[0].splitVFO {
                Stepper("Split uplink deadband: \(rig.config.tuning.splitUplinkDeadbandHz) Hz",
                        value: bindTuning(\.splitUplinkDeadbandHz), in: 0...3000, step: 100)
                Text("On split radios that swap VFOs to reach VFO B, the uplink retunes only after drifting this far, so the receiver moves less often. 1200-baud packet and FM voice tolerate 500–1000 Hz.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            Toggle("Narrow FM on FM satellites", isOn: bindTuning(\.narrowFM))
            Toggle("CW on linear transponders", isOn: bindTuning(\.linearCW))
            Text("Puts both legs in CW instead of USB/LSB on linear transponders (the dial shows the carrier, so your own signal returns at your CW pitch). FT4 keeps SSB while it runs.")
                .font(.caption).foregroundStyle(ODTheme.muted)
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
            Picker("Uplink CTCSS (other satellites)", selection: bindTuning(\.uplinkToneHz)) {
                Text("Off").tag(0.0)
                ForEach(CTCSS.availableHz, id: \.self) { Text(String(format: "%.1f Hz", $0)).tag($0) }
            }
            if let sat = store.selectedSatellite {
                satelliteToneRows(sat)
            }
            Text("Transverter LO offsets, deadbands and lead mirror CardSat. Per-satellite oscillator calibration comes from the Calibrations screen.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            // Its own view, so live monitor traffic doesn't re-render this whole form.
            CATMonitorControls()
            Text("Records every frame sent to and received from each radio (hex plus a short decode, last \(CATMonitor.capacity) lines) while on. Off costs nothing; it's never saved.")
                .font(.caption).foregroundStyle(ODTheme.muted)
            ForEach(selfTestSlots, id: \.self) { i in
                NavigationLink {
                    CATSelfTestView(slotIndex: i)
                } label: {
                    Text(rig.config.twoRadios ? "Self-test Radio \(i + 1)" : "Self-test radio")
                }
                .disabled(rig.connected || rig.connecting)
            }
            Text(rig.connected || rig.connecting
                 ? "Disconnect CAT to run a self-test."
                 : "Connects to the radio on its own, reads the frequency and mode, sets the same mode back and checks the radio's acknowledgment, with hints for anything that fails.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    private var selfTestSlots: [Int] {
        var out: [Int] = []
        if rig.config.slots[0].enabled, rig.config.slots[0].spec != nil { out.append(0) }
        if rig.config.twoRadios, rig.config.slots.count > 1, rig.config.slots[1].enabled, rig.config.slots[1].spec != nil { out.append(1) }
        return out
    }

    /// Per-satellite uplink tone for the selected satellite: Default (built-in table, else
    /// the global tone), Off, or a specific tone — plus which tone is in effect and why.
    @ViewBuilder private func satelliteToneRows(_ sat: SatelliteRecord) -> some View {
        let uplinkHz = rig.transponder(for: sat)?.uplinkCenter ?? 0
        let builtIn = SatelliteTones.builtInTone(norad: sat.id, uplinkHz: uplinkHz)
        let fallback = builtIn ?? rig.config.tuning.uplinkToneHz
        let fallbackText = fallback > 0 ? String(format: "%.1f Hz", fallback) : "off"
        Picker("CTCSS for \(sat.name)", selection: satToneBinding(sat.id)) {
            // Short, so the menu value doesn't crowd the label; the source is in the note below.
            Text("Default (\(fallbackText))").tag(-1.0)
            Text("Off").tag(0.0)
            ForEach(CTCSS.availableHz, id: \.self) { Text(String(format: "%.1f Hz", $0)).tag($0) }
        }
        let r = SatelliteTones.resolve(norad: sat.id, uplinkHz: uplinkHz, tuning: rig.config.tuning)
        Text("In effect for \(sat.name): \(r.hz > 0 ? String(format: "%.1f Hz", r.hz) : "no tone") (\(r.source.rawValue)). Sent only on FM uplinks; turned off again on a transponder without one and when you disconnect.")
            .font(.caption).foregroundStyle(ODTheme.muted)
    }

    /// The selected satellite's override; -1 = none (use the default).
    private func satToneBinding(_ norad: UInt) -> Binding<Double> {
        let key = String(norad)
        return Binding(get: { rig.config.tuning.satelliteToneHz[key] ?? -1 },
                       set: { v in
                           if v < 0 { rig.config.tuning.satelliteToneHz.removeValue(forKey: key) }
                           else { rig.config.tuning.satelliteToneHz[key] = v }
                       })
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

// MARK: - CAT monitor + self-test

/// Monitor toggle + link for the CAT settings screen.
private struct CATMonitorControls: View {
    @ObservedObject private var monitor = CATMonitor.shared

    var body: some View {
        Toggle("CAT monitor", isOn: $monitor.enabled)
        NavigationLink {
            CATMonitorView()
        } label: {
            HStack {
                Text("View CAT monitor")
                Spacer()
                Text(verbatim: "\(monitor.lines.count)").foregroundStyle(ODTheme.muted).monospacedDigit()
            }
        }
    }
}

/// Live view of the CAT monitor ring buffer, newest at the bottom, with copy/share.
struct CATMonitorView: View {
    @ObservedObject private var monitor = CATMonitor.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if monitor.lines.isEmpty {
                        Text(monitor.enabled ? "Waiting for CAT traffic…" : "Turn on the CAT monitor, then connect or run a self-test.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    ForEach(Array(monitor.lines.enumerated()), id: \.offset) { i, line in
                        Text(verbatim: line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(line.contains(" TX ") ? ODTheme.warning : ODTheme.good)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding()
            }
            .onChange(of: monitor.lines.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .navigationTitle("CAT monitor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle(isOn: $monitor.enabled) { Image(systemName: monitor.enabled ? "record.circle.fill" : "record.circle") }
                    .toggleStyle(.button)
                    .accessibilityLabel(monitor.enabled ? "Stop recording" : "Record")
                Menu {
                    Button { UIPasteboard.general.string = monitor.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: monitor.text) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { monitor.clear() } label: { Label("Clear", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }
}

/// Guided self-test of one configured radio (see `RigController.runSelfTest`).
struct CATSelfTestView: View {
    @EnvironmentObject private var rig: RigController
    let slotIndex: Int

    var body: some View {
        List {
            Section {
                Button {
                    Task { await rig.runSelfTest(slot: slotIndex) }
                } label: {
                    HStack {
                        Label(rig.selfTestRunning ? "Testing…" : "Run self-test", systemImage: "stethoscope")
                        if rig.selfTestRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(rig.selfTestRunning || rig.connected || rig.connecting)
                Text("Uses the radio settings above. It reads the frequency and mode and sets the same mode back, so the radio is left as it was. Turn on the CAT monitor to see every frame.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } header: {
                Text(rig.config.slots[slotIndex].spec?.name ?? "Radio")
            }
            if rig.selfTestSlot == slotIndex, !rig.selfTestSteps.isEmpty {
                Section("Results") {
                    ForEach(rig.selfTestSteps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.passed == true ? "checkmark.circle.fill"
                                  : (step.passed == false ? "xmark.octagon.fill" : "info.circle"))
                                .foregroundStyle(step.passed == true ? ODTheme.good : (step.passed == false ? ODTheme.warning : ODTheme.muted))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.name).font(.subheadline.weight(.semibold))
                                Text(step.detail).font(.caption).foregroundStyle(ODTheme.muted)
                                if let hint = step.hint {
                                    Text(hint).font(.caption).foregroundStyle(ODTheme.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("CAT self-test")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - No-CAT manual calculator

/// HOLD/TUNE calculator for the Home Doppler card when no CAT radio is connected: hold
/// one leg at a fixed dial (an HT or an FT-817 left on one uplink frequency) and read the
/// other leg's dial live, corrected through the transponder (on a linear bird the held
/// leg's Doppler error moves where you land in the passband, so the other leg follows it).
struct ManualDopplerCalculator: View {
    @EnvironmentObject private var rig: RigController
    let transponder: TransponderRecord
    let rangeRateKmS: Double
    /// Downlink calibration folded into the receive dial (as on the Doppler card).
    let downlinkCalibrationHz: Double
    /// The current corrected dials, captured when HOLD is engaged.
    let currentRx: Int64
    let currentTx: Int64

    @State private var holdLeg: RigRole?
    @State private var heldDialHz: Int64 = 0
    @State private var entry = ""
    @FocusState private var entryFocused: Bool

    var body: some View {
        content.onChange(of: transponder.id) { _, _ in holdLeg = nil }
    }

    @ViewBuilder private var content: some View {
        if !rig.connected, transponder.uplinkCenter > 0 {
            Divider().padding(.vertical, 2)
            // Title above the picker: side by side they overflow a narrow phone.
            VStack(alignment: .leading, spacing: 4) {
                Text("Manual HOLD/TUNE").font(.caption.weight(.semibold)).foregroundStyle(ODTheme.accent)
                Picker("Hold", selection: Binding(get: { holdLeg }, set: { leg in
                    holdLeg = leg
                    if let leg { heldDialHz = leg == .uplink ? currentTx : currentRx; entry = mhz(heldDialHz) }
                })) {
                    Text("Off").tag(RigRole?.none)
                    Text("Hold TX").tag(RigRole?.some(.uplink))
                    Text("Hold RX").tag(RigRole?.some(.downlink))
                }
                .pickerStyle(.segmented)
            }
            if let leg = holdLeg {
                VStack(alignment: .leading, spacing: 4) {
                    Text(leg == .uplink ? "TX dial to hold (MHz)" : "RX dial to hold (MHz)")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                    HStack(spacing: 6) {
                        // The result follows the typed value live: the decimal pad has no
                        // Return key, so waiting for a commit meant nothing ever updated.
                        TextField("e.g. 145.96000", text: $entry)
                            .keyboardType(.decimalPad)
                            .font(.body.monospacedDigit())
                            .textFieldStyle(.odField)
                            .focused($entryFocused)
                            .onSubmit(commitEntry)
                            .onChange(of: entryFocused) { _, focused in if !focused { commitEntry() } }
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { entryFocused = false }
                                }
                            }
                        Button("Now") { heldDialHz = leg == .uplink ? currentTx : currentRx; entry = mhz(heldDialHz) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityHint("Fills in the current corrected dial")
                    }
                    if !entry.isEmpty, parsedEntry == nil {
                        Text("Enter the frequency in MHz (145.96), kHz (145960) or Hz.")
                            .font(.caption2).foregroundStyle(ODTheme.warning)
                    }
                }
                let result = solve(leg: leg)
                MetricRow(leg == .uplink ? "RX (tune)" : "TX (tune)", ODFormat.frequency(result.other),
                          valueColor: leg == .uplink ? ODTheme.good : ODTheme.warning)
                if transponder.isLinear {
                    MetricRow("Lands in passband", String(format: "%+.2f kHz", Double(result.offset) / 1000))
                } else {
                    MetricRow("Held-leg Doppler error", String(format: "%+lld Hz", result.offset))
                }
                Text(leg == .uplink
                     ? "Leave the transmitter on the held dial and tune the receiver to the RX value as the pass goes on."
                     : "Leave the receiver on the held dial and tune the transmitter to the TX value as the pass goes on.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// 10 Hz resolution — fine enough for SSB/CW hand tuning.
    private func mhz(_ hz: Int64) -> String { String(format: "%.5f", Double(hz) / 1_000_000) }

    /// The typed held dial in Hz. Accepts MHz ("145.96"), kHz ("145960") or Hz
    /// ("145960000"); nil while the text isn't a usable frequency.
    private var parsedEntry: Int64? {
        let text = entry.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(text), v > 0 else { return nil }
        // With a decimal point it's MHz (145.96, 10368.1). A whole number is judged by
        // size: under 100,000 → MHz, under 100,000,000 → kHz (145960), else Hz.
        let hz: Double = text.contains(".") || v < 100_000 ? v * 1_000_000
            : (v < 100_000_000 ? v * 1_000 : v)
        return hz >= 1_000_000 ? Int64(hz.rounded()) : nil
    }

    /// The dial the calculation uses: what's being typed, else the last good value.
    private var liveHeldHz: Int64 { parsedEntry ?? heldDialHz }

    private func commitEntry() {
        if let hz = parsedEntry { heldDialHz = hz }
        entry = mhz(heldDialHz)
    }

    /// The other leg's dial for a held leg, and where the held leg lands relative to the
    /// transponder (linear: passband offset; FM: the held leg's Doppler error at the satellite).
    private func solve(leg: RigRole) -> (other: Int64, offset: Int64) {
        let beta = (rangeRateKmS * 1000.0) / 299_792_458.0
        if leg == .uplink {
            // What the satellite hears from the fixed transmitter.
            let atSat = Double(liveHeldHz) * (1.0 - beta)
            let offset = atSat - Double(transponder.uplinkCenter)
            let dlAtSat = transponder.isLinear
                ? Double(transponder.downlinkCenter) + (transponder.invert ? -offset : offset)
                : Double(transponder.downlinkCenter)
            let rx = dlAtSat * (1.0 - beta) + downlinkCalibrationHz
            return (Int64(rx.rounded()), Int64(offset.rounded()))
        } else {
            // What the satellite sent to arrive on the fixed receiver dial.
            let atSat = (Double(liveHeldHz) - downlinkCalibrationHz) / (1.0 - beta)
            let offset = atSat - Double(transponder.downlinkCenter)
            let ulAtSat = transponder.isLinear
                ? Double(transponder.uplinkCenter) + (transponder.invert ? -offset : offset)
                : Double(transponder.uplinkCenter)
            let tx = ulAtSat / (1.0 - beta)
            return (Int64(tx.rounded()), Int64(offset.rounded()))
        }
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
    /// Selects a transponder on the Home card (CAT follows it) — used by "Beacon".
    var selectTransponder: ((String) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase

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
                                if let hintText = s.hint {
                                    // show the hint only if we have some
                                    Text(hintText)
                                        .font(.caption2)
                                        .foregroundStyle(ODTheme.good)
                                        .padding(.top, 8)
                                }
                            }
                            Spacer()
                            if s.connecting { ProgressView().controlSize(.small) }
                        }
                    }
                    // With no per-radio rows (a setup problem caught before connecting,
                    // or reconnects given up), the station-level error is the only message.
                    if rig.statuses.isEmpty, !rig.connected, !rig.errorText.isEmpty {
                        Text(rig.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                    }
                } else {
                    if !rig.connected, !rig.errorText.isEmpty {
                        Text(rig.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                        if let hintText = rig.statuses.first?.hint {
                            Text(hintText).font(.caption2).foregroundStyle(ODTheme.good)
                        }
                    }
                }
                if rig.connected {
                    Divider().opacity(0.4)
                    switchBanner
                    if rig.tuningOtherSatellite, let sat = rig.trackedSatellite {
                        Label("Radio tuned to \(sat.name)", systemImage: "lock.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.accent)
                    }
                    if rig.atPassbandEdge {
                        Label("At passband edge", systemImage: "arrow.left.and.right.square")
                            .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.warning)
                    }
                    if rig.pttCapable, let why = rig.pttBlockedReason {
                        Label(why, systemImage: "mic.slash.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.warning)
                    }
                    MetricRow("Downlink", ODFormat.frequency(rig.downlinkDialHz), valueColor: ODTheme.good)
                    if rig.uplinkDialHz > 0 {
                        MetricRow("Uplink", ODFormat.frequency(rig.uplinkDialHz), valueColor: ODTheme.warning)
                    }
                    HStack(spacing: 8) {
                        tuneModeMenu
                        Spacer()
                        if let beacon = rig.beaconTransponder(for: satellite), selectTransponder != nil, !rig.tuningOtherSatellite {
                            Button {
                                selectTransponder?(beacon.id)
                            } label: {
                                Label("Beacon", systemImage: "dot.radiowaves.right")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(selectedTransponderID == beacon.id)
                            .accessibilityHint("Tunes the satellite's beacon or telemetry downlink")
                        }
                    }
                    if rig.tiltTuning || rig.trackedSatellite.flatMap({ rig.transponder(for: $0) })?.isLinear == true {
                        Toggle("Tilt to tune passband", isOn: $rig.tiltTuning)
                    }
                    if rig.tiltTuning {
                        Text("Roll the phone left or right to move through the passband — the further you tilt, the faster it moves. Hold it level to stop.")
                            .font(.caption2).foregroundStyle(ODTheme.muted)
                    }
                    Toggle("Track Doppler", isOn: Binding(
                        get: { rig.config.tuning.trackDoppler },
                        set: { rig.config.tuning.trackDoppler = $0; rig.persist() }
                    ))
                }
                StopAllButton()
                Text("CAT works only while OrbitDeck is in the foreground. Keep the Home screen awake during a pass (Settings ▸ Display).")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
            .onAppear {
                rig.transponderID = selectedTransponderID
                if !rig.tuningOtherSatellite { rig.config.tuning.passbandOffsetHz = passbandOffsetHz }
            }
            .onChange(of: selectedTransponderID) { _, v in rig.transponderID = v }
            // Tilt tuning reads the motion sensor: only while this card is on screen and
            // the app is active, never in a pocket or the background.
            .onDisappear { rig.tiltTuning = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { rig.tiltTuning = false } }
            // CAT switched satellites (Switch, automatic switching, follow, pass end): the
            // rig reset the passband trim, so put the Home slider back in step with it.
            .onChange(of: rig.engagedNorad) { old, new in
                guard old != nil, new != nil, !rig.tuningOtherSatellite else { return }
                if abs(passbandOffsetHz - rig.config.tuning.passbandOffsetHz) > 0.5 {
                    passbandOffsetHz = rig.config.tuning.passbandOffsetHz
                }
            }
            // Home slider → rig (operator scrubs the passband). Not while CAT is locked on
            // another satellite: Home's slider then belongs to the selection, not the radio.
            .onChange(of: passbandOffsetHz) { _, v in
                if !rig.tuningOtherSatellite, abs(rig.config.tuning.passbandOffsetHz - v) > 0.5 { rig.config.tuning.passbandOffsetHz = v }
            }
            // rig → Home slider + Doppler card (One True Rule / tilt moved the offset).
            .onChange(of: rig.config.tuning.passbandOffsetHz) { _, v in
                if !rig.tuningOtherSatellite, abs(passbandOffsetHz - v) > 0.5 { passbandOffsetHz = v }
            }
        }
    }

    /// "Switch radio to <new>?" while CAT stays on the engaged satellite.
    @ViewBuilder private var switchBanner: some View {
        if let n = rig.pendingSwitchNorad {
            let name = store.satellites.first { $0.id == n }?.name ?? "#\(n)"
            VStack(alignment: .leading, spacing: 6) {
                Text("Switch radio to \(name)?").font(.subheadline.weight(.semibold))
                Text("The radio is still tracking \(rig.trackedSatellite?.name ?? "the engaged satellite") during its pass.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
                HStack {
                    Button("Switch") { rig.acceptPendingSwitch() }.buttonStyle(.borderedProminent)
                    Button("Keep") { rig.keepEngagedSatellite() }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ODTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Live tune-mode selector, shown compactly as its current mode.
    private var tuneModeMenu: some View {
        Menu {
            Picker("Tune mode", selection: Binding(
                get: { rig.config.tuning.tuneMode },
                set: { rig.config.tuning.tuneMode = $0; rig.persist() }
            )) {
                ForEach(CATTuneMode.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Tune: \(rig.config.tuning.tuneMode.shortLabel)", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered).controlSize(.small)
        .tint(rig.config.tuning.tuneMode == .full ? ODTheme.accent : ODTheme.warning)
        .accessibilityLabel("Tune mode: \(rig.config.tuning.tuneMode.label)")
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

// MARK: - Stop all

/// "Stop all" with its confirmation, shared by the Home rig card and (for a station with
/// no CAT radio configured) the Home rotator card. Shown only while something is running.
struct StopAllButton: View {
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var rotator: RotatorController
    @EnvironmentObject private var ft4: FT4Engine
    @EnvironmentObject private var packet: PacketEngine
    @ObservedObject private var rigServer = RigctldServer.shared
    @ObservedObject private var rotServer = RotctldServer.shared
    @State private var confirm = false

    var body: some View {
        if available {
            Button(role: .destructive) {
                confirm = true
            } label: {
                Label("Stop all", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .confirmationDialog("Stop everything?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Stop all", role: .destructive) { stopAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Releases PTT, stops FT4 and packet, ends rigctld/rotctld client control, disconnects the radio, and parks and disconnects the rotator.")
            }
        }
    }

    private var available: Bool {
        rig.connected || rig.connecting || rotator.connected || ft4.isRunning || packet.isRunning
            || rigServer.externalControl || rigServer.clientKeyed || rotServer.externalControl
    }

    /// Release PTT and any network-client control, stop the digital engines, disconnect
    /// CAT, park + disconnect the rotator.
    private func stopAll() {
        ODLog.shared.log("Stop all", category: "cat")
        // The engines unkey on stop; release PTT explicitly too, before CAT goes away.
        let wasConnected = rig.connected
        ft4.stop()
        packet.stop()
        // A network client's key and Doppler hold, and a rotctld client's pause.
        rigServer.releaseForStopAll()
        rotServer.resumeTracking()
        Task {
            if wasConnected { await rig.setPTT(false) }
            if rig.connected || rig.connecting { rig.disconnect() }
        }
        if rotator.connected { rotator.disconnect() }
    }
}

// MARK: - Hamlib server settings

/// Settings section for the built-in rigctld server (bottom of the CAT screen).
struct RigctldServerSection: View {
    @ObservedObject private var server = RigctldServer.shared

    var body: some View {
        Section("rigctld server") {
            Toggle("Run rigctld server", isOn: Binding(get: { server.enabled }, set: { server.setEnabled($0) }))
            HamlibPortField(port: server.port, placeholder: "\(RigctldServer.defaultPort)") { server.setPort($0) }
            Toggle("Allow PTT from network clients", isOn: Binding(get: { server.allowPTT }, set: { server.setAllowPTT($0) }))
            Text(server.allowPTT
                 ? "A client may key the radio (T 1). It's unkeyed when that client disconnects, the server stops, OrbitDeck goes to the background, or after \(Int(RigctldServer.pttLimitSec / 60)) minutes keyed."
                 : "Clients can't key the radio: PTT commands are refused (RPRT -11).")
                .font(.caption).foregroundStyle(ODTheme.muted)
            if server.enabled {
                HamlibServerStatusRows(port: server.port, listening: server.listening, errorText: server.errorText,
                                       clientCount: server.clientCount, lastCommand: server.lastCommand)
                if server.externalControl {
                    Text("A client is tuning the radio — OrbitDeck's Doppler tuning is paused until it disconnects.")
                        .font(.caption).foregroundStyle(ODTheme.warning)
                    Button("Resume OrbitDeck Doppler") { server.resumeDoppler() }
                }
                if server.clientKeyed {
                    Text("A network client has the radio keyed.")
                        .font(.caption.weight(.semibold)).foregroundStyle(ODTheme.warning)
                    Button("Unkey now", role: .destructive) { server.unkeyClient() }
                }
            }
            Text("Lets Gpredict, SatPC32, WSJT-X or a logger on your local network read or drive the radio through OrbitDeck's CAT link — in the client choose Hamlib NET rigctl (model 2) and enter an address below. VFOA is the downlink, VFOB the uplink; frequencies are the radio's dial. Reading never disturbs OrbitDeck. When a client sets a frequency, OrbitDeck pauses its own Doppler tuning for as long as that client stays connected, so let the client do Doppler (or only read).")
                .font(.caption).foregroundStyle(ODTheme.muted)
            HamlibServerLimitsNote()
        }
    }
}

/// Port entry for a Hamlib server; applies on Return or the Apply button.
struct HamlibPortField: View {
    let port: Int
    let placeholder: String
    let apply: (Int) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            Text("TCP port")
            Spacer()
            if let p = Int(text), p != port, (1024...65535).contains(p) {
                Button("Apply") { apply(p) }.buttonStyle(.borderless)
            }
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 90).textFieldStyle(.odField)
                .onSubmit { if let p = Int(text) { apply(p) }; text = String(port) }
        }
        .onAppear { text = String(port) }
        .onChange(of: port) { _, p in text = String(p) }
    }
}

/// Live status for a Hamlib server: listening state, the phone's LAN addresses to enter
/// in the client, connected clients and the most recent command.
struct HamlibServerStatusRows: View {
    let port: Int
    let listening: Bool
    let errorText: String?
    let clientCount: Int
    let lastCommand: String

    var body: some View {
        let addresses = HamlibProtocol.lanAddresses()
        LabeledContent("Status", value: listening ? "Listening" : (errorText ?? "Starting…"))
        if addresses.isEmpty {
            Text("No local network address — join a Wi-Fi network (or turn on Personal Hotspot).")
                .font(.caption).foregroundStyle(ODTheme.warning)
        } else {
            ForEach(addresses, id: \.address) { a in
                LabeledContent(a.interface) {
                    Text(verbatim: "\(a.address):\(port)").textSelection(.enabled).monospacedDigit()
                }
            }
        }
        LabeledContent("Connected clients", value: "\(clientCount)")
        if !lastCommand.isEmpty {
            LabeledContent("Last command") {
                Text(verbatim: lastCommand).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// The iOS/security caveats shared by both servers.
struct HamlibServerLimitsNote: View {
    var body: some View {
        Text("iOS keeps the server running only while OrbitDeck is in the foreground, or while a background audio session (pass recording, decoding, remote voice) is active. Local network only; there is no authentication, so use it on a network you trust.")
            .font(.caption).foregroundStyle(ODTheme.muted)
    }
}
