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
    private var lastSentRx: Int64 = 0
    private var lastSentTx: Int64 = 0
    /// Identifies the current satellite/transponder/mode so mode + step are
    /// re-applied whenever any of them changes (not just at connect).
    private var lastEngageKey = ""

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
        connecting = true; errorText = ""; statusText = "Connecting…"
        persist()

        // Build the link list. Slot 0 is the primary radio; slot 1 (dual) is uplink.
        var built: [LiveLink] = []
        let leg0: RigRole = config.twoRadios ? .downlink : slot0.role
        built.append(LiveLink(slot: slot0, spec: spec0, transport: makeTransport(slot0, spec: spec0, index: 0), leg: leg0))
        if config.twoRadios, config.slots.count > 1, config.slots[1].enabled, let spec1 = config.slots[1].spec {
            built.append(LiveLink(slot: config.slots[1], spec: spec1,
                                  transport: makeTransport(config.slots[1], spec: spec1, index: 1), leg: .uplink))
        }
        links = built
        // Seed per-radio status (both show "Connecting…" for a two-radio station).
        statuses = built.enumerated().map { i, link in
            RigLinkStatus(id: i, radioName: link.spec.name, transport: link.slot.transport,
                          leg: link.leg, connecting: true, connected: false, error: nil)
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
                    if let err { statuses[i].error = err } else { statuses[i].connected = true }
                }
            }

            if statuses.allSatisfy({ $0.connected }) {
                await engageOnce()
                connected = true; connecting = false
                statusText = "Connected."
                startLoop()
            } else {
                connecting = false; connected = false
                errorText = statuses.compactMap(\.error).first ?? "Connection failed."
                statusText = "Connection failed."
                await teardown()
            }
        }
    }

    func disconnect() {
        timer?.cancel(); timer = nil
        statuses.removeAll()
        Task { await teardown(); connected = false; statusText = "Disconnected." }
    }

    private func teardown() async {
        for link in links { await link.transport.disconnect() }
        links.removeAll()
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
        }
    }

    // MARK: Engage-time setup

    /// One-time-per-connection setup: session handshakes, satellite mode.
    private func engageOnce() async {
        for link in links {
            let addr = civAddr(link)
            if link.spec.family == .yaesuFT736 { await sendRaw(link, CATCodec.yaesuCATOn); await pace(60) }
            if link.spec.family == .kenwoodHandheld {
                for f in CATCodec.khtSession() { await sendRaw(link, f); await pace(30) }
            }
            if config.tuning.satMode, link.spec.family == .civ, link.spec.fullDuplex,
               let f = CATCodec.civSatMode(link.spec, addr: addr, on: true) {
                await sendRaw(link, f)
            }
        }
    }

    /// Apply mode (and, for the handheld, the fine-step) and uplink tone. Called at
    /// connect and again whenever the satellite, transponder, band or mode changes.
    private func applyModes(dlMode: RigMode, ulMode: RigMode, isFM: Bool) async {
        for link in links {
            switch link.leg {
            case .both:
                await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
                await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
            case .downlink: await sendModeCIVorOther(link, mode: dlMode, leg: .downlink)
            case .uplink:   await sendModeCIVorOther(link, mode: ulMode, leg: .uplink)
            }
            if config.tuning.uplinkToneHz > 0, isFM {
                await sendTone(link, on: true, toneHz: config.tuning.uplinkToneHz)
            }
        }
    }

    // MARK: Doppler loop

    private func startLoop() {
        timer?.cancel()
        lastSentRx = 0; lastSentTx = 0; lastEngageKey = ""
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
                self.isTicking = true
                await self.tick()
                self.isTicking = false
            }
        }
        t.resume()
        timer = t
    }

    /// One tuning cycle: compute corrected dials and push changed frequencies.
    func tick() async {
        guard connected, config.tuning.trackDoppler,
              let store, let sat = store.selectedSatellite, let tp = transponder(for: sat) else { return }
        let observer = store.preferences.observer
        let isFM = tp.mode.uppercased().contains("FM")
        let deadband = Int64(isFM ? config.tuning.fmDeadbandHz : config.tuning.linearDeadbandHz)
        let dlMode = RigMode.parse(tp.mode)
        let ulMode = uplinkMode(dlMode, invert: tp.invert, linear: tp.isLinear)

        // Re-apply mode + step (and tone) whenever the satellite, transponder or
        // mode changes — the frequency band changes with them.
        let key = "\(sat.id)|\(tp.id)|\(dlMode.rawValue)|\(ulMode.rawValue)"
        if key != lastEngageKey {
            lastEngageKey = key
            lastSentRx = 0; lastSentTx = 0
            await applyModes(dlMode: dlMode, ulMode: ulMode, isFM: isFM)
        }

        // One True Rule: read the followed leg and fold an operator dial move into
        // the passband offset. NO early return — the send loop below then re-commands
        // both legs with the updated offset, so following never starves tuning.
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
                }
            }
        }

        // Predictive lead + Doppler using the current (possibly just-updated) offset.
        let when = Date().addingTimeInterval(Double(config.tuning.leadMs) / 1000.0)
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

        for link in links {
            switch link.leg {
            case .both:
                if abs(rxRig - lastSentRx) >= deadband { await sendFreq(link, leg: .downlink, hz: rxRig, mode: dlMode); lastSentRx = rxRig }
                if uplink > 0, abs(txRig - lastSentTx) >= deadband { await sendFreq(link, leg: .uplink, hz: txRig, mode: ulMode); lastSentTx = txRig }
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
            if link.spec.fullDuplex, let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: leg)) {
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
            await sendRaw(link, CATCodec.kwReadFreq())
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.kwParseFreq(data)
        case .kenwoodHandheld:
            await sendRaw(link, CATCodec.khtReadFreq())
            let data = await link.transport.readAvailable(maxWait: 0.5)
            return CATCodec.khtParseFreq(data)
        }
    }

    // MARK: Frame routing

    private func civAddr(_ link: LiveLink) -> UInt8 {
        link.slot.civAddrOverride > 0 ? UInt8(link.slot.civAddrOverride) : link.spec.civAddr
    }

    /// For a full-duplex CI-V rig, which VFO is a given leg (per VFO Type).
    private func useSub(for leg: RigRole) -> Bool {
        // Default VFO_MAIN_UP_SUB_DOWN: MAIN = uplink, SUB = downlink.
        let mainIsUplink = config.tuning.mainIsUplink
        switch leg {
        case .downlink: return mainIsUplink        // downlink on SUB when MAIN is uplink
        case .uplink:   return !mainIsUplink
        case .both:     return true
        }
    }

    private func yaesuVFO(_ link: LiveLink, leg: RigRole) -> YaesuVFO {
        guard link.spec.fullDuplex, link.spec.family == .yaesuBinary else { return .plain }
        return leg == .uplink ? .satTX : .satRX
    }

    private func sendFreq(_ link: LiveLink, leg: RigRole, hz: Int64, mode: RigMode) async {
        guard hz > 0 else { return }
        let u = UInt64(hz)
        switch link.spec.family {
        case .civ:
            if link.spec.fullDuplex, let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: leg)) {
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
        }
    }

    private func sendModeCIVorOther(_ link: LiveLink, mode: RigMode, leg: RigRole) async {
        switch link.spec.family {
        case .civ:
            if link.spec.fullDuplex, let sel = CATCodec.civSelect(link.spec, addr: civAddr(link), sub: useSub(for: leg)) {
                await sendRaw(link, sel)
            }
            await sendRaw(link, CATCodec.civSetMode(link.spec, addr: civAddr(link), mode: mode))
        case .yaesuBinary, .yaesuVR5000, .yaesuFT736:
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: yaesuVFO(link, leg: leg)))
        case .yaesuFT100:
            await sendRaw(link, CATCodec.yaesuSetMode(link.spec, mode: mode, vfo: .plain))
        case .kenwoodBase:
            await sendRaw(link, CATCodec.kwSetMode(mode))
        case .kenwoodHandheld:
            for f in CATCodec.khtStep(for: mode) { await sendRaw(link, f); await pace(20) }
            await sendRaw(link, CATCodec.khtSetMode(mode))
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
