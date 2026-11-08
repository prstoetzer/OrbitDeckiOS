import Foundation
import Combine
import CoreMotion

// ===========================================================================
//  RigController.swift — CAT orchestration
//
//  Owns the configured radios, their transports, and the Doppler tuning loop.
//  Mirrors the way Home computes live dials (OrbitPredictor.dopplerFrequencies +
//  per-satellite calibration + passband offset), then routes the corrected
//  downlink/uplink frequencies to the right radio and VFO:
//
//   • one full-duplex radio (role .both): downlink → SUB, uplink → MAIN
//   • one half-duplex radio (role .downlink/.uplink): that leg only
//   • two radios: slot 0 = downlink, slot 1 = uplink
//
//  Transverter LO offsets, FM/linear write deadbands, predictive lead, satellite
//  mode, band assignment and uplink CTCSS all come from `CATTuning`.
// ===========================================================================

@MainActor
final class RigController: ObservableObject {
    @Published var config = CATConfig()
    @Published var connected = false
    @Published var connecting = false
    @Published var statusText = "Not connected."
    @Published var errorText = ""
    /// Live corrected dials (real, transverter-inclusive) for the Home card.
    @Published var downlinkDialHz: Int64 = 0
    @Published var uplinkDialHz: Int64 = 0
    /// When true, the periodic Doppler loop stops pushing continuous updates; the dial
    /// is stepped explicitly instead (see `stepDopplerNow()`). An active FT4 session sets
    /// this so the frequency changes only at slot boundaries — the dial stays constant
    /// within each 7.5 s slot and the audio-domain de-Doppler removes the residual drift,
    /// rather than a mid-slot retune smearing the coherent decode.
    /// The hold is scoped to the satellite + transponder CAT was on when it began: if CAT
    /// moves to another one (automatic switching, a new selection) while FT4 is still
    /// running, that one gets continuous Doppler (see `dopplerHeld()`).
    var holdDoppler = false {
        didSet {
            guard holdDoppler != oldValue else { return }
            holdSatTp = holdDoppler ? currentSatTp() : ""
            holdScopeMismatch = false
            ODLog.shared.log("Doppler hold \(holdDoppler ? "ON for \(holdSatTp.isEmpty ? "(no transponder yet)" : holdSatTp)" : "OFF")", category: "cat")
        }
    }
    /// "<NORAD>|<transponder id>" the FT4 hold applies to ("" = not yet known).
    private var holdSatTp = ""
    /// True while the hold is bypassed because CAT is on a different transponder (logged once).
    private var holdScopeMismatch = false
    /// Which transponder of the selected satellite CAT tracks.
    @Published var transponderID: String?
    /// True while the passband offset is pinned at the transponder edge (clamped in `tick`).
    @Published private(set) var atPassbandEdge = false
    /// The satellite CAT is engaged on (nil = not yet / disconnected). During a pass it
    /// stays put when the selection changes, unless `followSelection` is on or the change
    /// came from automatic switching — see `resolveEngagement()`.
    @Published private(set) var engagedNorad: UInt?
    /// The transponder CAT was tracking on the engaged satellite, kept while locked.
    private var engagedTpID: String?
    /// A selection CAT hasn't moved to yet ("Switch radio to …?" on the rig card).
    @Published private(set) var pendingSwitchNorad: UInt?
    /// A pending switch the operator answered "Keep" to (not asked again for it).
    private var dismissedSwitchNorad: UInt?
    /// Set by AutoSwitchController just before it changes the selection: its picks are
    /// authoritative and move CAT straight away.
    static var automaticSelectionNorad: UInt?
    /// Tilt (device roll) passband tuning on the Home card. Never persisted: off at launch.
    @Published var tiltTuning = false { didSet { if tiltTuning != oldValue { tilt.setActive(tiltTuning, rig: self) } } }
    private let tilt = TiltTuner()
    /// Per-radio connection status for the Home card (one entry per configured
    /// radio, so a two-radio station shows both).
    @Published var statuses: [RigLinkStatus] = []

    struct RigLinkStatus: Identifiable, Sendable {
        let id: Int
        let radioName: String
        let transport: CATTransportKind
        let leg: RigRole
        var split = false
        var connecting: Bool
        var connected: Bool
        var error: String?
        var hint: String?

        var stateText: String {
            if connecting { return "Connecting…" }
            if let error { return error }
            if connected { return "Connected" }
            return "Not connected"
        }
        /// e.g. "IC-705 · Icom network (Wi-Fi)" or "TH-D75 · BLE — downlink".
        var title: String {
            var s = "\(radioName) · \(transport.label)"
            if split { s += " — split VFO" }
            else if leg != .both { s += " — \(leg == .uplink ? "uplink" : "downlink")" }
            return s
        }
    }

    private weak var store: OrbitStore?
    private var links: [LiveLink] = []
    private var timer: DispatchSourceTimer?
    private var isTicking = false
    // Auto-reconnect on an unexpected link drop (see handleLinkDropped).
    private var reconnecting = false
    private var reconnectAttempts = 0
    private var lastConnectAt = Date.distantPast
    private var wantConnection = false      // operator intent — false after a manual disconnect()
    private var lastSentRx: Int64 = 0
    private var lastSentTx: Int64 = 0
    /// One-tick uplink deferral after a downlink move (CardSat's driveUplinkDeferred):
    /// keeps the shared CI-V bus uncongested and avoids a MAIN excursion every tick.
    private var uplinkDeferTicks = 0
    /// Identifies the current satellite/transponder/mode so mode + step are
    /// re-applied whenever any of them changes (not just at connect).
    private var lastEngageKey = ""
    /// Command the rig's DATA sub-mode (USB-D/LSB-D, FM-D) for the digital audio path. On
    /// while any client (FT4, packet, SSTV — see `setDigitalDataMode`) wants it, so the
    /// ACC/USB data port carries the audio rather than the mic. Only affects data-capable
    /// rigs (`isDataModeCapable`).
    /// A client's request is scoped to the satellite/transponder CAT was on when it asked,
    /// so FT4's USB-D or packet's FM-D never follows CAT onto another bird (e.g. an FM
    /// voice satellite after automatic switching, where FM-D would cut the mic).
    private var useDataModeForDigital: Bool {
        let now = currentSatTp()
        return dataModeClients.values.contains { $0.isEmpty || $0 == now }
    }
    /// Legs we put in a DATA sub-mode and must take out again, per radio and leg (a
    /// single flag was cleared by whichever leg ran first, stranding the other in USB-D).
    private var dataModeLegs = Set<String>()
    /// Satellite + transponder of the last engage, so the passband offset is reset only
    /// when the bird or transponder changes (not on a mode/data change).
    private var lastEngageSatTp = ""
    /// The latest Doppler-corrected downlink dial (rig units), restored after an FT-847
    /// same-band transmit hold.
    private var lastTargetRx: Int64 = 0
    /// TH-D7x: the band of the last FQ, so a cross-band move re-applies the step.
    private var lastKhtBand = 0

    /// Data-mode-capable CI-V transceivers (USB-D via the CI-V 0x26 mode+data command).
    /// Older rigs (IC-820/821/910/970/9100, IC-2xx/4xx, IC-706 family, IC-7000) predate 0x26
    /// and are left on plain SSB.
    private static let dataModeModels: Set<String> = ["IC-9700", "IC-705", "IC-905", "IC-7100"]
    /// Yaesu rigs with a DIG data mode (0x0A). The FT-847/736R have no CAT data mode.
    private static let yaesuDataModels: Set<String> = ["FT-817", "FT-818", "FT-857", "FT-897"]
    /// A full-duplex Kenwood with satellite mode (TS-2000/TS-790) — needs the SATL
    /// entry handshake and dual-control (DC) band select for per-leg mode/tone.
    private func kenwoodSat(_ spec: RadioSpec) -> Bool {
        spec.family == .kenwoodBase && spec.fullDuplex && spec.hasSatMode
    }

    /// Whether this radio can be put in a DATA sub-mode for the digital audio path.
    private func isDataModeCapable(_ spec: RadioSpec) -> Bool {
        switch spec.family {
        case .civ:         return Self.dataModeModels.contains(spec.id)
        case .rigctld:     return true      // Hamlib maps to PKT* on radios that have it
        case .yaesuBinary: return Self.yaesuDataModels.contains(spec.id)
        default:           return false     // Kenwood/FT-736R/FT-847: no clean CAT data mode
        }
    }

    /// Digital-mode clients (FT4, packet, SSTV) currently asking for the DATA sub-mode,
    /// with the "<NORAD>|<transponder id>" each asked on ("" = not known yet; adopts the
    /// first transponder seen).
    private var dataModeClients: [String: String] = [:]
    /// Whether a mode carries the digital data path: SSB (USB-D/LSB-D) or FM (FM-D/PKT).
    private func dataModeSuits(_ mode: RigMode) -> Bool {
        mode == .usb || mode == .lsb || mode.isFM
    }

    /// Request (or release) the digital DATA sub-mode for one client. Reference-counted:
    /// data mode stays on while any client wants it. When the overall state changes the
    /// modes are re-applied on the next tick (the engage key includes the flag).
    func setDigitalDataMode(_ on: Bool, client: String = "ft4") {
        let before = useDataModeForDigital
        if on { dataModeClients[client] = currentSatTp() } else { dataModeClients[client] = nil }
        ODLog.shared.log("setDigitalDataMode(\(on)) client=\(client) clients=\(dataModeClients.sorted { $0.key < $1.key }) connected=\(connected) hold=\(holdDoppler)", category: "cat")
        guard useDataModeForDigital != before else { return }
        lastEngageKey = ""     // force applyModes() to run again
        if connected, dopplerHeld() { Task { await stepDopplerNow() } }   // FT4 is slot-gated
    }

    /// "<NORAD>|<transponder id>" CAT is tracking now, or "" if none.
    private func currentSatTp() -> String {
        guard let sat = trackedSatellite, let tp = transponder(for: sat) else { return "" }
        return "\(sat.id)|\(tp.id)"
    }

    // MARK: Engaged satellite

    /// The satellite CAT tunes: the engaged one while a pass is locked on it, else the
    /// app-wide selection.
    var trackedSatellite: SatelliteRecord? {
        guard let store else { return nil }
        if let n = engagedNorad, n != store.selectedSatellite?.id,
           let sat = store.satellites.first(where: { $0.id == n }) { return sat }
        return store.selectedSatellite
    }

    /// Whether CAT is tuning a satellite other than the one selected in the app.
    var tuningOtherSatellite: Bool {
        connected && engagedNorad != nil && engagedNorad != store?.selectedSatellite?.id
    }

