import SwiftUI

// ===========================================================================
//  RotatorViews.swift — rotator configuration screen + Home control card, plus the
//  manual control, self-test and monitor screens
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
                Text("Point your az/el rotator at the selected satellite over a BLE serial adapter (GS-232, Easycomm, SPID, SAEBRTrack) or a network connection (rotctld, PstRotator, OZ9AAR URC). Bluetooth Classic (SPP) adapters are not supported on iOS. Green Heron RT-21 Az/El needs two independent serial links (one per axis), which a single BLE adapter can't drive, so it isn't offered.")
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
                        if rot.config.proto == .gs232 {
                            Toggle("Azimuth-only controller", isOn: b(\.gs232AzOnly))
                            Text("For GS-232 controllers without an elevation axis: sends the azimuth-only M command instead of W. Flip mode is unavailable.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                        }
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
                        Text(networkHelp)
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                }

                Section("Control & diagnostics") {
                    NavigationLink("Manual control") { RotatorManualView() }
                    NavigationLink("Self-test") { RotatorSelfTestView() }
                    NavigationLink("Monitor") { RotatorMonitorView() }
                    if rot.config.proto.supportsReadBack {
                        Toggle("Read back position", isOn: b(\.readBack))
                    }
                    Picker("Sun/Moon below horizon", selection: b(\.belowHorizon)) {
                        ForEach(RotBelowHorizon.allCases) { Text($0.label).tag($0) }
                    }
                    Text(readBackHelp)
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }

                Section("Pointing") {
                    Picker("Azimuth range", selection: b(\.azRange)) {
                        ForEach(RotAzRange.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Flip mode (overhead passes)", isOn: b(\.flip))
                        .disabled(rot.config.azimuthOnly)
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
                    Stepper(value: b(\.trackLeadSec), in: 0...10) {
                        Text(verbatim: rot.config.trackLeadSec == 0 ? "Slew lead: off" : "Slew lead: \(rot.config.trackLeadSec) s")
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

    private var networkHelp: String {
        switch rot.config.proto {
        case .rotctld: "Hamlib rotctld TCP server (default port 4533)."
        case .urc: "OZ9AAR URC controller, TCP/JSON (default port 1111)."
        default: "PstRotator UDP (default port 12000)."
        }
    }

    private var readBackHelp: String {
        switch rot.config.proto {
        case .pstRotator: "PstRotator's UDP control is one-way, so the actual position isn't shown."
        case .saebrtrack: "SAEBRTrack has no safe position query, so the actual position isn't shown."
        default: "Read-back polls the controller about once a second and flags a stall when the antenna doesn't follow."
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
    @State private var showManual = false

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
                    RotatorTargetPicker()
                    if let pending = rot.pendingSwitch {
                        RotatorSwitchPrompt(pending: pending)
                    } else if rot.target == .satellite, let id = rot.engagedSatelliteID, id != satellite.id {
                        Text("Finishing the \(rot.engagedSatelliteName) pass").font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    RotatorPositionRows()
                    if !rot.lastTx.isEmpty {
                        Text(rot.lastTx).font(.caption2.monospaced())
                            .foregroundStyle(rot.lastTx.contains("ok") ? ODTheme.good : ODTheme.warning)
                    }
                    Button { showManual = true } label: {
                        Label("Manual control", systemImage: "dpad")
                    }
                    .buttonStyle(.bordered)
                }
                Text("Rotator control works only while OrbitDeck is in the foreground. Keep the Home screen awake during a pass (Settings ▸ Display).")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
            .sheet(isPresented: $showManual) { manualSheet }
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
        if rot.connected { return rot.stalled ? ODTheme.warning : ODTheme.good }
        if rot.connecting { return ODTheme.accent }
        return rot.errorText.isEmpty ? ODTheme.muted : ODTheme.warning
    }

    @ViewBuilder private var manualSheet: some View {
        NavigationStack {
            RotatorManualView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showManual = false }
                    }
                }
        }
    }
}

// MARK: - Shared pieces

/// Satellite / Sun / Moon / Manual target picker.
struct RotatorTargetPicker: View {
    @EnvironmentObject private var rot: RotatorController

    var body: some View {
        Picker("Target", selection: Binding(get: { rot.target.kind }, set: { rot.setTarget(kind: $0) })) {
            ForEach(RotatorTargetKind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// "Point at <new>?" when the selection changed mid-pass.
struct RotatorSwitchPrompt: View {
    @EnvironmentObject private var rot: RotatorController
    let pending: RotatorController.PendingSwitch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Point at \(pending.name)?").font(.subheadline.weight(.semibold))
            Text("The rotator is still on the \(rot.engagedSatelliteName) pass.")
                .font(.caption).foregroundStyle(ODTheme.muted)
            HStack {
                Button("Switch") { rot.switchToPending() }.buttonStyle(.borderedProminent)
                Button("Keep \(rot.engagedSatelliteName)") { rot.keepEngaged() }.buttonStyle(.bordered)
            }
        }
    }
}

/// Commanded vs actual az/el, plus read-back and stall warnings.
struct RotatorPositionRows: View {
    @EnvironmentObject private var rot: RotatorController

    var body: some View {
        // Always a 0–360° compass heading, whatever range the rotator is commanded in.
        MetricRow("Azimuth", String(format: "%.0f° %@", rot.displayAz, ODFormat.compass(rot.displayAz)), valueColor: ODTheme.good)
        if !rot.config.azimuthOnly {
            MetricRow("Elevation", rot.flipActive ? String(format: "%.0f° (flipped)", rot.commandedEl)
                                                  : String(format: "%.0f°", rot.commandedEl),
                      valueColor: ODTheme.warning)
        }
        if rot.readBackActive {
            if let az = rot.displayActualAz {
                MetricRow("Actual", rot.config.azimuthOnly ? String(format: "az %.0f°", az)
                                                           : String(format: "az %.0f° el %.0f°", az, rot.actualEl ?? 0),
                          valueColor: rot.stalled ? ODTheme.warning : .primary)
            } else if !rot.readBackError.isEmpty {
                MetricRow("Actual", rot.readBackError, valueColor: ODTheme.warning)
            }
            if rot.stalled {
                Label("Rotator isn't following the command — check for a stall, limit or jam.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(ODTheme.warning)
            }
        }
    }
}

// MARK: - Manual control

/// Jog, go-to, stop and park by hand, with live read-back.
struct RotatorManualView: View {
    @EnvironmentObject private var rot: RotatorController
    @State private var goAz = ""
    @State private var goEl = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle().fill(rot.connected ? (rot.stalled ? ODTheme.warning : ODTheme.good) : ODTheme.muted)
                        .frame(width: 10, height: 10)
                    Text(rot.connected ? rot.statusText : "Not connected").font(.subheadline.weight(.semibold))
                }
                if rot.connected { RotatorPositionRows() }
            }

            Section("Target") {
                RotatorTargetPicker()
                if rot.target != .satellite {
                    Button {
                        rot.target = .satellite
                    } label: {
                        Label("Resume satellite tracking", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }

            Section("Jog azimuth") {
                jogRow([-10, -5, -1, 1, 5, 10]) { rot.jog(azimuth: $0) }
            }
            if !rot.config.azimuthOnly {
                Section("Jog elevation") {
                    jogRow([-5, -1, 1, 5]) { rot.jog(elevation: $0) }
                }
            }

            Section("Go to") {
                HStack {
                    TextField("Az °", text: $goAz).keyboardType(.decimalPad).textFieldStyle(.odField)
                    if !rot.config.azimuthOnly {
                        TextField("El °", text: $goEl).keyboardType(.decimalPad).textFieldStyle(.odField)
                    }
                    Button("Go") { goTo() }
                        .buttonStyle(.borderedProminent)
                        .disabled(Double(goAz) == nil)
                }
                Text("True bearings; alignment offsets and magnetic correction are applied as in tracking.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }

            Section {
                HStack {
                    Button(role: .destructive) { rot.stopMotion() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { rot.parkNow() } label: {
                        Label("Park", systemImage: "parkingsign").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if !rot.config.proto.supportsStop {
                    Text("\(rot.config.proto.label) has no stop command: Stop holds, and the rotator finishes its current move.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
        }
        .disabled(!rot.connected)
        .navigationTitle("Manual Control")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func jogRow(_ steps: [Double], _ action: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Button { action(step) } label: {
                    Text(verbatim: step > 0 ? "+\(Int(step))" : "\(Int(step))")
                        .font(.body.monospacedDigit()).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func goTo() {
        guard let az = Double(goAz.replacingOccurrences(of: ",", with: ".")) else { return }
        let el = Double(goEl.replacingOccurrences(of: ",", with: ".")) ?? 0
        rot.pointManually(azimuth: az, elevation: rot.config.azimuthOnly ? 0 : el)
    }
}

// MARK: - Self-test

struct RotatorSelfTestView: View {
    @EnvironmentObject private var rot: RotatorController

    var body: some View {
        List {
            Section {
                Button {
                    rot.runSelfTest()
                } label: {
                    HStack {
                        Label("Run self-test", systemImage: "checklist")
                        if rot.selfTestRunning { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(rot.selfTestRunning || !rot.connected)
                Text(rot.connected
                     ? "Reads the position, sends a null move (no motion), then slews azimuth 5° and returns — the antenna moves. Tracking pauses during the test."
                     : "Connect the rotator from the Home card first.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            if !rot.selfTestSteps.isEmpty {
                Section("Results") {
                    ForEach(rot.selfTestSteps) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                icon(step.result)
                                Text(step.title).font(.subheadline.weight(.semibold))
                            }
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.caption.monospaced())
                            }
                            if !step.hint.isEmpty {
                                Text(step.hint).font(.caption).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Rotator Self-Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func icon(_ r: RotatorSelfTestStep.Result) -> some View {
        switch r {
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(ODTheme.good)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(ODTheme.accent)
        }
    }
}

// MARK: - Monitor

/// Passive live trace of rotator traffic (> sent, < received).
struct RotatorMonitorView: View {
    @EnvironmentObject private var rot: RotatorController
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    var body: some View {
        List {
            Section {
                Toggle("Record traffic", isOn: $rot.monitorEnabled)
                Text("Shows every command (>) and reply (<) on the rotator link: text protocols as text, SPID as hex. Keeps the last 500 lines. Traffic appears when something drives the rotator.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                if !rot.monitorLines.isEmpty {
                    HStack {
                        Button { UIPasteboard.general.string = rot.monitorText } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: rot.monitorText) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button(role: .destructive) { rot.clearMonitor() } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Section("Traffic") {
                if rot.monitorLines.isEmpty {
                    Text(rot.monitorEnabled ? "Waiting for traffic…" : "Off").foregroundStyle(ODTheme.muted)
                } else {
                    ForEach(rot.monitorLines.reversed()) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.timeFormat.string(from: line.date)).foregroundStyle(ODTheme.muted)
                            Text(line.outgoing ? ">" : "<")
                            Text(line.text).textSelection(.enabled)
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.outgoing ? ODTheme.warning : ODTheme.good)
                    }
                }
            }
        }
        .navigationTitle("Rotator Monitor")
        .navigationBarTitleDisplayMode(.inline)
    }
}
