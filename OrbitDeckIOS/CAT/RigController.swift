import Foundation
import Combine

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
    var holdDoppler = false
    /// Which transponder of the selected satellite CAT tracks.
    @Published var transponderID: String?
    /// Per-radio connection status for the Home card (one entry per configured
    /// radio, so a two-radio station shows both).
    @Published var statuses: [RigLinkStatus] = []

    struct RigLinkStatus: Identifiable, Sendable {
        let id: Int
        let radioName: String
        let transport: CATTransportKind
        let leg: RigRole
        var connecting: Bool
        var connected: Bool
        var error: String?

        var stateText: String {
            if connecting { return "Connecting…" }
            if let error { return error }
            if connected { return "Connected" }
            return "Not connected"
        }
        /// e.g. "IC-705 · Icom network (Wi-Fi)" or "TH-D75 · BLE — downlink".
        var title: String {
            var s = "\(radioName) · \(transport.label)"
            if leg != .both { s += " — \(leg == .uplink ? "uplink" : "downlink")" }
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
    /// Command the rig's DATA sub-mode (USB-D/LSB-D) for the digital audio path. Set by an
    /// FT4 session when "Use data mode for FT4" is on, so the ACC/USB data port carries the
    /// audio rather than the mic. Only affects data-capable CI-V rigs.
    private(set) var useDataModeForDigital = false
    private var dataModeApplied = false     // we turned DATA on and must turn it back off

    /// Data-mode-capable CI-V transceivers (USB-D via CI-V 1A 06). Older rigs (IC-820/821/
    /// 910/970, IC-2xx/4xx, IC-706 family) have no data mode and are left on plain SSB.
    private static let dataModeModels: Set<String> = ["IC-9700", "IC-9100", "IC-705", "IC-905", "IC-7100", "IC-7000"]
    /// Yaesu rigs with a DIG data mode (0x0A). The FT-847/736R have no CAT data mode.
    private static let yaesuDataModels: Set<String> = ["FT-817", "FT-818", "FT-857", "FT-897"]
    /// Whether this radio can be put in a DATA sub-mode for the digital audio path.
    private func isDataModeCapable(_ spec: RadioSpec) -> Bool {
        switch spec.family {
        case .civ:         return Self.dataModeModels.contains(spec.id)
        case .rigctld:     return true      // Hamlib maps to PKT* on radios that have it
        case .yaesuBinary: return Self.yaesuDataModels.contains(spec.id)
        default:           return false     // Kenwood/FT-736R/FT-847: no clean CAT data mode
        }
    }

    /// Turn the digital DATA sub-mode on/off and force the modes to be re-applied on the
    /// next tick (the engage key includes this flag).
    func setDigitalDataMode(_ on: Bool) {
        guard on != useDataModeForDigital else { return }
        useDataModeForDigital = on
        lastEngageKey = ""     // force applyModes() to run again
        if connected, holdDoppler { Task { await stepDopplerNow() } }   // FT4 is slot-gated
    }
    /// Last "why the loop can't tune" message, so we log it only when it changes.
    private var lastTickBail = ""
    /// Throttle for per-tick frequency-send logging (diagnostics).
    private var lastFreqLogAt = Date.distantPast
    /// Previous tick's commanded downlink dial + time, for the adaptive-deadband (D2)
    /// Doppler-slew estimate. Reset in startLoop().
    private var lastTickRxReal: Int64 = 0
    private var lastTickTime = Date.distantPast

    private struct LiveLink {
        let slot: RigSlot
        let spec: RadioSpec
        let transport: CATTransport
        let leg: RigRole      // .both, .downlink or .uplink
    }

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
        guard config.isConfigured, let slot0 = config.slots.first, let spec0 = slot0.spec else {
            errorText = "Configure a radio first."; return
        }
        connecting = true; wantConnection = true; errorText = ""; statusText = "Connecting…"
        persist()

        // Build the link list. Slot 0 is the primary radio; slot 1 (dual) is uplink.
        var built: [LiveLink] = []
        // A receive-only radio (CI-V receivers, RX-only handhelds) can only ever be a
        // downlink: never honour a config that assigns it the uplink/both leg, so no TX
        // frequency/mode/PTT frame is sent to a radio that must not transmit.
        let leg0: RigRole = config.twoRadios ? .downlink : (spec0.rxOnly ? .downlink : slot0.role)
        built.append(LiveLink(slot: slot0, spec: spec0, transport: makeTransport(slot0, spec: spec0, index: 0), leg: leg0))
        if config.twoRadios, config.slots.count > 1, config.slots[1].enabled, let spec1 = config.slots[1].spec {
            if spec1.rxOnly {
                ODLog.shared.log("ignoring uplink radio \(spec1.name): receive-only", category: "cat")
            } else {
                built.append(LiveLink(slot: config.slots[1], spec: spec1,
                                      transport: makeTransport(config.slots[1], spec: spec1, index: 1), leg: .uplink))
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
                          leg: link.leg, connecting: true, connected: false, error: nil)
        }
        for link in built {
            ODLog.shared.log("connect start: \(link.spec.name) via \(String(describing: link.slot.transport)) leg=\(String(describing: link.leg)) host=\(link.slot.host):\(link.slot.port)", category: "cat")
        }

        Task {
            // Connect all radios concurrently so both progress at once. Capture the
            // Sendable transport, not the (non-Sendable) LiveLink.
            await withTaskGroup(of: (Int, String?).self) { group in
                for (i, link) in links.enumerated() {
                    let t = link.transport
                    group.addTask {
                        do { try await t.connect(); return (i, nil) }
                        catch { return (i, error.localizedDescription) }
                    }
                }
                for await (i, err) in group where i < statuses.count {
                    statuses[i].connecting = false
                    if let err {
                        statuses[i].error = err
                        ODLog.shared.log("connect failed [\(statuses[i].radioName)]: \(err)", category: "cat")
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

    func disconnect() {
        timer?.cancel(); timer = nil
        // Clear `connected` BEFORE tearing the transports down: closing a socket can fire
        // its onError/state handler, and handleLinkDropped() guards on `connected`, so this
        // stops a caller-initiated disconnect from being mistaken for a live drop.
        connected = false
        wantConnection = false
        reconnectAttempts = 0
        statuses.removeAll()
        Task { await teardown(); statusText = "Not connected." }
    }

    private func teardown() async {
        for link in links { await link.transport.disconnect() }
        links.removeAll()
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
        for link in links {
            let addr = civAddr(link)
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
            // Satellite mode. The IC-9100/9700 (canAssignBand) REQUIRE satellite mode for
            // full-duplex MAIN/SUB tuning to take effect, so command it automatically for
            // those; other CI-V rigs honour the user's "Command satellite mode" toggle.
            if link.spec.family == .civ, link.spec.fullDuplex,
               (config.tuning.satMode || link.spec.canAssignBand),
               let f = CATCodec.civSatMode(link.spec, addr: addr, on: true) {
                await sendRaw(link, f)
                ODLog.shared.log("sat mode ON → \(link.spec.name)", category: "cat")
                await pace(60)
            }
            // rigctld full-duplex single radio: enable split so uplink tracks on
            // the TX VFO while downlink tracks on the RX VFO.
            if link.spec.family == .rigctld, link.leg == .both, config.tuning.rigctldUseSplit {
                await sendRaw(link, CATCodec.rigctldSetSplit(on: true))
            }
        }
    }

    /// Apply mode (and, for the handheld, the fine-step) and uplink tone. Called at
    /// connect and again whenever the satellite, transponder, band or mode changes.
    private func applyModes(dlMode: RigMode, ulMode: RigMode, isFM: Bool) async {
        let toneOn = config.tuning.uplinkToneHz > 0 && isFM
        for link in links {
            switch link.leg {
            case .both:
                // Uplink first (mode + uplink CTCSS on the MAIN band), downlink last —
                // so a full-duplex CI-V rig is left band-selected on the DOWNLINK, the
                // way CardSat does it. Otherwise the rig stays parked on MAIN.
                await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
                if toneOn { await sendTone(link, on: true, toneHz: config.tuning.uplinkToneHz) }
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
            case .downlink:
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
            case .uplink:
                await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
                if toneOn { await sendTone(link, on: true, toneHz: config.tuning.uplinkToneHz) }
            }
        }
    }

    /// Assign which band is on MAIN vs SUB for radios that need it (IC-9100/9700, the
    /// `07 D2` command). Without this the 9700's MAIN/SUB VFOs can sit on the wrong
    /// bands, so Doppler frequency/mode writes land where the operator can't see them.
    /// MAIN = uplink, SUB = downlink (unless the operator swapped that). Auto for
    /// canAssignBand rigs; other rigs are unaffected.
    private func applyBandAssignment(tp: TransponderRecord) async {
        for link in links where link.spec.canAssignBand && link.leg == .both {
            let mainIsUp = mainCarriesUplink(link.spec)
            let mainHz = UInt64(max(0, mainIsUp ? tp.uplinkCenter : tp.downlinkCenter))
            let subHz  = UInt64(max(0, mainIsUp ? tp.downlinkCenter : tp.uplinkCenter))
            let frames = CATCodec.civAssignBands(link.spec, addr: civAddr(link), mainHz: mainHz, subHz: subHz)
            guard !frames.isEmpty else { continue }
            for f in frames { await sendRaw(link, f); await pace(60) }
            ODLog.shared.log("band assign \(link.spec.name): MAIN=\(mainHz) SUB=\(subHz)", category: "cat")
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
        let ms = max(100, config.tuning.updateMs)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        t.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTicking else { return }
                // Slot-gated (FT4): the periodic loop is suppressed; frequency is stepped
                // at slot boundaries via stepDopplerNow() instead.
                if self.holdDoppler { return }
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
    /// slots) so it never retunes mid-slot. Overlap-guarded like the periodic tick.
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
        guard config.tuning.trackDoppler else { return bailLog("Track Doppler is off") }
        guard let store, let sat = store.selectedSatellite else { return bailLog("no satellite selected") }
        guard let tp = transponder(for: sat) else { return bailLog("no transponder for \(sat.name) — select one on the Home card") }
        bailLog("")   // clear: we can tune
        let observer = store.preferences.observer
        let isFM = tp.mode.uppercased().contains("FM")
        var deadband = Int64(isFM ? config.tuning.fmDeadbandHz : config.tuning.linearDeadbandHz)   // adapted near TCA (D2)
        let dlMode = RigMode.parse(tp.mode)
        let ulMode = uplinkMode(dlMode, invert: tp.invert, linear: tp.isLinear)

        // Re-apply mode + step (and tone) whenever the satellite, transponder or
        // mode changes — the frequency band changes with them.
        let key = "\(sat.id)|\(tp.id)|\(dlMode.rawValue)|\(ulMode.rawValue)|\(useDataModeForDigital)"
        if key != lastEngageKey {
            lastEngageKey = key
            lastSentRx = 0; lastSentTx = 0; uplinkDeferTicks = 0
            ODLog.shared.log("engage \(sat.name)/\(tp.id): dl=\(dlMode.rawValue) ul=\(ulMode.rawValue) \(isFM ? "FM" : "linear")", category: "cat")
            await applyBandAssignment(tp: tp)
            await applyModes(dlMode: dlMode, ulMode: ulMode, isFM: isFM)
        }

        // One True Rule: read the followed leg and fold an operator dial move into
        // the passband offset. The followed leg then LEADS — we don't re-command it on
        // the same tick (mark its last-sent as the observed value), so we don't fight
        // the operator's dial; Doppler resumes on it next tick. The other leg is always
        // re-commanded from the updated offset below, so following never starves tuning.
        if config.tuning.followRadio {
            let followLeg = config.tuning.followLeg
            let last = (followLeg == .downlink) ? lastSentRx : lastSentTx
            if last != 0, let fl = followLink(for: followLeg),
               let obs = await readLegFreq(fl, leg: followLeg) {
                let delta = Int64(obs) - last
                let thresh = max(Int64(30), deadband)
                if abs(delta) >= thresh, abs(delta) < 1_000_000 {
                    let d = Double(delta)
                    config.tuning.passbandOffsetHz += (followLeg == .downlink) ? d : (tp.invert ? -d : d)
                    if followLeg == .downlink { lastSentRx = Int64(obs) } else { lastSentTx = Int64(obs) }
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
        let baseLeadSec = (Double(config.tuning.leadMs) + Double(config.tuning.updateMs) * 0.5) / 1000.0
        let rrNow = (try? OrbitPredictor.look(sat, observer: observer, at: Date()))?.rangeRateKmS ?? 0
        let leadTaper = min(1.0, abs(rrNow) / 0.35)
        let leadSec = baseLeadSec * leadTaper
        let when = Date().addingTimeInterval(leadSec)
        guard let look = try? OrbitPredictor.look(sat, observer: observer, at: when) else { return }
        let offset = tp.isLinear ? Int64(config.tuning.passbandOffsetHz.rounded()) : 0
        let downlink = tp.downlinkCenter + offset
        let uplink: Int64 = {
            let u = tp.uplinkCenter
            guard tp.isLinear, u > 0 else { return u }
            return tp.invert ? u - offset : u + offset
        }()
        let cal = store.downlinkCalibrationHz(for: sat.id, invert: tp.invert) + Double(config.tuning.calDownlinkHz)
        let corrected = OrbitPredictor.dopplerFrequencies(downlinkHz: downlink, uplinkHz: uplink,
                                                          rangeRateKmS: look.rangeRateKmS,
                                                          downlinkCalibrationHz: cal,
                                                          uplinkCalibrationHz: Double(config.tuning.calUplinkHz))
        // Transverter LO: the rig tunes (real − LO).
        let rxReal = corrected.rx, txReal = corrected.tx
        downlinkDialHz = rxReal; uplinkDialHz = txReal
        let rxRig = rxReal - config.tuning.xvtrDownlinkHz
        let txRig = txReal - config.tuning.xvtrUplinkHz

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

        for link in links {
            switch link.leg {
            case .both:
                // Downlink first (CardSat driveDownlink), then uplink.
                let followUplink = config.tuning.followRadio && config.tuning.followLeg == .uplink
                let dlMoved = abs(rxRig - lastSentRx) >= deadband
                if dlMoved { await sendFreq(link, leg: .downlink, hz: rxRig, mode: dlMode); lastSentRx = rxRig }
                if uplink > 0, abs(txRig - lastSentTx) >= deadband {
                    if followUplink {
                        // OTR-uplink: write the uplink immediately (no defer) and LEAVE
                        // band access on the uplink, so the followed-uplink read stays
                        // valid and the operator's uplink VFO isn't yanked back to RX
                        // each tick (CardSat driveUplinkOtr → rigSelectUplink).
                        await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode); lastSentTx = txRig
                    } else if dlMoved && uplinkDeferTicks == 0 {
                        // Defer the uplink one tick after a downlink move so the shared
                        // bus isn't congested (CardSat driveUplinkDeferred).
                        uplinkDeferTicks = 1
                    } else {
                        uplinkDeferTicks = 0
                        await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode); lastSentTx = txRig
                        // Return band access to the downlink so the rig stays on RX
                        // (matches CardSat's driveUplink → rigSelectDownlink).
                        await reselectDownlink(link)
                    }
                }
            case .downlink:
                if abs(rxRig - lastSentRx) >= deadband { await sendFreq(link, leg: .downlink, hz: rxRig, mode: dlMode); lastSentRx = rxRig }
            case .uplink:
                if uplink > 0, abs(txRig - lastSentTx) >= deadband { await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode); lastSentTx = txRig }
            }
        }
    }

    // MARK: Read-back (One True Rule)

    private func followLink(for leg: RigRole) -> LiveLink? {
        links.first { $0.leg == leg || $0.leg == .both }
    }

    /// Read the current frequency (rig units) of a leg, or nil if unavailable.
    private func readLegFreq(_ link: LiveLink, leg: RigRole) async -> UInt64? {
        guard link.spec.canReadFreq else { return nil }
        switch link.spec.family {
        case .civ:
            if link.spec.fullDuplex, let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: leg, spec: link.spec)) {
                await sendRaw(link, sel)
            }
            await sendRaw(link, CATCodec.civReadFreq(addr: civAddr(link)))
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.civParseFreq(data, addr: civAddr(link))
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736, .yaesuFT100:
            await sendRaw(link, CATCodec.yaesuReadFreq(link.spec, vfo: yaesuVFO(link, leg: leg)))
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.yaesuParseFreq(link.spec, data)
        case .kenwoodBase:
            // Full-duplex Kenwood: uplink is VFO B — read/parse FB, not FA (follow-uplink).
            let vfoB = link.spec.fullDuplex && leg == .uplink
            await sendRaw(link, CATCodec.kwReadFreq(vfoB: vfoB))
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.kwParseFreq(data, vfoB: vfoB)
        case .kenwoodHandheld:
            await sendRaw(link, CATCodec.khtReadFreq())
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.khtParseFreq(data)
        case .rigctld:
            // Full-duplex split: the uplink is on the TX (split) VFO — read it with `i`.
            let split = link.leg == .both && config.tuning.rigctldUseSplit && leg == .uplink
            await sendRaw(link, split ? CATCodec.rigctldReadSplitFreq() : CATCodec.rigctldReadFreq())
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.rigctldParseFreq(data)
        }
    }

    // MARK: Frame routing

    private func civAddr(_ link: LiveLink) -> UInt8 {
        link.slot.civAddrOverride > 0 ? UInt8(link.slot.civAddrOverride) : link.spec.civAddr
    }

    /// Whether MAIN carries the uplink for this radio. The IC-9100/9700 satellite mode is
    /// a FIXED Main=RX(downlink) / Sub=TX(uplink) layout (per OscarWatch RigSatModeHelper
    /// and Icom's SAT design), so band-assign (07 D2) and MAIN/SUB select must put the
    /// downlink on MAIN — regardless of the generic VFO-Type setting. Using the setting
    /// there sent RS-44's modes to the wrong VFOs (downlink came out LSB, uplink USB).
    private func mainCarriesUplink(_ spec: RadioSpec) -> Bool {
        if spec.canAssignBand { return false }     // 9100/9700: Main = downlink (RX)
        return config.tuning.mainIsUplink
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
        // Full-duplex Yaesu (FT-847 SAT VFOs, FT-736R split RX/TX): map the leg to a VFO.
        guard link.spec.fullDuplex, link.spec.family == .yaesuBinary || link.spec.family == .yaesuFT736 else { return .plain }
        return leg == .uplink ? .satTX : .satRX
    }

    /// Leave a full-duplex CI-V rig band-selected on the downlink (SUB) so it stays
    /// on receive after an uplink write. No-op for rigs without CI-V band access.
    private func reselectDownlink(_ link: LiveLink) async {
        guard link.spec.family == .civ, link.spec.fullDuplex,
              let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: .downlink, spec: link.spec)) else { return }
        await sendRaw(link, sel)
    }

    private func sendFreq(_ link: LiveLink, leg: RigRole, hz: Int64, mode: RigMode) async {
        guard hz > 0 else { return }
        let u = UInt64(hz)
        switch link.spec.family {
        case .civ:
            if link.spec.fullDuplex, let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: leg, spec: link.spec)) {
                await sendRaw(link, sel)
            }
            await sendRaw(link, CATCodec.civSetFreq(link.spec, addr: civAddr(link), hz: u))
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736:
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: u, vfo: yaesuVFO(link, leg: leg)))
        case .yaesuFT100:
            await sendRaw(link, CATCodec.yaesuSetFreq(link.spec, hz: u, vfo: .plain))
        case .kenwoodBase:
            // Full-duplex: VFO A = downlink, VFO B = uplink. Mono: VFO A.
            let vfo = (link.spec.fullDuplex && leg == .uplink) ? "FB" : "FA"
            await sendRaw(link, CATCodec.kwSetFreq(vfo: vfo, hz: u))
        case .kenwoodHandheld:
            // TH-D74/D75 refuse off-grid writes: fine mode (SSB/CW/AM) is a 20 Hz
            // grid, FM/DATA (NFM) is 5 kHz. Round to match the step we set at engage.
            let step: UInt64 = (mode == .usb || mode == .lsb || mode == .cw || mode == .am) ? 20 : 5000
            let rounded = ((u + step / 2) / step) * step
            await sendRaw(link, CATCodec.khtSetFreq(hz: rounded))
        case .rigctld:
            // Full-duplex single radio: uplink on the split/TX VFO, downlink on the
            // current VFO. A standalone leg (two-radio station) uses the main VFO.
            if link.leg == .both, leg == .uplink, config.tuning.rigctldUseSplit {
                await sendRaw(link, CATCodec.rigctldSetSplitFreq(hz: u))
            } else {
                await sendRaw(link, CATCodec.rigctldSetFreq(hz: u))
            }
        }
    }

    private func sendModeCIVorOther(_ link: LiveLink, mode: RigMode, leg: RigRole) async {
        // Whether to command the DATA sub-mode for this SSB leg (FT4 digital audio path).
        let wantData = useDataModeForDigital && (mode == .usb || mode == .lsb) && isDataModeCapable(link.spec)
        switch link.spec.family {
        case .civ:
            if link.spec.fullDuplex, let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: leg, spec: link.spec)) {
                await sendRaw(link, sel)
            }
            await sendRaw(link, CATCodec.civSetMode(link.spec, addr: civAddr(link), mode: mode))
            // FT4 data path: with an SSB base mode, toggle the rig's DATA sub-mode (USB-D/
            // LSB-D) on the selected VFO so audio routes over the ACC/USB port. Only touch
            // it on data-capable rigs, and only when we want it on or previously set it on
            // (so a non-FT4 session never disturbs the operator's manual data mode).
            if isDataModeCapable(link.spec), mode == .usb || mode == .lsb,
               useDataModeForDigital || dataModeApplied {
                await sendRaw(link, CATCodec.civDataMode(link.spec, addr: civAddr(link), on: useDataModeForDigital))
                dataModeApplied = useDataModeForDigital
            }
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736:
            // FT-817/818/857/897 use DIG for the data path (wantData); FT-847/736R aren't
            // data-capable so wantData is false and the base mode is sent.
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: yaesuVFO(link, leg: leg), data: wantData))
        case .yaesuFT100:
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: .plain))
        case .kenwoodBase:
            await sendRaw(link, CATCodec.kwSetMode(mode))     // no clean CAT data mode
        case .kenwoodHandheld:
            for f in CATCodec.khtStep(for: mode) { await sendRaw(link, f); await pace(20) }
            await sendRaw(link, CATCodec.khtSetMode(mode))
        case .rigctld:
            // Hamlib PKTUSB/PKTLSB/PKTFM when the data path is wanted (works on any
            // Hamlib-supported radio that has a data mode).
            if link.leg == .both, leg == .uplink, config.tuning.rigctldUseSplit {
                await sendRaw(link, CATCodec.rigctldSetSplitMode(mode, data: wantData))
            } else {
                await sendRaw(link, CATCodec.rigctldSetMode(mode, data: wantData))
            }
        }
    }

    private func sendTone(_ link: LiveLink, on: Bool, toneHz: Double) async {
        switch link.spec.family {
        case .civ:
            for f in CATCodec.civTone(link.spec, addr: civAddr(link), on: on, toneHz: toneHz) { await sendRaw(link, f) }
        case .yaesuBinary where link.spec.id == "FT-847":
            for f in CATCodec.ft847Tone(on: on, toneHz: toneHz) { await sendRaw(link, f) }
        case .kenwoodBase:
            for f in CATCodec.kwTone(on: on, toneHz: toneHz) { await sendRaw(link, f) }
        default: break
        }
    }

    private func sendRaw(_ link: LiveLink, _ bytes: [UInt8]) async {
        try? await link.transport.send(bytes)
        await pace(config.tuning.commandDelayMs)
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

    // MARK: PTT (for full-duplex FT4)

    /// Whether the uplink radio can be keyed over CAT.
    var pttSupported: Bool {
        guard connected, let link = links.first(where: { ($0.leg == .uplink || $0.leg == .both) && !$0.spec.rxOnly }) else { return false }
        switch link.spec.family {
        case .civ, .yaesuBinary, .yaesuFT736, .kenwoodBase, .rigctld: return true
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
        switch link.spec.family {
        case .civ: await sendRaw(link, CATCodec.civPTT(addr: civAddr(link), on: on))
        case .yaesuBinary, .yaesuFT736: await sendRaw(link, CATCodec.yaesuPTT(on: on))
        case .kenwoodBase: await sendRaw(link, CATCodec.kwPTT(on: on))
        case .rigctld: await sendRaw(link, CATCodec.rigctldSetPTT(on: on))
        default: break
        }
    }

    // MARK: Helpers

    func transponder(for sat: SatelliteRecord) -> TransponderRecord? {
        if let id = transponderID, let tp = sat.transponders.first(where: { $0.id == id }) { return tp }
        // Prefer a two-way (linear/FM with uplink) transponder, else the first.
        return sat.transponders.first(where: { $0.uplinkCenter > 0 }) ?? sat.transponders.first
    }

    private func uplinkMode(_ dl: RigMode, invert: Bool, linear: Bool) -> RigMode {
        guard linear, invert else { return dl }
        switch dl { case .usb: return .lsb; case .lsb: return .usb; default: return dl }
    }
}