    /// Follow (or hold off on) a selection change. While the engaged satellite is above
    /// the horizon a manual change is only offered (`pendingSwitchNorad`); automatic
    /// switching, the "Follow selection while connected" setting, or the engaged pass
    /// having ended move CAT at once.
    private func resolveEngagement() {
        guard let store, let sel = store.selectedSatellite else { return }
        guard let current = engagedNorad, current != sel.id else {
            engagedNorad = sel.id
            pendingSwitchNorad = nil; dismissedSwitchNorad = nil
            Self.automaticSelectionNorad = nil
            return
        }
        let automatic = Self.automaticSelectionNorad == sel.id
        let engagedSat = store.satellites.first { $0.id == current }
        let up = engagedSat.flatMap { try? OrbitPredictor.look($0, observer: store.preferences.observer, at: Date()).elevation }
            .map { $0 >= 0 } ?? false
        if automatic || config.tuning.followSelection || !up {
            ODLog.shared.log("CAT follows the selection to \(sel.name)\(automatic ? " (automatic switching)" : "")", category: "cat")
            Self.automaticSelectionNorad = nil
            switchEngaged(to: sel.id)
        } else if pendingSwitchNorad != sel.id, dismissedSwitchNorad != sel.id {
            pendingSwitchNorad = sel.id
            ODLog.shared.log("selection changed to \(sel.name) during a pass — CAT stays on \(engagedSat?.name ?? "#\(current)") until you switch", category: "cat")
        }
    }

    private func switchEngaged(to norad: UInt) {
        engagedNorad = norad; engagedTpID = nil
        pendingSwitchNorad = nil; dismissedSwitchNorad = nil
    }

    /// "Switch": move CAT to the pending selection.
    func acceptPendingSwitch() {
        guard let n = pendingSwitchNorad else { return }
        switchEngaged(to: n)
        ODLog.shared.log("operator switched CAT to the selection", category: "cat")
    }

    /// "Keep": stay on the engaged satellite and stop asking for this selection.
    func keepEngagedSatellite() {
        dismissedSwitchNorad = pendingSwitchNorad
        pendingSwitchNorad = nil
    }

    /// Whether the FT4 slot-gated hold applies right now: `holdDoppler` is set AND CAT is
    /// still on the transponder the hold began on. Otherwise the periodic loop runs as
    /// normal (logged once per change).
    private func dopplerHeld() -> Bool {
        guard holdDoppler else { return false }
        let now = currentSatTp()
        if holdSatTp.isEmpty { holdSatTp = now }      // hold began before a transponder was known
        let applies = now == holdSatTp
        if applies == holdScopeMismatch {
            holdScopeMismatch = !applies
            ODLog.shared.log(applies
                ? "Doppler hold: back on \(holdSatTp) — slot-gated stepping resumed"
                : "Doppler hold: CAT moved from \(holdSatTp) to \(now.isEmpty ? "(none)" : now) — continuous Doppler while FT4 holds the other transponder",
                category: "cat")
        }
        return applies
    }
    /// Last "why the loop can't tune" message, so we log it only when it changes.
    private var lastTickBail = ""
    /// Throttle for per-tick frequency-send logging (diagnostics).
    private var lastFreqLogAt = Date.distantPast
    /// Previous tick's commanded downlink dial + time, for the adaptive-deadband (D2)
    /// Doppler-slew estimate. Reset in startLoop().
    private var lastTickRxReal: Int64 = 0
    private var lastTickTime = Date.distantPast
    /// While the operator is turning the dial on the followed leg, Doppler on that leg is
    /// paused until this time (a short settle window) so we don't fight them mid-turn.
    private var followSettleUntil = Date.distantPast

    private struct LiveLink {
        let slot: RigSlot
        let spec: RadioSpec
        let transport: CATTransport
        let leg: RigRole      // .both, .downlink or .uplink
        /// Single-radio split VFO (leg .both): VFO A = downlink, VFO B = uplink.
        var split = false
        /// Split only: VFO B is addressed directly (CI-V 0x25/0x26, Kenwood FB) rather
        /// than by swapping VFOs. Set at engage (the IC-7100 is probed).
        var directVFOB = false
        /// FT-847 same-band transmit hold: no CAT split exists, so satellite mode is off,
        /// the main VFO tracks the downlink, and it moves to the uplink only while keyed.
        var txHold = false
        /// Receive-only transponder on a full-duplex Icom (beacon/telemetry, no uplink):
        /// satellite mode off and the downlink tuned on MAIN (see `reconcileLayout`).
        var rxOnlyLayout = false
        /// Position in `links` (0 = primary radio, 1 = two-radio uplink), for per-link
        /// "what we changed on the radio" bookkeeping.
        var index = 0
    }

    /// Links whose uplink CTCSS encoder OrbitDeck turned on (by `LiveLink.index`), so it
    /// is turned off again on a non-tone transponder and on an operator disconnect.
    private var toneLinks = Set<Int>()
    /// Full-duplex Icom links OrbitDeck put in satellite mode, taken out on disconnect.
    private var satModeLinks = Set<Int>()
    /// rigctld links whose server runs in `--vfo` mode (VFO inline on every command).
    private var rigctldInline = Set<Int>()
    /// rigctld VFO mode on a plain server: the VFO last selected with `V`, per link.
    private var rigctldCurrentVFO: [Int: String] = [:]

    /// True while OrbitDeck has the uplink keyed (FT4/PTT). Split rigs that must
    /// swap VFOs to reach VFO B skip uplink writes then, so a swap never lands
    /// mid-transmission. (A manual PTT press can't be seen.)
    private var pttKeyed = false
    /// The latest Doppler-corrected uplink dial (rig units), pushed just before
    /// keying a split rig so the transmission starts on frequency.
    private var lastTargetTx: Int64 = 0

    private static let configKey = "orbitdeck.rigConfig"

    func attach(_ store: OrbitStore) {
        self.store = store
        // Persist CAT config in its own UserDefaults key, NOT in store.preferences:
        // writing the store's @Published preferences rebuilds the whole detail
        // column and freezes navigation when leaving the settings screen.
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(CATConfig.self, from: data) {
            config = saved
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: Connect / disconnect

    func connect() {
        guard !connecting, !connected else { return }
        // The exit sequence of a just-requested disconnect is still talking to the old
        // links; connecting now would let its teardown remove the new ones.
        guard !disconnecting else { statusText = "Disconnecting…"; return }
        guard config.isConfigured, let slot0 = config.slots.first, let spec0 = slot0.spec else {
            errorText = "Configure a radio first."; return
        }
        if let problem = stationProblem() { statuses.removeAll(); errorText = problem; return }
        connecting = true; wantConnection = true; errorText = ""; statusText = "Connecting…"
        persist()

        // Build the link list. Slot 0 is the primary radio; slot 1 (dual) is uplink.
        var built: [LiveLink] = []
        // A receive-only radio (CI-V receivers, RX-only handhelds) can only ever be a
        // downlink: never honor a config that assigns it the uplink/both leg, so no TX
        // frequency/mode/PTT frame is sent to a radio that must not transmit.
        // Single-radio split VFO: one radio, both legs, on VFO A/B (rigctld has its own
        // split option and is excluded here).
        let split0 = !config.twoRadios && slot0.splitVFO && slot0.transport != .rigctld && spec0.supportsSplit
        let leg0: RigRole = split0 ? .both : (config.twoRadios ? .downlink : (spec0.rxOnly ? .downlink : slot0.role))
        built.append(LiveLink(slot: slot0, spec: spec0, transport: makeTransport(slot0, spec: spec0, index: 0),
                              leg: leg0, split: split0))
        if config.twoRadios, config.slots.count > 1, config.slots[1].enabled, let spec1 = config.slots[1].spec {
            if spec1.rxOnly {
                ODLog.shared.log("ignoring uplink radio \(spec1.name): receive-only", category: "cat")
            } else {
                built.append(LiveLink(slot: config.slots[1], spec: spec1,
                                      transport: makeTransport(config.slots[1], spec: spec1, index: 1), leg: .uplink,
                                      index: built.count))
            }
        }
        links = built
        // Bring the whole station back if any link drops unexpectedly after connect (a
        // brief Wi-Fi/BLE blip, the radio power-cycling, or the app being backgrounded and
        // iOS reclaiming the sockets). transport.onDisconnect only fires on a live drop,
        // never on our own disconnect().
        for link in links {
            link.transport.onDisconnect = { [weak self] in
                Task { @MainActor in self?.handleLinkDropped() }
            }
        }
        // Seed per-radio status (both show "Connecting…" for a two-radio station).
        statuses = built.enumerated().map { i, link in
            RigLinkStatus(id: i, radioName: link.spec.name, transport: link.slot.transport,
                          leg: link.leg, split: link.split, connecting: true, connected: false, error: nil, hint: nil)
        }
        for link in built {
            ODLog.shared.log("connect start: \(link.spec.name) via \(String(describing: link.slot.transport)) leg=\(String(describing: link.leg)) host=\(link.slot.host):\(link.slot.port)", category: "cat")
        }

        Task {
            // Connect all radios concurrently so both progress at once. Capture the
            // Sendable transport, not the (non-Sendable) LiveLink.
            await withTaskGroup(of: (Int, Error?).self) { group in
                for (i, link) in links.enumerated() {
                    let t = link.transport
                    group.addTask {
                        do { try await t.connect(); return (i, nil) }
                        catch { return (i, error) }
                    }
                }
                for await (i, err) in group where i < statuses.count {
                    statuses[i].connecting = false
                    if let err {
                        let errorText = err.localizedDescription
                        statuses[i].error = errorText
                        ODLog.shared.log("connect failed [\(statuses[i].radioName)]: \(errorText)", category: "cat")
                        if statuses[i].transport == .bleicom,
                           err as? IComBLESerialTransport.BLEError == .accessNotGranted {
                            statuses[i].hint = "Hint: If you are pairing your Icom radio via Bluetooth for the first time, go to Menu > Set > Bluetooth Set > Pairing Reception and then try to connect again."
                        }
                    } else {
                        statuses[i].connected = true
                        ODLog.shared.log("connected [\(statuses[i].radioName)]", category: "cat")
                    }
                }
            }

            if statuses.allSatisfy({ $0.connected }) {
                await engageOnce()
                connected = true; connecting = false
                lastConnectAt = Date()
                statusText = "Connected."
                ODLog.shared.log("all radios connected; Doppler loop started", category: "cat")
                startLoop()
            } else {
                connecting = false; connected = false
                errorText = statuses.compactMap(\.error).first ?? "Connection failed."
                statusText = "Connection failed."
                ODLog.shared.log("connection failed: \(errorText)", category: "cat")
                await teardown()
            }
        }
    }

    /// Station setups that would otherwise connect but misbehave quietly: a two-radio
    /// station whose uplink radio isn't set up (it would run downlink-only), a BLE link
    /// with no device chosen (it would scan for a random ID until the timeout), or both
    /// radios on the same BLE adapter (both links would drive one radio).
    private func stationProblem() -> String? {
        var active = [0]
        if config.twoRadios {
            guard config.slots.count > 1, config.slots[1].enabled, config.slots[1].spec != nil else {
                return "Two radios is on, but Radio 2 (uplink) isn't set up. Turn on \"Use this radio\" and choose a model, or turn off Two radios."
            }
            active.append(1)
        }
        let ble = active.filter { config.slots[$0].transport == .ble || config.slots[$0].transport == .bleicom }
        for i in ble where UUID(uuidString: config.slots[i].bleIdentifier) == nil {
            let which = config.twoRadios ? "Radio \(i + 1)" : "the radio"
            return "Choose a BLE device for \(which) in Rig Control settings."
        }
        if ble.count == 2, config.slots[0].bleIdentifier == config.slots[1].bleIdentifier {
            return "Radio 1 and Radio 2 are set to the same BLE device. Each radio needs its own adapter (or its own built-in Bluetooth)."
        }
        return nil
    }

    /// True while an operator disconnect's exit sequence (tone off, SATL/split/sat-mode
    /// exits, teardown) is still running.
    @Published private(set) var disconnecting = false

    func disconnect() {
        guard !disconnecting else { return }
        timer?.cancel(); timer = nil
        SSTVDopplerFeed.set(0)      // stop feeding a stale Doppler residual to the SSTV decoder
        // Clear `connected` BEFORE tearing the transports down: closing a socket can fire
        // its onError/state handler, and handleLinkDropped() guards on `connected`, so this
        // stops a caller-initiated disconnect from being mistaken for a live drop.
        connected = false
        wantConnection = false
        reconnectAttempts = 0
        statuses.removeAll()
        // The engaged-satellite lock ends with the session (a reconnect after a drop keeps it).
        engagedNorad = nil; engagedTpID = nil; pendingSwitchNorad = nil; dismissedSwitchNorad = nil
        tiltTuning = false
        // Leave the radio the way we found it on an operator-initiated disconnect
        // (best-effort; the link is still up here): uplink tone off, Kenwood out of SATL,
        // split off on VFO A, Icom satellite mode off on MAIN.
        disconnecting = true
        Task {
            defer { disconnecting = false }
            // Let an in-flight tick finish so its frames don't interleave with the exit.
            var waited = 0
            while isTicking, waited < 2000 { await pace(20); waited += 20 }
            await sendToneExit()
            await sendKenwoodSatExit()
            await sendSplitExit()
            await sendIcomSatExit()
            await teardown()
            statusText = "Not connected."
        }
    }

    /// Best-effort uplink CTCSS off on every leg where OrbitDeck turned it on. A Kenwood
    /// in SATL is left to its SATL exit (which clears the tone itself).
    private func sendToneExit() async {
        for link in links where toneLinks.contains(link.index) {
            if link.txHold {
                for f in CATCodec.ft847Tone(on: false, toneHz: 0, main: true) { await sendRaw(link, f) }
            } else if link.split {
                await sendSplitTone(link, on: false, toneHz: 0)
            } else if link.leg == .both {
                if kenwoodSat(link.spec) { continue }
                // Full-duplex Icom: the tone lives on the uplink band — select it first.
                if let sel = bandSelect(link, leg: .uplink) { await sendRaw(link, sel) }
                await sendTone(link, on: false, toneHz: 0)
                await reselectDownlink(link)
            } else {
                await sendTone(link, on: false, toneHz: 0)
            }
            ODLog.shared.log("disconnect: uplink CTCSS OFF → \(link.spec.name)", category: "cat")
        }
        toneLinks.removeAll()
    }

    /// Best-effort satellite mode off (where OrbitDeck turned it on) and MAIN band
    /// selected again on a full-duplex Icom.
    private func sendIcomSatExit() async {
        for link in links where link.spec.family == .civ && link.spec.fullDuplex && link.leg == .both && !link.split {
            let addr = civAddr(link)
            if satModeLinks.contains(link.index), let off = CATCodec.civSatMode(link.spec, addr: addr, on: false) {
                await sendRaw(link, off); await pace(60)
                ODLog.shared.log("disconnect: sat mode OFF → \(link.spec.name)", category: "cat")
            }
            if let main = CATCodec.civSelect(link.spec, addr: addr, sub: false) {
                await sendRaw(link, main)
                ODLog.shared.log("disconnect: MAIN selected → \(link.spec.name)", category: "cat")
            }
        }
        satModeLinks.removeAll()
    }

    /// Best-effort SATL exit for a full-duplex Kenwood before teardown.
    private func sendKenwoodSatExit() async {
        for link in links where kenwoodSat(link.spec) && link.leg == .both && !link.split {
            for f in CATCodec.kwSatExit() { await sendRaw(link, f) }
            ODLog.shared.log("disconnect: Kenwood SATL exit → \(link.spec.name)", category: "cat")
        }
    }

    /// Best-effort SPLIT off on an operator disconnect, leaving the radio as found on
    /// VFO A (the Yaesu FT-817 family can only toggle VFOs, so it's left as is).
    private func sendSplitExit() async {
        for link in links where link.split {
            let addr = civAddr(link)
            switch link.spec.family {
            case .civ:
                await sendRaw(link, CATCodec.civSplit(addr: addr, on: false))
                await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
            case .yaesuBinary: await sendRaw(link, CATCodec.yaesuSplitOff)
            case .yaesuFT100:
                await sendRaw(link, CATCodec.ft100Split(on: false))
                await sendRaw(link, CATCodec.ft100SelectVFO(b: false))
            case .kenwoodBase:
                // FR/FT rigs: FR0;FT0 is already VFO A. FN/SP rigs: SP0, then FN0.
                for f in CATCodec.kwSplit(on: false, frft: link.spec.kenwoodSplitFRFT) { await sendRaw(link, f) }
                if !link.spec.kenwoodSplitFRFT { await sendRaw(link, CATCodec.kwActiveVFO(b: false, frft: false)) }
            default: break
            }
            ODLog.shared.log("disconnect: split OFF, VFO A → \(link.spec.name)", category: "cat")
        }
    }

    /// Split engage: take the rig out of any satellite mode (split runs on one band),
    /// park it on VFO A (receive) and turn SPLIT on so VFO B transmits. Returns whether
    /// the rig can address VFO B directly (CI-V 0x25/0x26), probing the IC-7100.
    private func engageSplit(_ link: LiveLink) async -> Bool {
        let addr = civAddr(link)
        var direct = false
        switch link.spec.family {
        case .civ:
            // Split is MAIN-band only on the IC-910H/9100/9700 and needs satellite mode off.
            if let off = CATCodec.civSatMode(link.spec, addr: addr, on: false) {
                await sendRaw(link, off); await pace(60)
                satModeLinks.remove(link.index)
            }
            if link.spec.fullDuplex, let main = CATCodec.civSelect(link.spec, addr: addr, sub: false) { await sendRaw(link, main) }
            await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
            await sendRaw(link, CATCodec.civSplit(addr: addr, on: true))
            direct = link.spec.civUnselectedVFO
            if link.spec.civUnselectedVFOMaybe {
                // IC-7100: 0x25/0x26 need firmware E4+. Ask for the selected VFO's
                // frequency with 25 00; a 25 reply means supported, FA/silence means not.
                _ = await readReply(link, maxWait: 0.05)   // drop stale bytes
                await sendRaw(link, CATCodec.civProbeUnselectedVFO(addr: addr))
                let reply = await readReply(link, maxWait: 0.5)
                direct = CATCodec.civReply(reply, addr: addr, cmd: 0x25) != nil
                ODLog.shared.log("split: \(link.spec.name) 0x25/0x26 \(direct ? "supported" : "not supported (pre-E4 firmware?) — using VFO swaps")", category: "cat")
            }
        case .yaesuBinary:
            // These rigs can only toggle VFOs, so make sure we start on A. The VFO bit
            // lives in EEPROM (0x55 on the 817/818, 0x68 on the 857/897); some 857/897
            // units don't answer, in which case we assume the operator left it on A.
            _ = await readReply(link, maxWait: 0.05)
            await sendRaw(link, CATCodec.yaesuReadEEPROM(CATCodec.yaesuVFOStatusAddress(link.spec)))
            let reply = await readReply(link, maxWait: 0.5)
            if let status = reply.first, reply.count >= 2 {
                if status & 0x01 == 1 {
                    await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50)
                    ODLog.shared.log("split: \(link.spec.name) was on VFO B — toggled to A", category: "cat")
                }
            } else {
                ODLog.shared.log("split: \(link.spec.name) VFO status unreadable — assuming VFO A", category: "cat")
            }
            await sendRaw(link, CATCodec.yaesuSplitOn)
        case .yaesuFT100:
            await sendRaw(link, CATCodec.ft100SelectVFO(b: false))
            await sendRaw(link, CATCodec.ft100Split(on: true))
        case .kenwoodBase:
            if kenwoodSat(link.spec) { for f in CATCodec.kwSatExit() { await sendRaw(link, f); await pace(60) } }
            // Commands go to the MAIN band: TS-2000 DC00 (TX + CTRL main), TS-790 DC0.
            if link.spec.id == "TS-2000" { await sendRaw(link, Array("DC00;".utf8)) }
            if link.spec.id == "TS-790" { await sendRaw(link, Array("DC0;".utf8)) }
            for f in CATCodec.kwSplit(on: true, frft: link.spec.kenwoodSplitFRFT) { await sendRaw(link, f); await pace(30) }
        default:
            break
        }
        ODLog.shared.log("split VFO ON → \(link.spec.name) (VFO A = RX, VFO B = TX\(direct ? ", direct VFO B" : ""))", category: "cat")
        return direct
    }

    private func teardown() async {
        SSTVDopplerFeed.set(0)      // no more live Doppler residual for the SSTV decoder
        for link in links { await link.transport.disconnect() }
        links.removeAll()
        // A reconnect re-engages and re-records what it turns on.
        toneLinks.removeAll(); satModeLinks.removeAll()
        rigctldInline.removeAll(); rigctldCurrentVFO.removeAll()
        atPassbandEdge = false
    }

    /// A transport reported an unexpected drop after a good connect. Stop the loop, tear
    /// the station down cleanly, and reconnect — so a pass survives a brief Wi-Fi/BLE blip
    /// or the app being backgrounded. Bounded (3 tries) so a radio that stays down doesn't
    /// spin forever; a session that had been stable for a while resets the counter, so this
    /// only gives up on genuine flapping.
    private func handleLinkDropped() {
        guard connected, !reconnecting else { return }
        reconnecting = true
        connected = false
        timer?.cancel(); timer = nil
        if Date().timeIntervalSince(lastConnectAt) > 30 { reconnectAttempts = 0 }
        Task {
            await teardown()
            reconnecting = false
            guard reconnectAttempts < 3 else {
                statusText = "Connection lost."
                errorText = "Lost the connection to the radio. Check its power/Wi-Fi/BLE and reconnect."
                statuses.removeAll(); reconnectAttempts = 0
                ODLog.shared.log("link drop: giving up after 3 reconnect attempts", category: "cat")
                return
            }
            reconnectAttempts += 1
            statusText = "Connection lost — reconnecting (\(reconnectAttempts)/3)…"
            ODLog.shared.log("link drop: reconnect attempt \(reconnectAttempts)/3", category: "cat")
            await pace(2000)
            guard wantConnection else { return }   // operator disconnected during the backoff
            connect()
        }
    }

    /// Foreground restore: if the operator had connected but the link died while the app
    /// was backgrounded/suspended (iOS reclaims BLE + UDP sockets), bring it back. Called
    /// from the scene-phase handler on `.active`. No-op when already connected/connecting,
    /// mid-reconnect, or the operator had deliberately disconnected.
    func resumeIfNeeded() {
        guard wantConnection, !connected, !connecting, !reconnecting else { return }
        ODLog.shared.log("foreground: restoring dropped CAT connection", category: "cat")
        reconnectAttempts = 0
        connect()
    }

    private func makeTransport(_ slot: RigSlot, spec: RadioSpec, index: Int) -> CATTransport {
        switch slot.transport {
        case .network:
            let pass = OrbitSecretStore.get(index == 0 ? .rigPassword0 : .rigPassword1)
            return IcomNetworkTransport(host: slot.host, port: UInt16(slot.port),
                                        username: slot.username, password: pass, modelName: spec.name)
        case .ble:
            let uuid = UUID(uuidString: slot.bleIdentifier) ?? UUID()
            return BLESerialTransport(identifier: uuid)
        case .bleicom:
            let uuid = UUID(uuidString: slot.bleIdentifier) ?? UUID()
            return IComBLESerialTransport(identifier: uuid)
        case .rigctld:
            // Reuse the generic TCP transport (also used by rotctld); rigctld is a
            // plain line-oriented TCP protocol. Default Hamlib NET port is 4532.
            let port = UInt16(slot.port == 0 ? 4532 : min(65535, max(1, slot.port)))
            return RotatorNetworkTransport(host: slot.host, port: port, udp: false)
        }
    }

    // MARK: Engage-time setup

    /// One-time-per-connection setup: session handshakes, satellite mode.
    private func engageOnce() async {
        for index in links.indices {
            let link = links[index]
            let addr = civAddr(link)
            if link.split { links[index].directVFOB = await engageSplit(link); continue }
            // CardSat's YaesuRig::begin() sends CAT-ON on connect for both the
            // FT-847 (full-duplex) and the FT-736R. Mono FT-817-family legs don't.
            if link.spec.family == .yaesuFT736 || (link.spec.family == .yaesuBinary && link.spec.fullDuplex) {
                await sendRaw(link, CATCodec.yaesuCATOn); await pace(60)
            }
            // FT-736R: enable full-duplex (split) so the RX (main) and uplink (split TX)
            // VFOs tune independently — required for two-leg Doppler on the '736R.
            if link.spec.family == .yaesuFT736, link.spec.fullDuplex, link.leg == .both {
                await sendRaw(link, CATCodec.ft736FullDuplexOn); await pace(60)
                ODLog.shared.log("FT-736R full-duplex ON", category: "cat")
            }
            // FT-847: enter satellite mode so its SAT RX/TX VFO tracking drives actual
            // receive/transmit (Hamlib ft847.c 0x4E). Idempotent if already in SAT.
            if link.spec.family == .yaesuBinary, link.spec.fullDuplex, link.leg == .both {
                await sendRaw(link, CATCodec.ft847SatModeOn); await pace(60)
                ODLog.shared.log("FT-847 satellite mode ON", category: "cat")
            }
            if link.spec.family == .kenwoodHandheld {
                for f in CATCodec.khtSession() { await sendRaw(link, f); await pace(30) }
            }
            // Kenwood TS-2000/790: enter satellite (SATL) mode so the MAIN=downlink /
            // SUB=uplink split tracks. TRACE is left off (OrbitDeck drives Doppler). This
            // is the fix for the "Kenwood never enters sat mode" defect. Idempotent.
            if kenwoodSat(link.spec), link.leg == .both {
                for f in CATCodec.kwSatEntry() { await sendRaw(link, f); await pace(60) }
                ODLog.shared.log("Kenwood SATL entry → \(link.spec.name)", category: "cat")
            }
            // Satellite mode. The IC-9100/9700 (canAssignBand) REQUIRE satellite mode for
            // full-duplex MAIN/SUB tuning to take effect, so command it automatically for
            // those; other CI-V rigs honor the user's "Command satellite mode" toggle.
            if link.spec.family == .civ, satRig(link),
               (config.tuning.satMode || link.spec.canAssignBand),
               let f = CATCodec.civSatMode(link.spec, addr: addr, on: true) {
                // Satellite mode-on is ignored while split is on, and split can be left on
                // by a dropped link or a previous same-band pass — clear it first.
                if link.spec.supportsSplit { await sendRaw(link, CATCodec.civSplit(addr: addr, on: false)) }
                await sendRaw(link, f)
                satModeLinks.insert(link.index)
                ODLog.shared.log("sat mode ON → \(link.spec.name)", category: "cat")
                await pace(60)
            }
            if link.spec.family == .rigctld {
                // Probe \chk_vfo (CardSat): a server started with --vfo wants the VFO inline
                // on every command, including on a single-leg link.
                _ = await readReply(link, maxWait: 0.05)
                await sendRaw(link, CATCodec.rigctldChkVFO)
                let inline = CATCodec.rigctldParseChkVFO(await readReply(link, maxWait: 0.5))
                if inline { rigctldInline.insert(link.index) }
                let method = link.leg != .both ? "single VFO"
                    : (config.tuning.rigctldVFOMode ? "VFO mode (VFOA = downlink, VFOB = uplink)"
                       : (config.tuning.rigctldUseSplit ? "split (S 1 VFOB + I/X)" : "one VFO"))
                ODLog.shared.log("rigctld: \(inline ? "--vfo server (VFO inline)" : "plain server") · \(method)", category: "cat")
                // Split method: enable split so the uplink tracks on the TX VFO while the
                // downlink tracks on the RX VFO.
                if link.leg == .both, !config.tuning.rigctldVFOMode, config.tuning.rigctldUseSplit {
                    await sendRaw(link, CATCodec.rigctldLine("S", vfo: inline ? "currVFO" : nil, "1 VFOB"))
                }
            }
        }
    }

    /// Apply mode (and, for the handheld, the fine-step) and uplink tone. Called at
    /// connect and again whenever the satellite, transponder, band, mode or tone changes.
    /// `toneHz` is the resolved per-satellite tone (`SatelliteTones.resolve`). A leg we
    /// turned the tone on for is turned off again when the new transponder has none.
    private func applyModes(dlMode: RigMode, ulMode: RigMode, isFM: Bool, toneHz: Double) async {
        let toneOn = toneHz > 0 && isFM
        for link in links {
            // Tone on, or off only if we turned it on (radios we never touched stay as-is).
            let toneAction = toneOn || toneLinks.contains(link.index)
            switch link.leg {
            case .both where link.txHold:
                // One VFO for both legs: the downlink mode, and the tone on the main VFO.
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
                if toneAction {
                    let frames = CATCodec.ft847Tone(on: toneOn, toneHz: toneHz, main: true)
                    for f in frames { await sendRaw(link, f) }
                    noteTone(link, on: toneOn, sent: !frames.isEmpty, hz: toneHz)
                }
            case .both where link.split:
                await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
                if toneAction {
                    noteTone(link, on: toneOn, sent: await sendSplitTone(link, on: toneOn, toneHz: toneHz), hz: toneHz)
                }
            case .both where link.rxOnlyLayout:
                // Receive-only transponder: no uplink mode or tone; only turn off a tone we set.
                if toneLinks.contains(link.index) {
                    noteTone(link, on: false, sent: await sendTone(link, on: false, toneHz: 0), hz: 0)
                }
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
            case .both:
                // Uplink first (mode + uplink CTCSS on the MAIN band), downlink last —
                // so a full-duplex CI-V rig is left band-selected on the DOWNLINK, the
                // way CardSat does it. Otherwise the rig stays parked on MAIN.
                await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
                if toneAction {
                    noteTone(link, on: toneOn, sent: await sendTone(link, on: toneOn, toneHz: toneHz), hz: toneHz)
                }
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
            case .downlink:
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
            case .uplink:
                await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
                if toneAction {
                    noteTone(link, on: toneOn, sent: await sendTone(link, on: toneOn, toneHz: toneHz), hz: toneHz)
                }
            }
        }
    }

    /// Record (and log) an uplink tone change on a link.
    private func noteTone(_ link: LiveLink, on: Bool, sent: Bool, hz: Double) {
        guard sent else { return }
        if on { toneLinks.insert(link.index) } else { toneLinks.remove(link.index) }
        ODLog.shared.log("uplink CTCSS \(on ? String(format: "%.1f Hz ON", hz) : "OFF") → \(link.spec.name)", category: "cat")
    }

    /// Put the downlink band on MAIN for radios with the fixed Main=RX/Sub=TX satellite
    /// layout (IC-9100/9700). These rigs have NO command to assign a band to MAIN/SUB
    /// directly; the only lever is exchanging MAIN and SUB (`07 B0`). So we read MAIN's
    /// current frequency and, if its band differs from the downlink's, exchange — exactly
    /// as OscarWatch's RigSatModeHelper.NeedsMainSubBandSwap + ExchangeVfos. This is what
    /// makes a cross-band change like AO-7 Mode B (2 m downlink / 70 cm uplink, the reverse
    /// of RS-44) actually land the downlink on the VFO the operator hears. Auto for
    /// canAssignBand rigs; other rigs are unaffected.
    private func applyBandAssignment(tp: TransponderRecord) async {
        for link in links where link.spec.canAssignBand && link.leg == .both && !link.split && !link.rxOnlyLayout {
            let dlBand = CATCodec.civBandCode(UInt64(max(0, tp.downlinkCenter)))
            guard dlBand != 0 else { continue }
            // MAIN carries the downlink on these rigs (mainCarriesUplink == false), so
            // readLegFreq(.downlink) selects MAIN (07 D0) and reads its frequency.
            guard let mainHz = await readLegFreq(link, leg: .downlink) else {
                ODLog.shared.log("band assign \(link.spec.name): MAIN read failed — leaving bands as-is", category: "cat")
                continue
            }
            let mainBand = CATCodec.civBandCode(mainHz)
            if mainBand != 0, mainBand != dlBand {
                await sendRaw(link, CATCodec.civExchangeMainSub(addr: civAddr(link)))
                await pace(120)
                ODLog.shared.log("band assign \(link.spec.name): MAIN was \(mainHz) (band 0x\(String(mainBand, radix: 16))), downlink needs band 0x\(String(dlBand, radix: 16)) — exchanged MAIN/SUB", category: "cat")
            } else {
                ODLog.shared.log("band assign \(link.spec.name): MAIN=\(mainHz) already on downlink band 0x\(String(dlBand, radix: 16)) — no swap", category: "cat")
            }
        }
    }

    /// Log a "can't tune" reason once, only when it changes (empty clears it).
    private func bailLog(_ reason: String) {
        guard reason != lastTickBail else { return }
        lastTickBail = reason
        if !reason.isEmpty { ODLog.shared.log("Doppler idle: \(reason)", category: "cat") }
    }

    // MARK: Doppler loop

    private func startLoop() {
        timer?.cancel()
        lastSentRx = 0; lastSentTx = 0; lastEngageKey = ""; uplinkDeferTicks = 0
        lastTickRxReal = 0; lastTickTime = .distantPast
        // A GCD timer on the main queue — reliable here, unlike a MainActor
        // `while { await Task.sleep }` loop, which can peg the main thread and
        // freeze the UI on this device. The overlap guard skips a tick if the
        // previous one (BLE writes/reads) hasn't finished.
        let ms = config.effectiveUpdateMs     // soft-floored for slow serial links
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        t.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTicking else { return }
                // Slot-gated (FT4): the periodic loop is suppressed; frequency is stepped
                // at slot boundaries via stepDopplerNow() instead — but only while CAT is
                // still on the transponder the hold began on.
                if self.dopplerHeld() { return }
                self.isTicking = true
                await self.tick()
                self.isTicking = false
            }
        }
        t.resume()
        timer = t
    }

