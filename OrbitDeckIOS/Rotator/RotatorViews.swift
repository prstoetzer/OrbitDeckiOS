import SwiftUI

// ===========================================================================
//  RotatorViews.swift — rotator configuration screen + Home control card
// ===========================================================================

/// Full rotator setup screen (presented as a sheet from Settings).
struct RotatorSettingsView: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rot: RotatorController
    @State private var showBLEPicker = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable rotator control", isOn: b(\.enabled))
                Text("Point your az/el rotator at the selected satellite over a BLE serial adapter (GS-232, Easycomm, SPID) or a network connection (rotctld, PstRotator). Bluetooth Classic (SPP) adapters are not supported on iOS.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            if rot.config.enabled {
                Section("Rotator") {
                    Picker("Protocol", selection: b(\.proto)) {
                        ForEach(RotatorProtocolKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: rot.config.proto) { _, p in
                        // Sensible default port when switching to a network protocol.
                        if p.isNetwork { rot.config.port = p.defaultPort }
                    }

                    if rot.config.proto.isSerial {
                        Button {
                            showBLEPicker = true
                        } label: {
                            HStack {
                                Text("BLE adapter")
                                Spacer()
                                Text(rot.config.bleName.isEmpty ? "Choose…" : rot.config.bleName)
                                    .foregroundStyle(ODTheme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Picker("Serial rate", selection: b(\.baud)) {
                            ForEach([1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200], id: \.self) {
                                Text(verbatim: "\($0)").tag($0)
                            }
                        }
                        Text("Wire a BLE UART adapter to the rotator controller's serial port; set this to match the controller's baud.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    } else {
                        TextField("Host / IP", text: b(\.host))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.odField)
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("Port", value: b(\.port), format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                .textFieldStyle(.odField)
                        }
                        Text(rot.config.proto == .rotctld
                             ? "Hamlib rotctld TCP server (default port 4533)."
                             : "PstRotator UDP (default port 12000).")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }

                Section("Pointing") {
                    Picker("Azimuth range", selection: b(\.azRange)) {
                        ForEach(RotAzRange.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Flip mode (overhead passes)", isOn: b(\.flip))
                    if rot.config.azRange == .az450 {
                        Stepper(value: b(\.azLookSec), in: 0...30) {
                            Text(verbatim: "Az lookahead: \(rot.config.azLookSec) s")
                        }
                    }
                    Toggle("Send magnetic bearings", isOn: b(\.magCorrect))
                    Stepper(value: b(\.deadbandDeg), in: 0...30) {
                        Text(verbatim: "Deadband: \(rot.config.deadbandDeg)°")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Track above elevation")
                            Spacer()
                            Text(verbatim: "\(Int(rot.config.minElevationDeg))°").font(.body.monospacedDigit())
                        }
                        Slider(value: b(\.minElevationDeg), in: 0...45, step: 1)
                    }
                    Stepper(value: b(\.leadSec), in: 0...600, step: 15) {
                        Text(verbatim: rot.config.leadSec == 0 ? "Pre-position lead: off" : "Pre-position lead: \(rot.config.leadSec) s")
                    }
                    Stepper(value: b(\.updateMs), in: 200...5000, step: 100) {
                        Text(verbatim: "Update rate: \(rot.config.updateMs) ms")
                    }
                }

                Section("Alignment & park") {
                    Stepper(value: b(\.azOffsetDeg), in: -180...180) {
                        Text(verbatim: "Azimuth offset: \(rot.config.azOffsetDeg)°")
                    }
                    Stepper(value: b(\.elOffsetDeg), in: -90...90) {
                        Text(verbatim: "Elevation offset: \(rot.config.elOffsetDeg)°")
                    }
                    Stepper(value: b(\.parkAz), in: 0...450) {
                        Text(verbatim: "Park azimuth: \(rot.config.parkAz)°")
                    }
                    Stepper(value: b(\.parkEl), in: 0...180) {
                        Text(verbatim: "Park elevation: \(rot.config.parkEl)°")
                    }
                    Text("Offsets are added to the commanded bearing for alignment. On LOS or disconnect the rotator parks here.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
        }
        .navigationTitle("Rotator Control")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { rot.persist() }
        .sheet(isPresented: $showBLEPicker) {
            NavigationStack {
                BLEPickerView(selectedID: rot.config.bleIdentifier) { dev in
                    rot.config.bleIdentifier = dev.id.uuidString
                    rot.config.bleName = dev.name
                }
            }
        }
    }

    private func b<T>(_ key: WritableKeyPath<RotatorConfig, T>) -> Binding<T> {
        Binding(get: { rot.config[keyPath: key] }, set: { rot.config[keyPath: key] = $0 })
    }
}

// MARK: - Home control card

/// Live rotator control on the Home screen, shown when a rotator is configured.
struct HomeRotatorCard: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rot: RotatorController
    let satellite: SatelliteRecord

    var body: some View {
        if rot.config.isConfigured {
            SectionCard("Rotator") {
                ControlStatusHeader(title: statusTitle, subtitle: statusSubtitle, dot: dotColor,
                                    connected: rot.connected, connecting: rot.connecting,
                                    onToggle: { rot.connected ? rot.disconnect() : rot.connect() })
                if !rot.connected, !rot.errorText.isEmpty {
                    Text(rot.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                if rot.connected {
                    Divider().opacity(0.4)
                    MetricRow("Azimuth", String(format: "%.0f° %@", rot.commandedAz, ODFormat.compass(rot.commandedAz)), valueColor: ODTheme.good)
                    MetricRow("Elevation", String(format: "%.0f°", rot.commandedEl), valueColor: ODTheme.warning)
                    if !rot.lastTx.isEmpty {
                        Text(rot.lastTx).font(.caption2.monospaced())
                            .foregroundStyle(rot.lastTx.contains("ok") ? ODTheme.good : ODTheme.warning)
                    }
                }
                Text("Rotator control works only while OrbitDeck is in the foreground. Keep the Home screen awake during a pass (Settings ▸ Display).")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// When connected, the operational mode (Tracking / Pre-positioning / Parked)
    /// carried in `statusText`; otherwise the connection state.
    private var statusTitle: String {
        if rot.connected { return rot.statusText }
        return rot.connecting ? "Connecting…" : "Not connected"
    }

    /// One-line description of the configured link, shown under the status.
    private var statusSubtitle: String? {
        let proto = rot.config.proto.label
        if rot.config.proto.isNetwork {
            return "\(proto) · \(rot.config.host):\(rot.config.port)"
        }
        return rot.config.bleName.isEmpty ? proto : "\(proto) · \(rot.config.bleName)"
    }

    private var dotColor: Color {
        if rot.connected { return ODTheme.good }
        if rot.connecting { return ODTheme.accent }
        return rot.errorText.isEmpty ? ODTheme.muted : ODTheme.warning
    }
}