    /// Perform one Doppler update immediately, regardless of `holdDoppler`. Used by an
    /// active FT4 session to step the dial once per slot boundary (between the RX and TX
    /// slots) so it never retunes mid-slot. Overlap-guarded like the periodic tick, so
    /// when the hold doesn't apply (CAT on another transponder, loop running) it's just
    /// one extra tick.
    func stepDopplerNow() async {
        guard connected, !isTicking else { return }
        isTicking = true
        await tick()
        isTicking = false
    }

    /// One tuning cycle: compute corrected dials and push changed frequencies.
    func tick() async {
        // Log *why* the loop can't tune (once, when the reason changes) — otherwise a
        // "connected but nothing moves" report is undiagnosable from the log.
        guard connected else { return }
        resolveEngagement()
        guard config.tuning.trackDoppler else { return bailLog("Track Doppler is off") }
        guard let store, let sat = trackedSatellite else { return bailLog("no satellite selected") }
        guard let tp = transponder(for: sat) else { return bailLog("no transponder for \(sat.name) — select one on the Home card") }
        if sat.id == store.selectedSatellite?.id { engagedTpID = tp.id }
        bailLog("")   // clear: we can tune
        let observer = store.preferences.observer
        // Receiver modes from the SatNOGS modulation (SSTV/AFSK/GMSK… → FM, BPSK → USB),
        // with the uplink taken from SatNOGS's uplink_mode when it has one.
        var dlMode = RigMode.downlink(for: tp)
        var ulMode = RigMode.uplink(for: tp, downlink: dlMode)
        // Operator-chosen CW on a linear transponder: both sideband legs go to CW. The dial
        // then reads the carrier itself, so the uplink maps 1:1 through the transponder and
        // your own signal returns at your CW pitch. A digital client holding the DATA
        // sub-mode on this transponder (FT4) keeps SSB.
        if config.tuning.linearCW, tp.isLinear, !useDataModeForDigital {
            if dlMode == .usb || dlMode == .lsb { dlMode = .cw }
            if ulMode == .usb || ulMode == .lsb { ulMode = .cw }
        }
        let isFM = dlMode.isFM
        var deadband = Int64(isFM ? config.tuning.fmDeadbandHz : config.tuning.linearDeadbandHz)   // adapted near TCA (D2)
        // Voice FM, SSTV and 1200-baud packet birds are narrow-band, so command FM-N on
        // them (the rig picks its narrow FM filter). 9600-baud data needs wide FM and is
        // left alone. Settable; falls back to plain FM on rigs without a CAT narrow-FM
        // filter byte. Doesn't touch modes the DB already marks narrow.
        if config.tuning.narrowFM {
            if dlMode == .fm, RigMode.narrowFMSuitable(tp.mode, baud: tp.baud) { dlMode = .fmn }
            if ulMode == .fm, RigMode.narrowFMSuitable(tp.uplinkMode ?? tp.mode, baud: tp.baud) { ulMode = .fmn }
        }

        // Re-apply mode + step (and tone) whenever the satellite, transponder, mode or
        // uplink tone changes — the frequency band changes with them.
        let tone = SatelliteTones.resolve(norad: sat.id, uplinkHz: tp.uplinkCenter, tuning: config.tuning)
        // A data-mode request made before any transponder was known adopts this one.
        for (client, satTp) in dataModeClients where satTp.isEmpty { dataModeClients[client] = "\(sat.id)|\(tp.id)" }
        let key = "\(sat.id)|\(tp.id)|\(dlMode.rawValue)|\(ulMode.rawValue)|\(useDataModeForDigital)|\(tone.hz)"
        if key != lastEngageKey {
            // A passband trim belongs to one bird/transponder: reset it when that changes
            // (e.g. automatic switching) so an RS-44 trim doesn't follow onto the next one.
            let satTp = "\(sat.id)|\(tp.id)"
            if satTp != lastEngageSatTp {
                if !lastEngageSatTp.isEmpty { config.tuning.passbandOffsetHz = 0 }
                lastEngageSatTp = satTp
            }
            lastEngageKey = key
            lastSentRx = 0; lastSentTx = 0; uplinkDeferTicks = 0
            rigctldCurrentVFO.removeAll()     // re-select the VFO once after an engage
            ODLog.shared.log("engage \(sat.name)/\(tp.id): dl=\(dlMode.rawValue) ul=\(ulMode.rawValue) \(isFM ? "FM" : "linear") tone=\(tone.hz > 0 ? String(format: "%.1f Hz", tone.hz) : "off") (\(tone.source.rawValue))", category: "cat")
            await reconcileLayout(tp: tp)
            await applyBandAssignment(tp: tp)
            await alignSplitBand(tp: tp)
            await applyModes(dlMode: dlMode, ulMode: ulMode, isFM: ulMode.isFM, toneHz: tone.hz)
        }
        // Keep the trim inside the passband (follow mode can otherwise walk it off).
        if tp.isLinear, tp.bandwidth > 0 {
            clampPassband(tp)
        } else if atPassbandEdge {
            atPassbandEdge = false
        }

        // One True Rule: read the followed leg and fold an operator dial move into
        // the passband offset. The followed leg then LEADS — we don't re-command it on
        // the same tick (mark its last-sent as the observed value), so we don't fight
        // the operator's dial; Doppler resumes on it next tick. The other leg is always
        // re-commanded from the updated offset below, so following never starves tuning.
        // The live tune mode decides whether (and which leg) the rule follows.
        let tuneMode = config.tuning.tuneMode
        if config.tuning.followActive {
            let followLeg = config.tuning.effectiveFollowLeg
            let last = (followLeg == .downlink) ? lastSentRx : lastSentTx
            if last != 0, let fl = followLink(for: followLeg), !(fl.txHold && pttKeyed),
               let obs = await readLegFreq(fl, leg: followLeg) {
                let obsHz = Int64(obs)
                let delta = obsHz - last
                let thresh = max(Int64(30), deadband)
                // Band-plausibility guard: only fold a read that's on the SAME band we last
                // commanded for this leg (a wrong-VFO or garbled reply on a cross-band rig
                // would otherwise corrupt the passband offset). Replaces the old 1 MHz cap.
                if abs(delta) >= thresh, sameBand(obsHz, last) {
                    let d = Double(delta)
                    config.tuning.passbandOffsetHz += (followLeg == .downlink) ? d : (tp.invert ? -d : d)
                    if followLeg == .downlink { lastSentRx = obsHz } else { lastSentTx = obsHz }
                    // Pause Doppler on the followed leg for a short settle window so we don't
                    // fight the operator while they're still turning (uplink gets a touch longer).
                    let windowMs = followLeg == .uplink ? config.tuning.followUplinkResumeMs : config.tuning.followSettleMs
                    followSettleUntil = Date().addingTimeInterval(Double(max(0, windowMs)) / 1000.0)
                    if tp.isLinear, tp.bandwidth > 0 { clampPassband(tp) }
                }
            }
        }

        // Predictive lead + Doppler using the current (possibly just-updated) offset.
        // Aim the commanded frequency at the MIDDLE of the upcoming update interval
        // (leadMs + updateMs/2), not "now". Otherwise the dial always trails the true
        // Doppler by up to a half-interval — worst near TCA (high Doppler rate), where
        // it smears FT4 within a slot. Centering halves the peak tracking error for free.
        // D1 — TCA lead taper: a fixed forward lead over-predicts near TCA, where the
        // range rate ≈ 0 but its slope (Doppler curvature) is steepest, so aiming ahead
        // pushes the dial PAST the true value right at closest approach. Scale the lead by
        // |range-rate|/0.35 km/s so it fades to ~0 at TCA and is full on the fast legs. A
        // cheap probe at "now" gives the current range rate (SGP4 is fast).
        let baseLeadSec = (Double(config.tuning.leadMs) + Double(config.effectiveUpdateMs) * 0.5) / 1000.0
        let rrNow = (try? OrbitPredictor.look(sat, observer: observer, at: Date()))?.rangeRateKmS ?? 0
        let leadTaper = min(1.0, abs(rrNow) / 0.35)
        var leadSec = baseLeadSec * leadTaper
        // Post-TCA receding-leg assist (from the OscarWatch cross-audit): on the outbound
        // half of the pass (range rate > 0, satellite departing) the dial tends to lag as
        // Doppler falls away, so add a modest extra lead (up to +25%), ramped in with the
        // receding rate. The inbound/approaching leg and the TCA region are left unchanged.
        if rrNow > 0 { leadSec *= 1.0 + 0.25 * min(1.0, rrNow / 1.5) }
        let when = Date().addingTimeInterval(leadSec)
        guard let look = try? OrbitPredictor.look(sat, observer: observer, at: when) else { return }
        let offset = tp.isLinear ? Int64(config.tuning.passbandOffsetHz.rounded()) : 0
        let downlink = tp.downlinkCenter + offset
        let uplink: Int64 = {
            let u = tp.uplinkCenter
            guard tp.isLinear, u > 0 else { return u }
            return tp.invert ? u - offset : u + offset
        }()
        let cal = store.downlinkCalibrationHz(for: sat.id, transponder: tp.id, invert: tp.invert) + Double(config.tuning.calDownlinkHz)
        let corrected = OrbitPredictor.dopplerFrequencies(downlinkHz: downlink, uplinkHz: uplink,
                                                          rangeRateKmS: look.rangeRateKmS,
                                                          downlinkCalibrationHz: cal,
                                                          uplinkCalibrationHz: Double(config.tuning.calUplinkHz))
        // Transverter LO: the rig tunes (real − LO).
        let rxReal = corrected.rx, txReal = corrected.tx
        downlinkDialHz = rxReal; uplinkDialHz = txReal
        let rxRig = rxReal - config.tuning.xvtrDownlinkHz
        let txRig = txReal - config.tuning.xvtrUplinkHz
        lastTargetTx = uplink > 0 ? txRig : 0
        lastTargetRx = rxRig

        // D2 — adaptive deadband: when the downlink Doppler is slewing fast (near TCA),
        // shrink the deadband so the dial updates more often exactly when it matters;
        // relax it back to the configured value away from TCA to spare the CI-V/BLE bus.
        // Slew (Hz/s) = the per-tick change in the commanded downlink dial.
        let nowTick = Date()
        let dt = max(0.02, nowTick.timeIntervalSince(lastTickTime))
        let slewHzPerSec = lastTickRxReal == 0 ? 0 : abs(Double(rxReal - lastTickRxReal)) / dt
        lastTickRxReal = rxReal; lastTickTime = nowTick
        // Ramp from the base deadband (slew ≤ 15 Hz/s) down to a floor (slew ≥ 35 Hz/s).
        // The floor is base/2 but never below 25 Hz and never ABOVE the base (so the tight
        // linear deadband is left alone; the coarse FM deadband is the one that benefits).
        let baseDb = Double(deadband)
        let floorDb = min(baseDb, max(25.0, baseDb / 2.0))
        let ramp = min(1.0, max(0.0, (slewHzPerSec - 15.0) / 20.0))
        deadband = Int64(baseDb - (baseDb - floorDb) * ramp)

        // Throttled diagnostics (every ~5 s): confirms the loop is driving and shows the
        // target dials, so a "connected but nothing moves" report is answerable.
        if Date().timeIntervalSince(lastFreqLogAt) >= 5 {
            lastFreqLogAt = Date()
            ODLog.shared.log("tune rx=\(rxRig) tx=\(txRig) dl=\(dlMode.rawValue) ul=\(ulMode.rawValue)", category: "cat")
        }

        // During the settle window, hold Doppler off the followed leg (see follow block).
        let followLeg = config.tuning.effectiveFollowLeg
        let settling = config.tuning.followActive && Date() < followSettleUntil
        let settleDown = settling && followLeg == .downlink
        let settleUp = settling && followLeg == .uplink
        // Live tune mode: legs it leaves to the operator get no Doppler writes at all.
        let driveDown = tuneMode.drivesDownlink, driveUp = tuneMode.drivesUplink
        for link in links {
            switch link.leg {
            case .both where link.txHold:
                // FT-847 same-band hold: the main VFO tracks the downlink; the uplink is
                // written only around a transmission (setPTT). Leave it alone while keyed.
                if driveDown, !pttKeyed, !settleDown, abs(rxRig - lastSentRx) >= deadband {
                    await sendFreq(link, leg: .downlink, hz: rxRig, mode: dlMode); lastSentRx = rxRig
                }
            case .both:
                // Downlink first (CardSat driveDownlink), then uplink.
                let followUplink = config.tuning.followActive && followLeg == .uplink
                let dlMoved = driveDown && abs(rxRig - lastSentRx) >= deadband
                if dlMoved, !settleDown { await sendFreq(link, leg: .downlink, hz: rxRig, mode: dlMode); lastSentRx = rxRig }
                // Split rigs that swap VFOs to reach VFO B move the receiver on every uplink
                // write, so give their uplink a wider deadband (never narrower than normal).
                let ulDeadband = (link.split && splitNeedsSwap(link))
                    ? max(deadband, Int64(config.tuning.splitUplinkDeadbandHz)) : deadband
                if driveUp, uplink > 0, !settleUp, abs(txRig - lastSentTx) >= ulDeadband {
                    if followUplink {
                        // OTR-uplink: write the uplink immediately (no defer) and LEAVE
                        // band access on the uplink, so the followed-uplink read stays
                        // valid and the operator's uplink VFO isn't yanked back to RX
                        // each tick (CardSat driveUplinkOtr → rigSelectUplink).
                        if await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode) { lastSentTx = txRig }
                    } else if dlMoved && uplinkDeferTicks == 0 {
                        // Defer the uplink one tick after a downlink move so the shared
                        // bus isn't congested (CardSat driveUplinkDeferred).
                        uplinkDeferTicks = 1
                    } else {
                        uplinkDeferTicks = 0
                        // A split write held during transmit isn't recorded as sent, so it
                        // goes out on the first tick after the over.
                        if await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode) { lastSentTx = txRig }
                        // Return band access to the downlink so the rig stays on RX
                        // (matches CardSat's driveUplink → rigSelectDownlink).
                        await reselectDownlink(link)
                    }
                }
            case .downlink:
                if driveDown, !settleDown, abs(rxRig - lastSentRx) >= deadband { await sendFreq(link, leg: .downlink, hz: rxRig, mode: dlMode); lastSentRx = rxRig }
            case .uplink:
                if driveUp, uplink > 0, !settleUp, abs(txRig - lastSentTx) >= deadband { await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode); lastSentTx = txRig }
            }
        }
        // Feed-forward the current downlink residual (commanded target vs last-sent dial)
        // to the SSTV decoder so it can correct a mid-image Doppler step continuously. Zero
        // unless a downlink is actually being tracked; cleared on disconnect. An operator
        // without CAT never sets this, so SSTV decoding is unaffected.
        let hasDownlink = driveDown && links.contains { $0.leg == .both || $0.leg == .downlink }
        SSTVDopplerFeed.set(hasDownlink ? Double(rxRig - lastSentRx) : 0)
    }

    /// Keep the passband trim inside the transponder and publish whether it's pinned at
    /// an edge (follow mode or tilt tuning can otherwise walk it off).
    private func clampPassband(_ tp: TransponderRecord) {
        let half = Double(tp.bandwidth) / 2
        let clamped = min(half, max(-half, config.tuning.passbandOffsetHz))
        if clamped != config.tuning.passbandOffsetHz { config.tuning.passbandOffsetHz = clamped }
        let edge = abs(clamped) >= half - 1
        if edge != atPassbandEdge { atPassbandEdge = edge }
    }

    // MARK: Per-pass layout (OscarWatch audit H1–H4)

    /// Choose each single radio's layout for the current transponder. MAIN/SUB satellite
    /// rigs can't put both legs on one band, so a same-band bird (dl/ul within 10 MHz,
    /// e.g. ISS APRS) runs in split VFO for that pass and goes back to satellite mode on
    /// the next cross-band bird. The FT-847 has no CAT split, so it gets the transmit
    /// hold instead: satellite mode off, main VFO on the downlink, uplink only when keyed.
    private func reconcileLayout(tp: TransponderRecord) async {
        let sameBand = tp.uplinkCenter > 0 && abs(tp.uplinkCenter - tp.downlinkCenter) < 10_000_000
        for i in links.indices where links[i].leg == .both && links[i].slot.transport != .rigctld {
            let spec = links[i].spec
            let forced = !config.twoRadios && links[i].slot.splitVFO && spec.supportsSplit
            let wantSplit = forced || (sameBand && spec.fullDuplex && spec.supportsSplit)
            if wantSplit != links[i].split {
                if wantSplit {
                    links[i].split = true
                    links[i].directVFOB = await engageSplit(links[i])
                } else {
                    await leaveSplit(links[i])
                    links[i].split = false
                }
                if i < statuses.count { statuses[i].split = links[i].split }
                ODLog.shared.log("layout \(spec.name): \(wantSplit ? "split VFO" : "satellite (MAIN/SUB)") for \(sameBand ? "same-band" : "cross-band") transponder", category: "cat")
            }
            // Receive-only transponder (beacon/telemetry: no uplink) on an Icom sat rig:
            // satellite mode off and the downlink on MAIN, like a plain receiver; back to
            // satellite mode on the next two-way transponder (CardSat behavior).
            let wantRxOnly = tp.uplinkCenter <= 0 && spec.family == .civ && spec.hasSatMode && !links[i].split
            if wantRxOnly != links[i].rxOnlyLayout {
                await setRxOnlyLayout(i, on: wantRxOnly, tp: tp)
            }
            let wantHold = sameBand && spec.id == "FT-847"
            if wantHold != links[i].txHold {
                if wantHold {
                    await sendRaw(links[i], CATCodec.ft847SatModeOff); await pace(60)
                    await sendRaw(links[i], CATCodec.ft847Simplex); await pace(60)
                } else {
                    await sendRaw(links[i], CATCodec.ft847SatModeOn); await pace(60)
                }
                links[i].txHold = wantHold
                ODLog.shared.log("layout FT-847: \(wantHold ? "same-band transmit hold (SAT off)" : "satellite mode")", category: "cat")
            }
        }
    }

    /// Enter or leave the receive-only layout on a full-duplex Icom. Entering: satellite
    /// mode off, MAIN selected, and MAIN/SUB exchanged (`07 B0`) if MAIN isn't on the
    /// downlink band. Leaving: satellite mode back on where OrbitDeck commands it — the
    /// band assignment that follows puts the downlink on the right VFO again.
    private func setRxOnlyLayout(_ i: Int, on: Bool, tp: TransponderRecord) async {
        let link = links[i]
        let addr = civAddr(link)
        if on {
            if let off = CATCodec.civSatMode(link.spec, addr: addr, on: false) {
                await sendRaw(link, off); await pace(60)
                satModeLinks.remove(link.index)
            }
            links[i].rxOnlyLayout = true
            if let main = CATCodec.civSelect(link.spec, addr: addr, sub: false) { await sendRaw(link, main) }
            let target = CATCodec.civBandCode(UInt64(max(0, tp.downlinkCenter)))
            if target != 0 {
                _ = await readReply(link, maxWait: 0.02)
                await sendRaw(link, CATCodec.civReadFreq(addr: addr))
                if let hz = CATCodec.civParseFreq(await readReply(link, maxWait: 0.5), addr: addr) {
                    let band = CATCodec.civBandCode(hz)
                    if band != 0, band != target {
                        await sendRaw(link, CATCodec.civExchangeMainSub(addr: addr)); await pace(120)
                        if let main = CATCodec.civSelect(link.spec, addr: addr, sub: false) { await sendRaw(link, main) }
                        ODLog.shared.log("receive-only \(link.spec.name): MAIN was on band 0x\(String(band, radix: 16)) — exchanged MAIN/SUB", category: "cat")
                    }
                }
            }
        } else {
            links[i].rxOnlyLayout = false
            if config.tuning.satMode || link.spec.canAssignBand,
               let sat = CATCodec.civSatMode(link.spec, addr: addr, on: true) {
                await sendRaw(link, sat); await pace(60)
                satModeLinks.insert(link.index)
            }
        }
        ODLog.shared.log("layout \(link.spec.name): \(on ? "receive-only transponder — satellite mode off, downlink on MAIN" : "two-way transponder — satellite layout restored")", category: "cat")
    }

    /// Back from split to the radio's satellite layout (split off first: satellite
    /// mode-on is ignored while split is on).
    private func leaveSplit(_ link: LiveLink) async {
        let addr = civAddr(link)
        switch link.spec.family {
        case .civ:
            await sendRaw(link, CATCodec.civSplit(addr: addr, on: false))
            if config.tuning.satMode || link.spec.canAssignBand,
               let on = CATCodec.civSatMode(link.spec, addr: addr, on: true) {
                await sendRaw(link, on); await pace(60)
                satModeLinks.insert(link.index)
            }
        case .kenwoodBase:
            for f in CATCodec.kwSplit(on: false, frft: link.spec.kenwoodSplitFRFT) { await sendRaw(link, f) }
            if kenwoodSat(link.spec) { for f in CATCodec.kwSatEntry() { await sendRaw(link, f); await pace(60) } }
        default:
            break
        }
    }

    /// IC-9100/9700 split runs on MAIN, so MAIN must carry the transponder's band:
    /// with split off, read MAIN and exchange MAIN/SUB (07 B0) if it's on the other band,
    /// then turn split back on (the exchange is ignored while split is on).
    private func alignSplitBand(tp: TransponderRecord) async {
        let target = CATCodec.civBandCode(UInt64(max(0, tp.downlinkCenter)))
        guard target != 0 else { return }
        for link in links where link.split && link.spec.canAssignBand {
            let addr = civAddr(link)
            await sendRaw(link, CATCodec.civSplit(addr: addr, on: false))
            if let main = CATCodec.civSelect(link.spec, addr: addr, sub: false) { await sendRaw(link, main) }
            await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
            _ = await readReply(link, maxWait: 0.02)
            await sendRaw(link, CATCodec.civReadFreq(addr: addr))
            let data = await readReply(link, maxWait: 0.5)
            if let hz = CATCodec.civParseFreq(data, addr: addr) {
                let band = CATCodec.civBandCode(hz)
                if band != 0, band != target {
                    await sendRaw(link, CATCodec.civExchangeMainSub(addr: addr)); await pace(120)
                    if let main = CATCodec.civSelect(link.spec, addr: addr, sub: false) { await sendRaw(link, main) }
                    await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
                    ODLog.shared.log("split \(link.spec.name): MAIN was on band 0x\(String(band, radix: 16)) — exchanged MAIN/SUB", category: "cat")
                }
            }
            await sendRaw(link, CATCodec.civSplit(addr: addr, on: true))
        }
    }

    // MARK: Read-back (One True Rule)

    private func followLink(for leg: RigRole) -> LiveLink? {
        links.first { $0.leg == leg || $0.leg == .both }
    }

    /// Read the current frequency (rig units) of a leg, or nil if unavailable.
    private func readLegFreq(_ link: LiveLink, leg: RigRole) async -> UInt64? {
        guard link.spec.canReadFreq else { return nil }
        if link.split { return await readSplitLegFreq(link, leg: leg) }
        switch link.spec.family {
        case .civ:
            if let sel = bandSelect(link, leg: leg) {
                await sendRaw(link, sel)
            }
            await sendRaw(link, CATCodec.civReadFreq(addr: civAddr(link)))
            let data = await readReply(link, maxWait: 0.5)
            return CATCodec.civParseFreq(data, addr: civAddr(link))
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736, .yaesuFT100:
            _ = await readReply(link, maxWait: 0.02)   // drop stale set-command replies
            await sendRaw(link, CATCodec.yaesuReadFreq(link.spec, vfo: yaesuVFO(link, leg: leg)))
            let data = await readReply(link, maxWait: 0.5)
            return CATCodec.yaesuParseFreq(link.spec, data)
        case .kenwoodBase:
            // Full-duplex Kenwood: uplink is VFO B — read/parse FB, not FA (follow-uplink).
            let vfoB = satRig(link) && leg == .uplink
            await sendRaw(link, CATCodec.kwReadFreq(vfoB: vfoB))
            let data = await readReply(link, maxWait: 0.5)
            return CATCodec.kwParseFreq(data, vfoB: vfoB)
        case .kenwoodHandheld:
            await sendRaw(link, CATCodec.khtReadFreq())
            let data = await readReply(link, maxWait: 0.5)
            return CATCodec.khtParseFreq(data)
        case .rigctld:
            // VFO mode reads the leg's VFO; the split method reads the TX VFO with `i`.
            await rigctldSend(link, "f", leg: leg)
            let data = await readReply(link, maxWait: 0.5)
            return CATCodec.rigctldParseFreq(data)
        }
    }

    // MARK: Frame routing

    private func civAddr(_ link: LiveLink) -> UInt8 {
        link.slot.civAddrOverride > 0 ? UInt8(link.slot.civAddrOverride) : link.spec.civAddr
    }

    /// Two frequencies (rig units) on the same amateur band — the follow-dial
    /// band-plausibility guard. Compares against the last-commanded value for the leg, so
    /// it stays self-consistent even with a transverter IF. Unknown bands never match.
    private func sameBand(_ a: Int64, _ b: Int64) -> Bool {
        func band(_ hz: Int64) -> Int {
            switch hz {
            case 1_800_000...2_000_000: return 160
            case 3_500_000...4_000_000: return 80
            case 7_000_000...7_300_000: return 40
            case 14_000_000...14_350_000: return 20
            case 21_000_000...21_450_000: return 15
            case 28_000_000...29_700_000: return 10
            case 50_000_000...54_000_000: return 6
            case 144_000_000...148_000_000: return 2
            case 220_000_000...225_000_000: return 122
            case 430_000_000...450_000_000: return 70
            case 902_000_000...928_000_000: return 33
            case 1_240_000_000...1_300_000_000: return 23
            default: return -1
            }
        }
        let ba = band(a)
        return ba != -1 && ba == band(b)
    }

    /// Whether MAIN carries the uplink for this radio. The IC-9100/9700 satellite mode is
    /// a FIXED Main=RX(downlink) / Sub=TX(uplink) layout (per OscarWatch RigSatModeHelper
    /// and Icom's SAT design), so the MAIN/SUB band exchange and band-access select must put
    /// the downlink on MAIN — regardless of the generic VFO-Type setting. Using the setting
    /// there sent RS-44's modes to the wrong VFOs (downlink came out LSB, uplink USB).
    private func mainCarriesUplink(_ spec: RadioSpec) -> Bool {
        if spec.canAssignBand { return false }     // 9100/9700: Main = downlink (RX)
        return config.tuning.mainIsUplink
    }

    /// Whether a link drives a full-duplex satellite rig as one (MAIN/SUB, SAT VFOs, VFO A/B
    /// legs). A sat rig used as one leg of a two-radio station is a plain single-VFO radio on
    /// whatever band its front panel has selected: no band select, satellite mode or
    /// band exchange, so every `fullDuplex` path must go through this.
    private func satRig(_ link: LiveLink) -> Bool { link.spec.fullDuplex && link.leg == .both }

    /// CI-V MAIN/SUB band-select frame for a leg on a sat-rig link, or nil when the link
    /// isn't driven as a sat rig (mono leg) or has no band select.
    private func bandSelect(_ link: LiveLink, leg: RigRole) -> [UInt8]? {
        guard link.spec.family == .civ, satRig(link), !link.split else { return nil }
        // Receive-only transponder: satellite mode is off and the downlink is on MAIN.
        let sub = link.rxOnlyLayout ? (leg == .uplink) : useSub(for: leg, spec: link.spec)
        return CATCodec.civSelect(link.spec, addr: civAddr(link), sub: sub)
    }

    /// For a full-duplex CI-V rig, which VFO (SUB?) a given leg is on.
    private func useSub(for leg: RigRole, spec: RadioSpec) -> Bool {
        let mainIsUplink = mainCarriesUplink(spec)
        switch leg {
        case .downlink: return mainIsUplink        // downlink on SUB when MAIN is uplink
        case .uplink:   return !mainIsUplink
        case .both:     return true
        }
    }

    private func yaesuVFO(_ link: LiveLink, leg: RigRole) -> YaesuVFO {
        // Full-duplex Yaesu (FT-847 SAT VFOs, FT-736R full-duplex RX/TX): map the leg to a
        // VFO — but only when it's driven as one full-duplex radio (leg .both), which is
        // when SAT / full duplex is switched on at engage. As a single leg it stays on the
        // plain main VFO (0x01/0x07); the SAT opcodes would tune a VFO that isn't in use.
        guard link.leg == .both, link.spec.fullDuplex, !link.txHold,
              link.spec.family == .yaesuBinary || link.spec.family == .yaesuFT736 else { return .plain }
        return leg == .uplink ? .satTX : .satRX
    }

    /// Leave a full-duplex CI-V rig band-selected on the downlink (SUB) so it stays
    /// on receive after an uplink write. No-op for rigs without CI-V band access.
    private func reselectDownlink(_ link: LiveLink) async {
        guard let sel = bandSelect(link, leg: .downlink) else { return }
        await sendRaw(link, sel)
    }

    // MARK: Split VFO routing (VFO A = downlink/receive, VFO B = uplink/transmit)

    /// Whether reaching VFO B on this rig means swapping VFOs (no direct VFO B
    /// command), which briefly moves the receiver and must not happen mid-transmission.
    private func splitNeedsSwap(_ link: LiveLink) -> Bool {
        switch link.spec.family {
        case .civ:                      return !link.directVFOB
        case .yaesuBinary, .yaesuFT100: return true
        default:                        return false     // Kenwood FA/FB address each VFO directly
        }
    }

    /// Whether the radio is transmitting right now, where we can ask it (CI-V `1C 00`).
    /// Catches a hand-keyed PTT / TNC, which `pttKeyed` can't see. nil = can't tell.
    private func radioTransmitting(_ link: LiveLink) async -> Bool? {
        guard link.spec.family == .civ, link.spec.civHasPTT else { return nil }
        let addr = civAddr(link)
        _ = await readReply(link, maxWait: 0.02)
        await sendRaw(link, CATCodec.civReadTX(addr: addr))
        let reply = await readReply(link, maxWait: 0.3)
        guard let body = CATCodec.civReply(reply, addr: addr, cmd: 0x1C), body.count >= 2, body[0] == 0x00 else { return nil }
        return body[1] == 0x01
    }

    /// Whether an uplink (VFO B) write must wait: OrbitDeck has the radio keyed, or
    /// a swap-only rig reports it's transmitting.
    private func holdUplinkForTX(_ link: LiveLink) async -> Bool {
        guard splitNeedsSwap(link) else { return false }
        if pttKeyed { return true }
        return await radioTransmitting(link) == true
    }

    /// Returns false when the write was held (uplink during transmit).
    @discardableResult
    private func sendSplitFreq(_ link: LiveLink, leg: RigRole, hz: Int64) async -> Bool {
        let u = UInt64(hz)
        let addr = civAddr(link)
        if leg == .uplink, await holdUplinkForTX(link) {
            ODLog.shared.log("split: uplink write held while transmitting (\(link.spec.name) swaps VFOs)", category: "cat")
            return false
        }
        switch link.spec.family {
        case .civ:
            if leg == .downlink {
                await sendRaw(link, CATCodec.civSetFreq(link.spec, addr: addr, hz: u))       // VFO A is selected
            } else if link.directVFOB {
                await sendRaw(link, CATCodec.civSetUnselectedFreq(link.spec, addr: addr, hz: u))
            } else {
                await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: true))
                await sendRaw(link, CATCodec.civSetFreq(link.spec, addr: addr, hz: u))
                await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
            }
        case .yaesuBinary:
            // Hamlib waits ~50 ms for the VFO swap to take on these rigs.
            if leg == .uplink { await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50) }
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: u, vfo: .plain))
            if leg == .uplink { await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50) }
        case .yaesuFT100:
            if leg == .uplink { await sendRaw(link, CATCodec.ft100SelectVFO(b: true)) }
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: u, vfo: .plain))
            if leg == .uplink { await sendRaw(link, CATCodec.ft100SelectVFO(b: false)) }
        case .kenwoodBase:
            await sendRaw(link, CATCodec.kwSetFreq(vfo: leg == .uplink ? "FB" : "FA", hz: u))
        default:
            break
        }
        return true
    }

    private func sendSplitMode(_ link: LiveLink, mode: RigMode, leg: RigRole) async {
        let addr = civAddr(link)
        let wantData = useDataModeForDigital && dataModeSuits(mode) && isDataModeCapable(link.spec)
        switch link.spec.family {
        case .civ:
            if leg == .downlink {
                for f in civModeFrames(link, mode: mode, leg: leg) { await sendRaw(link, f) }    // VFO A is selected
            } else if link.directVFOB {
                // 0x26 carries the data flag itself, so it always says data on/off.
                await sendRaw(link, CATCodec.civSetUnselectedMode(link.spec, addr: addr, mode: mode, data: wantData))
            } else {
                await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: true))
                for f in civModeFrames(link, mode: mode, leg: leg) { await sendRaw(link, f) }
                await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
            }
        case .yaesuBinary:
            if leg == .uplink { await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50) }
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: .plain, data: wantData))
            if leg == .uplink { await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50) }
        case .yaesuFT100:
            if leg == .uplink { await sendRaw(link, CATCodec.ft100SelectVFO(b: true)) }
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: .plain))
            if leg == .uplink { await sendRaw(link, CATCodec.ft100SelectVFO(b: false)) }
        case .kenwoodBase:
            // MD has no VFO field: make B active for the uplink mode, then go back to A.
            // FR (and possibly FN) can cancel split, so re-assert it afterward (Hamlib
            // always appends FT1 after FR for this reason).
            let frft = link.spec.kenwoodSplitFRFT
            if leg == .uplink { await sendRaw(link, CATCodec.kwActiveVFO(b: true, frft: frft)) }
            for f in CATCodec.kwSetMode(link.spec, mode) { await sendRaw(link, f) }
            if leg == .uplink {
                for f in CATCodec.kwSplit(on: true, frft: frft) { await sendRaw(link, f) }
            }
        default:
            break
        }
    }

    /// Uplink CTCSS on a split rig. Icom tone settings are per VFO, so set it on
    /// VFO B (the transmit VFO) and A alike; Kenwood's TN/TO are global. Returns whether
    /// any tone frame was sent.
    @discardableResult
    private func sendSplitTone(_ link: LiveLink, on: Bool, toneHz: Double) async -> Bool {
        switch link.spec.family {
        case .civ:
            let addr = civAddr(link)
            await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: true))
            await sendTone(link, on: on, toneHz: toneHz)
            await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false))
            return await sendTone(link, on: on, toneHz: toneHz)
        case .yaesuBinary:
            // Tone is per VFO here too; B is the transmit VFO.
            await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50)
            await sendTone(link, on: on, toneHz: toneHz)
            await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50)
            return await sendTone(link, on: on, toneHz: toneHz)
        default:
            return await sendTone(link, on: on, toneHz: toneHz)
        }
    }

    private func readSplitLegFreq(_ link: LiveLink, leg: RigRole) async -> UInt64? {
        if leg == .uplink, await holdUplinkForTX(link) { return nil }
        switch link.spec.family {
        case .civ:
            let addr = civAddr(link)
            if leg == .uplink { await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: true)) }
            await sendRaw(link, CATCodec.civReadFreq(addr: addr))
            let data = await readReply(link, maxWait: 0.5)
            if leg == .uplink { await sendRaw(link, CATCodec.civSelectVFO(addr: addr, b: false)) }
            return CATCodec.civParseFreq(data, addr: addr)
        case .yaesuBinary:
            if leg == .uplink { await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50) }
            await sendRaw(link, CATCodec.yaesuReadFreq(link.spec, vfo: .plain))
            let data = await readReply(link, maxWait: 0.5)
            if leg == .uplink { await sendRaw(link, CATCodec.yaesuToggleVFO); await pace(50) }
            return CATCodec.yaesuParseFreq(link.spec, data)
        case .yaesuFT100:
            if leg == .uplink { await sendRaw(link, CATCodec.ft100SelectVFO(b: true)) }
            await sendRaw(link, CATCodec.yaesuReadFreq(link.spec, vfo: .plain))
            let data = await readReply(link, maxWait: 0.5)
            if leg == .uplink { await sendRaw(link, CATCodec.ft100SelectVFO(b: false)) }
            return CATCodec.yaesuParseFreq(link.spec, data)
        case .kenwoodBase:
            await sendRaw(link, CATCodec.kwReadFreq(vfoB: leg == .uplink))
            let data = await readReply(link, maxWait: 0.5)
            return CATCodec.kwParseFreq(data, vfoB: leg == .uplink)
        default:
            return nil
        }
    }

    /// Returns false only when a split uplink write was held during transmit.
    @discardableResult
    private func sendFreq(_ link: LiveLink, leg: RigRole, hz: Int64, mode: RigMode) async -> Bool {
        guard hz > 0 else { return true }
        if link.split { return await sendSplitFreq(link, leg: leg, hz: hz) }
        let u = UInt64(hz)
        switch link.spec.family {
        case .civ:
            if let sel = bandSelect(link, leg: leg) {
                await sendRaw(link, sel)
            }
            await sendRaw(link, CATCodec.civSetFreq(link.spec, addr: civAddr(link), hz: u))
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736:
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: u, vfo: yaesuVFO(link, leg: leg)))
        case .yaesuFT100:
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: u, vfo: .plain))
        case .kenwoodBase:
            // Full-duplex: VFO A = downlink, VFO B = uplink. Mono: VFO A.
            let vfo = (satRig(link) && leg == .uplink) ? "FB" : "FA"
            await sendRaw(link, CATCodec.kwSetFreq(vfo: vfo, hz: u))
        case .kenwoodHandheld:
            // TH-D74/D75 refuse off-grid writes: fine mode (SSB/CW/AM) is a 20 Hz
            // grid, FM/DATA (NFM) is 5 kHz. Round to match the step we set at engage.
            let step: UInt64 = (mode == .usb || mode == .lsb || mode == .cw || mode == .am) ? 20 : 5000
            let rounded = ((u + step / 2) / step) * step
            await sendRaw(link, CATCodec.khtSetFreq(hz: rounded))
            // A cross-band FQ can discard the tuning step (OscarWatch audit): re-apply it.
            let band = u < 300_000_000 ? 2 : (u < 1_000_000_000 ? 70 : 23)
            if band != lastKhtBand {
                if lastKhtBand != 0 { for f in CATCodec.khtStep(for: mode) { await sendRaw(link, f); await pace(20) } }
                lastKhtBand = band
            }
        case .rigctld:
            // Full-duplex single radio: VFOA/VFOB (VFO mode) or the split/TX VFO. A
            // standalone leg (two-radio station) uses the current VFO.
            await rigctldSend(link, "F", leg: leg, String(u))
        }
        return true
    }

    private func sendModeCIVorOther(_ link: LiveLink, mode: RigMode, leg: RigRole) async {
        if link.split { await sendSplitMode(link, mode: mode, leg: leg); return }
        // Whether to command the DATA sub-mode for this leg (FT4/packet/SSTV audio path):
        // USB-D/LSB-D on SSB, FM-D (Icom) / PKT (FT-817 family) / PKTFM (Hamlib) on FM.
        let wantData = useDataModeForDigital && dataModeSuits(mode) && isDataModeCapable(link.spec)
        switch link.spec.family {
        case .civ:
            if let sel = bandSelect(link, leg: leg) {
                await sendRaw(link, sel)
            }
            for f in civModeFrames(link, mode: mode, leg: leg) { await sendRaw(link, f) }
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736:
            // FT-817/818/857/897 use DIG/PKT for the data path (wantData); FT-847/736R aren't
            // data-capable so wantData is false and the base mode is sent.
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: yaesuVFO(link, leg: leg), data: wantData))
        case .yaesuFT100:
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: .plain))
        case .kenwoodBase:
            // TS-2000/790 in SATL: MD applies to the CTRL band, so select it first
            // (uplink → SUB, downlink → MAIN with TX left on SUB). Non-sat Kenwoods
            // (TS-711/811) just get MD. No clean CAT data mode either way.
            if kenwoodSat(link.spec), link.leg == .both {
                await sendRaw(link, CATCodec.kwSatControl(uplink: leg == .uplink))
                // The SA control-band change needs time to take before MD is scoped to it.
                await pace(400)
            }
            for f in CATCodec.kwSetMode(link.spec, mode) { await sendRaw(link, f) }
        case .kenwoodHandheld:
            // MD first, then the step: MD can reset the step (OscarWatch audit).
            await sendRaw(link, CATCodec.khtSetMode(mode))
            for f in CATCodec.khtStep(for: mode) { await sendRaw(link, f); await pace(20) }
        case .rigctld:
            // Hamlib PKTUSB/PKTLSB/PKTFM when the data path is wanted (works on any
            // Hamlib-supported radio that has a data mode).
            await rigctldSend(link, "M", leg: leg, CATCodec.rigctldModeArgs(mode, data: wantData))
        }
    }

    /// CI-V mode frames for the currently selected VFO/band. Digital data path: on a
    /// data-capable Icom, the base mode (bare 06 <mode>, no filter byte) then the DATA
    /// sub-mode + filter (1A 06) — the sequence OscarWatch uses on the IC-9700 in satellite
    /// mode (0x26 is rejected there). USB/LSB give USB-D/LSB-D, FM/FM-N give FM-D (narrow
    /// filter for FM-N where known). Only used while a client wants data, or once more to
    /// CLEAR a data mode we set, so other sessions keep the plain 06 <mode> [filter].
    private func civModeFrames(_ link: LiveLink, mode: RigMode, leg: RigRole) -> [[UInt8]] {
        let addr = civAddr(link)
        let legKey = "\(ObjectIdentifier(link.transport).hashValue)-\(leg.rawValue)"
        guard isDataModeCapable(link.spec), useDataModeForDigital || dataModeLegs.contains(legKey) else {
            return [CATCodec.civSetMode(link.spec, addr: addr, mode: mode)]
        }
        let on = useDataModeForDigital && dataModeSuits(mode)
        let filter: UInt8 = (mode == .fmn && link.spec.fmNarrowFilter != 0) ? link.spec.fmNarrowFilter : 0x01
        var frames = [CATCodec.civSetModeBase(addr: addr, mode: mode),
                      CATCodec.civDataMode(link.spec, addr: addr, on: on, filter: filter)]
        // Data off on FM: the bare 06 05 dropped the FM filter, so set it again (FM-N/FIL1).
        if !on, mode.isFM { frames.append(CATCodec.civSetMode(link.spec, addr: addr, mode: mode)) }
        if on { dataModeLegs.insert(legKey) } else { dataModeLegs.remove(legKey) }
        ODLog.shared.log("civ data mode (1A 06): \(link.spec.name) mode=\(mode.rawValue) data=\(on)", category: "cat")
        return frames
    }

    /// Returns whether any tone frame was sent (false for radios without CAT tone).
    @discardableResult
    private func sendTone(_ link: LiveLink, on: Bool, toneHz: Double) async -> Bool {
        let frames: [[UInt8]]
        switch link.spec.family {
        case .civ:
            frames = CATCodec.civTone(link.spec, addr: civAddr(link), on: on, toneHz: toneHz)
        case .yaesuBinary where link.spec.id == "FT-847":
            frames = CATCodec.ft847Tone(on: on, toneHz: toneHz, main: !satRig(link))   // as a leg: main VFO
        case .yaesuBinary where !link.spec.fullDuplex:
            // FT-817/818/857/897 (OscarWatch audit: SO-50 etc. need a tone on these).
            frames = CATCodec.yaesuTone(on: on, toneHz: toneHz)
        case .kenwoodBase where link.spec.isKenwoodHF && !link.spec.hasTone:
            // TS-890S/990S: TN/TO take a band parameter / different table — not driven.
            frames = []
        case .kenwoodBase:
            frames = CATCodec.kwTone(on: on, toneHz: toneHz, zeroBased: link.spec.kenwoodToneZeroBased)
        default:
            frames = []
        }
        for f in frames { await sendRaw(link, f) }
        return !frames.isEmpty
    }

    private func sendRaw(_ link: LiveLink, _ bytes: [UInt8]) async {
        if CATMonitor.shared.enabled { CATMonitor.shared.record(monitorLabel(link), tx: true, bytes, family: link.spec.family) }
        try? await link.transport.send(bytes)
        await pace(config.tuning.commandDelayMs)
    }

    /// Read whatever the radio has sent (see `CATTransport.readAvailable`), recording it
    /// in the CAT monitor when that's on.
    private func readReply(_ link: LiveLink, maxWait: TimeInterval) async -> [UInt8] {
        let data = await link.transport.readAvailable(maxWait: maxWait)
        if CATMonitor.shared.enabled, !data.isEmpty {
            CATMonitor.shared.record(monitorLabel(link), tx: false, data, family: link.spec.family)
        }
        return data
    }

    /// Send one rigctld command for a leg. Full duplex in VFO mode (the default, CardSat's
    /// method): downlink on VFOA, uplink on VFOB — inline for a `--vfo` server, else
    /// pre-selected with `V` (cached, so a bare command doesn't re-select every time). The
    /// split method maps the uplink to the split command (`F`→`I`, `M`→`X`, `f`→`i`).
    private func rigctldSend(_ link: LiveLink, _ cmd: String, leg: RigRole, _ args: String = "") async {
        let inline = rigctldInline.contains(link.index)
        var command = cmd
        var vfo: String? = inline ? "currVFO" : nil
        if link.leg == .both, config.tuning.rigctldVFOMode {
            let v = CATCodec.rigctldVFO(uplink: leg == .uplink)
            if inline {
                vfo = v
            } else if rigctldCurrentVFO[link.index] != v {
                await sendRaw(link, CATCodec.rigctldSelectVFO(v))
                rigctldCurrentVFO[link.index] = v
            }
        } else if link.leg == .both, config.tuning.rigctldUseSplit, leg == .uplink {
            command = ["F": "I", "M": "X", "f": "i"][cmd] ?? cmd
        }
        await sendRaw(link, CATCodec.rigctldLine(command, vfo: vfo, args))
    }

    private func monitorLabel(_ link: LiveLink) -> String {
        config.twoRadios ? "R\(link.index + 1) \(link.spec.name)" : link.spec.name
    }

    /// Off-main delay using GCD (reliable), NOT Task.sleep — a MainActor
    /// Task.sleep can fail to suspend on this device and freeze the UI.
    private func pace(_ ms: Int) async {
        guard ms > 0 else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) { c.resume() }
        }
    }

    /// The live Icom network transport, if a configured radio uses one — lets the
    /// audio subsystem (recording/SSTV/FT4) run over the RS-BA1 audio stream.
    var icomAudioTransport: IcomNetworkTransport? {
        guard connected else { return nil }
        for link in links { if let t = link.transport as? IcomNetworkTransport { return t } }
        return nil
    }

    /// True when the connected station is running half duplex: a single radio in
    /// split-VFO mode (chosen, or automatic for a same-band bird) or the FT-847
    /// same-band transmit hold. Full-duplex-only features (satellite FT4) check this.
    var isSplitVFO: Bool { connected && links.contains { $0.split || $0.txHold } }

    // MARK: PTT (for full-duplex FT4)

    /// Whether the uplink radio can be keyed over CAT.
    var pttSupported: Bool {
        guard connected, let link = links.first(where: { ($0.leg == .uplink || $0.leg == .both) && !$0.spec.rxOnly }) else { return false }
        switch link.spec.family {
        case .civ: return link.spec.civHasPTT      // IC-706 family, IC-821H, … have no 1C
        case .yaesuBinary, .yaesuFT736, .kenwoodBase, .rigctld: return true
        default: return false
        }
    }

    /// Key/unkey the uplink radio over CAT, if supported. No-op otherwise (the
    /// operator uses VOX or manual PTT).
    func setPTT(_ on: Bool) async {
        guard connected, let link = links.first(where: { ($0.leg == .uplink || $0.leg == .both) && !$0.spec.rxOnly }) else {
            ODLog.shared.log("setPTT(\(on)) ignored — not connected or no keyable uplink link", category: "cat")
            return
        }
        ODLog.shared.log("setPTT(\(on)) → \(link.spec.name) [\(link.spec.family)]", category: "cat")
        // Split: put VFO B on the current Doppler target before keying, since uplink
        // writes that need a VFO swap are held for the length of the transmission.
        var heldTickLock = false
        if on, link.split {
            // On a VFO-swapping rig a tick may have VFO B selected right now, and with
            // SPLIT on that would transmit on VFO A. Let any in-flight tick finish, then
            // hold the tick lock until the radio is keyed so none can start in between.
            var waited = 0
            while isTicking, waited < 2000 { await pace(20); waited += 20 }
            if !isTicking { isTicking = true; heldTickLock = true }
            if lastTargetTx > 0, lastTargetTx != lastSentTx {
                await sendSplitFreq(link, leg: .uplink, hz: lastTargetTx)
                lastSentTx = lastTargetTx
            }
        }
        defer { if heldTickLock { isTicking = false } }
        // FT-847 same-band hold: move the main VFO to the uplink just for the transmission.
        if on, link.txHold {
            var waited = 0
            while isTicking, waited < 2000 { await pace(20); waited += 20 }
            if !isTicking { isTicking = true; heldTickLock = true }
            if lastTargetTx > 0 {
                await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: UInt64(lastTargetTx), vfo: .plain))
                await pace(60)
            }
        }
        pttKeyed = on
        switch link.spec.family {
        case .civ where link.spec.civHasPTT: await sendRaw(link, CATCodec.civPTT(addr: civAddr(link), on: on))
        case .yaesuBinary, .yaesuFT736: await sendRaw(link, CATCodec.yaesuPTT(on: on))
        case .kenwoodBase: await sendRaw(link, CATCodec.kwPTT(on: on))
        case .rigctld:
            await sendRaw(link, CATCodec.rigctldLine("T", vfo: rigctldInline.contains(link.index) ? "currVFO" : nil, on ? "1" : "0"))
        default: break
        }
        if !on, link.txHold, lastTargetRx > 0 {
            await pace(60)
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: UInt64(lastTargetRx), vfo: .plain))
            lastSentRx = lastTargetRx
        }
    }

    // MARK: Helpers

    func transponder(for sat: SatelliteRecord) -> TransponderRecord? {
        // Locked on an engaged satellite the Home card no longer shows: keep its transponder.
        if sat.id == engagedNorad, sat.id != store?.selectedSatellite?.id,
           let id = engagedTpID, let tp = sat.transponders.first(where: { $0.id == id }) { return tp }
        if let id = transponderID, let tp = sat.transponders.first(where: { $0.id == id }) { return tp }
        // Prefer a two-way (linear/FM with uplink) transponder, else the first.
        return sat.transponders.first(where: { $0.uplinkCenter > 0 }) ?? sat.transponders.first
    }

    /// The satellite's beacon/telemetry transmitter for the Home "Beacon" button: a
    /// receive-only transponder, preferring one named as a beacon or telemetry.
    func beaconTransponder(for sat: SatelliteRecord) -> TransponderRecord? {
        let rxOnly = sat.transponders.filter { $0.uplinkCenter <= 0 }
        let named = rxOnly.first { tp in
            let text = "\(tp.description) \(tp.kind) \(tp.mode)".lowercased()
            return ["beacon", "telemetry", "tlm"].contains { text.contains($0) }
        }
        return named ?? rxOnly.first
    }

    /// Move the passband trim by `hz` (tilt tuning), clamped at the transponder edge.
    func nudgePassband(_ hz: Double) {
        guard connected, hz != 0, let sat = trackedSatellite, let tp = transponder(for: sat),
              tp.isLinear, tp.bandwidth > 0 else { return }
        config.tuning.passbandOffsetHz += hz
        clampPassband(tp)
    }

    // MARK: Self-test

    struct SelfTestStep: Identifiable, Sendable {
        let id: Int
        let name: String
        /// true = pass, false = fail, nil = informational / not applicable.
        var passed: Bool?
        var detail: String
        var hint: String?
    }
    @Published private(set) var selfTestSteps: [SelfTestStep] = []
    @Published private(set) var selfTestRunning = false
    @Published private(set) var selfTestSlot: Int?

    /// Guided check of one configured radio, on its own short-lived link: connect, any
    /// session handshake, read the frequency, read the mode and set it back to the same
    /// mode (so the radio is left as found), checking the ACK/NAK where the protocol has
    /// one (CI-V FB/FA, Kenwood `?;`, rigctld RPRT). Only while CAT is disconnected.
    func runSelfTest(slot index: Int) async {
        guard !selfTestRunning, !connected, !connecting, index < config.slots.count else { return }
        let slot = config.slots[index]
        guard let spec = slot.spec else { return }
        selfTestRunning = true; selfTestSlot = index; selfTestSteps = []
        defer { selfTestRunning = false }
        let transport = makeTransport(slot, spec: spec, index: index)
        let link = LiveLink(slot: slot, spec: spec, transport: transport, leg: .downlink, index: index)
        let addr = civAddr(link)
        let baud = slot.baudOverride > 0 ? slot.baudOverride : spec.defaultBaud
        func add(_ name: String, _ passed: Bool?, _ detail: String, hint: String? = nil) {
            selfTestSteps.append(SelfTestStep(id: selfTestSteps.count, name: name, passed: passed, detail: detail, hint: hint))
        }
        ODLog.shared.log("self-test start: \(spec.name) via \(slot.transport.label)", category: "cat")

        // 1. Connect.
        do {
            try await transport.connect()
            add("Connect", true, "\(slot.transport.label) link is up.")
        } catch {
            let hint: String
            switch slot.transport {
            case .ble: hint = "Make sure the adapter is powered, in range, and not connected to another app. Choose it again in the BLE adapter picker if needed."
            case .bleicom: hint = "On the radio: Menu ▸ Set ▸ Bluetooth Set ▸ Pairing Reception, then run the test again."
            case .network: hint = "Check the radio's IP address, control port (50001), Network Control and the User1 login."
            case .rigctld: hint = "Check the host and port and that rigctld is running and reachable on your network."
            }
            add("Connect", false, error.localizedDescription, hint: hint)
            await transport.disconnect()
            return
        }

        // 2. Session handshakes the controller also sends at connect.
        if spec.family == .yaesuFT736 || (spec.family == .yaesuBinary && spec.fullDuplex) {
            await sendRaw(link, CATCodec.yaesuCATOn); await pace(60)
            add("CAT on", nil, "Sent CAT-ON (this radio needs it before it accepts commands).")
        }
        if spec.family == .kenwoodHandheld {
            for f in CATCodec.khtSession() { await sendRaw(link, f); await pace(30) }
            add("Session", nil, "Band B set to VFO mode and made the control band.")
        }
        if spec.family == .rigctld {
            _ = await readReply(link, maxWait: 0.05)
            await sendRaw(link, CATCodec.rigctldChkVFO)
            let reply = await readReply(link, maxWait: 0.5)
            let inline = CATCodec.rigctldParseChkVFO(reply)
            if inline { rigctldInline.insert(link.index) }
            add("rigctld", reply.isEmpty ? false : true,
                reply.isEmpty ? "No answer to \\chk_vfo." : (inline ? "Server runs with --vfo (VFO sent inline)." : "Plain server (VFO selected with V)."),
                hint: reply.isEmpty ? "rigctld didn't answer. Check that it's running and connected to the radio." : nil)
        }

        let noReplyHint: String = {
            switch spec.family {
            case .civ:
                return String(format: "No CI-V reply. Check the CI-V address (%02X), that the adapter's serial rate matches the radio's CI-V baud rate (%d), CI-V Transceive, and that the radio routes CI-V to the port you're using.", addr, baud)
            case .yaesuBinary, .yaesuFT100, .yaesuVR5000, .yaesuFT736:
                return "No reply. Check that the radio's CAT rate matches the adapter (\(baud) baud) and that the CAT cable is on the CAT jack."
            case .kenwoodBase:
                return "No reply. Check that the radio's COM rate matches the adapter (\(baud) baud) and the cable is on the COM/RS-232 port."
            case .kenwoodHandheld:
                return "No reply. Check the B.B. Link pairing and that band B is in VFO mode."
            case .rigctld:
                return "No frequency from rigctld. Check that rigctld can talk to the radio (try rigctl f on that computer)."
            }
        }()

        // 3. Read the frequency.
        var yaesuModeByte: UInt8?
        if spec.canReadFreq {
            if spec.family == .yaesuBinary {
                // The FT-817-family frequency reply carries the mode in its 5th byte.
                _ = await readReply(link, maxWait: 0.02)
                await sendRaw(link, CATCodec.yaesuReadFreq(spec, vfo: .plain))
                let data = await readReply(link, maxWait: 0.5)
                if let hz = CATCodec.yaesuParseFreq(spec, data) {
                    add("Read frequency", true, ODFormat.frequency(Int64(hz)))
                    yaesuModeByte = data.suffix(5).last
                } else {
                    add("Read frequency", false, data.isEmpty ? "No reply." : "Unreadable reply: \(CATCodec.hex(data))", hint: noReplyHint)
                }
            } else if let hz = await readLegFreq(link, leg: .downlink) {
                add("Read frequency", true, ODFormat.frequency(Int64(hz)))
            } else {
                add("Read frequency", false, "No usable reply.", hint: noReplyHint)
            }
        } else {
            add("Read frequency", nil, "\(spec.name) can't report its frequency over CAT (write-only), so the rest of the test can't confirm anything.")
        }

        // 4. Mode: read it, set the same mode back, check the acknowledgment, read again.
        switch spec.family {
        case .civ:
            _ = await readReply(link, maxWait: 0.02)
            await sendRaw(link, CATCodec.civReadMode(addr: addr))
            let body = CATCodec.civReply(await readReply(link, maxWait: 0.5), addr: addr, cmd: 0x04)
            let mode = body?.first.flatMap(CATCodec.civModeFromByte)
            add("Read mode", mode != nil, mode.map { $0.label } ?? "No usable reply.", hint: mode == nil ? noReplyHint : nil)
            let setMode = mode ?? .usb
            await sendRaw(link, CATCodec.civSetMode(spec, addr: addr, mode: setMode))
            switch CATCodec.civAck(await readReply(link, maxWait: 0.5), addr: addr) {
            case true?: add("Set mode (\(setMode.label))", true, "Radio answered OK (FB).")
            case false?: add("Set mode (\(setMode.label))", false, "Radio answered NG (FA).",
                             hint: "The radio rejected the mode command. Some rigs refuse it in memory/satellite mode, or reject the filter byte — try VFO mode on the radio.")
            case nil: add("Set mode (\(setMode.label))", false, "No OK/NG reply.", hint: noReplyHint)
            }
        case .kenwoodBase:
            _ = await readReply(link, maxWait: 0.02)
            await sendRaw(link, CATCodec.kwReadMode)
            let mode = CATCodec.kwParseMode(await readReply(link, maxWait: 0.5))
            add("Read mode", mode != nil, mode.map { $0.label } ?? "No usable reply.", hint: mode == nil ? noReplyHint : nil)
            let setMode = mode ?? .usb
            for f in CATCodec.kwSetMode(spec, setMode) { await sendRaw(link, f) }
            let reply = await readReply(link, maxWait: 0.3)
            let rejected = String(decoding: reply, as: UTF8.self).contains("?")
            add("Set mode (\(setMode.label))", rejected ? false : nil, rejected ? "Radio answered ?; (command error)." : "Sent (Kenwood only answers errors).",
                hint: rejected ? "The radio refused MD. Check the model choice (TS-990S uses OM) and that it isn't in a menu." : nil)
            await sendRaw(link, CATCodec.kwReadMode)
            let after = CATCodec.kwParseMode(await readReply(link, maxWait: 0.5))
            add("Confirm mode", after == setMode, after.map { $0.label } ?? "No reply.")
        case .rigctld:
            await rigctldSend(link, "m", leg: .downlink)
            let name = CATCodec.rigctldParseMode(await readReply(link, maxWait: 0.5))
            add("Read mode", name != nil, name ?? "No usable reply.", hint: name == nil ? noReplyHint : nil)
            let mode = name.map { RigMode.parse($0) } ?? .usb
            await rigctldSend(link, "M", leg: .downlink, CATCodec.rigctldModeArgs(mode))
            let status = CATCodec.rigctldStatus(await readReply(link, maxWait: 0.5))
            add("Set mode (\(mode.label))", status == 0, status.map { "RPRT \($0)" } ?? "No RPRT reply.",
                hint: status == 0 ? nil : "rigctld refused the mode. Check the Hamlib model and that the radio is in VFO mode.")
        case .yaesuBinary:
            guard let b = yaesuModeByte else {
                add("Mode", nil, "Skipped: the frequency read failed, so the current mode is unknown.")
                break
            }
            let map: [UInt8: RigMode] = [0x00: .lsb, 0x01: .usb, 0x02: .cw, 0x04: .am, 0x08: .fm, 0x88: .fmn]
            guard let mode = map[b] else { add("Read mode", nil, String(format: "Mode byte %02X (data/other) — left as is.", b)); break }
            add("Read mode", true, mode.label)
            await sendRaw(link, CATCodec.yaesuSetMode(spec, mode: mode, vfo: .plain))
            _ = await readReply(link, maxWait: 0.05)
            await sendRaw(link, CATCodec.yaesuReadFreq(spec, vfo: .plain))
            let again = await readReply(link, maxWait: 0.5)
            add("Set mode (\(mode.label))", again.suffix(5).last == b, again.isEmpty ? "No reply after setting the mode." : "Mode confirmed by read-back.",
                hint: again.isEmpty ? noReplyHint : nil)
        default:
            add("Mode", nil, "Not tested on this radio (no CAT confirmation).")
        }

        await transport.disconnect()
        rigctldInline.remove(link.index)
        let failed = selfTestSteps.contains { $0.passed == false }
        ODLog.shared.log("self-test \(spec.name): \(failed ? "FAILED" : "passed") — \(selfTestSteps.map { "\($0.name)=\($0.passed.map { $0 ? "ok" : "fail" } ?? "info")" }.joined(separator: ", "))", category: "cat")
    }
}

// MARK: - CAT monitor

/// Bounded live record of every CAT frame (TX and RX, per link) for the CAT monitor
/// screen. Off by default and never persisted; when off, `RigController` doesn't call
/// in at all, so it costs nothing.
@MainActor
final class CATMonitor: ObservableObject {
    static let shared = CATMonitor()
    static let capacity = 500

    @Published var enabled = false
    @Published private(set) var lines: [String] = []

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func record(_ link: String, tx: Bool, _ bytes: [UInt8], family: RigFamily) {
        let decode = CATCodec.describe(bytes, family: family)
        let ascii = family == .kenwoodBase || family == .kenwoodHandheld || family == .rigctld
        // ASCII protocols read better as text; binary ones get the hex plus the decode.
        let body = ascii ? decode : (decode.isEmpty ? CATCodec.hex(bytes) : "\(CATCodec.hex(bytes))  | \(decode)")
        lines.append("\(stamp.string(from: Date())) \(tx ? "TX" : "RX") \(link)  \(body)")
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    func clear() { lines.removeAll() }

    var text: String { lines.joined(separator: "\n") }
}

// MARK: - Tilt tuning

/// One-handed passband tuning: rolling the phone left/right nudges the passband offset
/// at a rate that grows with the tilt, with a dead zone around level. Device motion
/// needs no permission prompt. Runs only while `RigController.tiltTuning` is on.
@MainActor
final class TiltTuner {
    private let motion = CMMotionManager()
    private weak var rig: RigController?
    private var lastTimestamp: TimeInterval = 0

    /// Roll inside ±this (degrees) does nothing.
    static let deadZoneDeg = 6.0
    /// Roll at which the rate peaks (degrees).
    static let fullScaleDeg = 40.0
    /// Peak tuning rate (Hz per second).
    static let maxRateHz = 3000.0

    func setActive(_ on: Bool, rig: RigController) {
        if on {
            guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
            self.rig = rig
            lastTimestamp = 0
            motion.deviceMotionUpdateInterval = 0.1
            // Delivered on the main queue, so hopping onto the main actor is safe.
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let roll = data.attitude.roll, time = data.timestamp
                MainActor.assumeIsolated { self?.apply(rollRadians: roll, at: time) }
            }
        } else {
            motion.stopDeviceMotionUpdates()
            lastTimestamp = 0
        }
    }

    private func apply(rollRadians: Double, at time: TimeInterval) {
        defer { lastTimestamp = time }
        guard lastTimestamp > 0, let rig else { return }
        let dt = min(0.25, max(0, time - lastTimestamp))
        let deg = rollRadians * 180 / .pi
        let past = abs(deg) - Self.deadZoneDeg
        guard past > 0 else { return }
        // Squared ramp: fine control near level, faster sweeps at a steep tilt.
        let x = min(1, past / (Self.fullScaleDeg - Self.deadZoneDeg))
        let rate = (deg > 0 ? 1 : -1) * x * x * Self.maxRateHz
        rig.nudgePassband(rate * dt)
    }
}

// MARK: - rigctld server bridge

/// Entry points for the built-in Hamlib rigctld server (`RigctldServer`, in
/// CATTransport.swift). Legs are addressed as `.downlink` (Hamlib VFOA) and `.uplink`
/// (VFOB); frequencies are the radio's own dial (rig units, i.e. after any transverter
/// LO is subtracted). Every bus access waits for and then holds the Doppler loop's tick
/// lock, so a server read or write never interleaves with a tick on the same transport.
extension RigController {
    /// Whether the connected station has a radio carrying `leg`.
    func serverHasLeg(_ leg: RigRole) -> Bool {
        guard connected, let link = followLink(for: leg) else { return false }
        return !(leg == .uplink && link.spec.rxOnly)
    }

    /// True while the Doppler loop is actively commanding the radio (connected, Track
    /// Doppler on, a target computed, not held by FT4 or an external client).
    var serverDopplerDriving: Bool {
        connected && config.tuning.trackDoppler && !holdDoppler && lastTargetRx > 0
    }

    /// Whether Hamlib's "Main" VFO name means the uplink on this station.
    var serverMainIsUplink: Bool {
        guard let spec = links.first?.spec else { return config.tuning.mainIsUplink }
        return mainCarriesUplink(spec)
    }

    /// The leg's current dial frequency. While the Doppler loop is driving the radio this
    /// is the last commanded dial (no bus traffic, so a polling logger doesn't slow the
    /// loop); otherwise it's read back from the radio, falling back to the last value sent.
    func serverRigFrequency(leg: RigRole) async -> Int64? {
        guard serverHasLeg(leg), let link = followLink(for: leg) else { return nil }
        let lastSent = leg == .uplink ? lastSentTx : lastSentRx
        if serverDopplerDriving, lastSent > 0 { return lastSent }
        let read: UInt64? = await serverWithBus {
            let f = await readLegFreq(link, leg: leg)
            if leg == .uplink, link.leg == .both { await reselectDownlink(link) }
            return f
        }
        if let read, read > 0 { return Int64(read) }
        return lastSent > 0 ? lastSent : nil
    }

    /// Tune a leg to `hz` (dial units). The caller holds the Doppler loop first
    /// (`serverBeginExternalHold`) so the loop doesn't immediately retune it.
    func serverSetFrequency(leg: RigRole, hz: Int64, mode: RigMode?) async -> Bool {
        guard hz > 0, serverHasLeg(leg), let link = followLink(for: leg) else { return false }
        let ok: Bool = await serverWithBus {
            let sent = await sendFreq(link, leg: leg, hz: hz, mode: mode ?? .usb)
            if leg == .uplink, link.leg == .both { await reselectDownlink(link) }
            return sent
        }
        if ok {
            if leg == .uplink { lastSentTx = hz } else { lastSentRx = hz }
        }
        return ok
    }

    /// Set a leg's operating mode.
    func serverSetMode(leg: RigRole, mode: RigMode) async -> Bool {
        guard serverHasLeg(leg), let link = followLink(for: leg) else { return false }
        await serverWithBus {
            await sendModeCIVorOther(link, mode: mode, leg: leg)
            if leg == .uplink, link.leg == .both { await reselectDownlink(link) }
        }
        return true
    }

    /// The mode OrbitDeck would put on a leg for the current transponder, if known.
    func serverDerivedMode(leg: RigRole) -> RigMode? {
        guard let sat = store?.selectedSatellite, let tp = transponder(for: sat) else { return nil }
        var dl = RigMode.downlink(for: tp)
        var ul = RigMode.uplink(for: tp, downlink: dl)
        if config.tuning.linearCW, tp.isLinear, !useDataModeForDigital {
            if dl == .usb || dl == .lsb { dl = .cw }
            if ul == .usb || ul == .lsb { ul = .cw }
        }
        return leg == .uplink ? ul : dl
    }

    /// Whether OrbitDeck has keyed the uplink radio.
    var serverPTT: Bool { pttKeyed }

    /// Key/unkey through the normal PTT path. False when the uplink radio can't be keyed.
    func serverSetPTT(_ on: Bool) async -> Bool {
        guard pttSupported else { return false }
        await setPTT(on)
        return true
    }

    /// Hold the Doppler loop for an external client. Returns true if this call took the
    /// hold (it was off). If it's already held (by this server or by FT4) the hold is just
    /// re-scoped to the current satellite/transponder, so automatic switching can't
    /// silently resume OrbitDeck's own Doppler while the client is still steering.
    @discardableResult
    func serverBeginExternalHold() -> Bool {
        if holdDoppler {
            holdSatTp = currentSatTp(); holdScopeMismatch = false
            return false
        }
        holdDoppler = true
        ODLog.shared.log("rigctld server: external client is tuning — OrbitDeck Doppler paused", category: "cat")
        return true
    }

    /// Release a hold taken by `serverBeginExternalHold`, forcing both legs to be
    /// re-commanded on the next tick.
    func serverEndExternalHold() {
        guard holdDoppler else { return }
        holdDoppler = false
        lastSentRx = 0; lastSentTx = 0
        ODLog.shared.log("rigctld server: external control ended — OrbitDeck Doppler resumed", category: "cat")
    }

    /// Run `body` holding the tick lock (waits up to 2 s for an in-flight tick).
    private func serverWithBus<T>(_ body: () async -> T) async -> T {
        var waited = 0
        while isTicking, waited < 2000 { await pace(20); waited += 20 }
        let took = !isTicking
        if took { isTicking = true }
        let result = await body()
        if took { isTicking = false }
        return result
    }
}
