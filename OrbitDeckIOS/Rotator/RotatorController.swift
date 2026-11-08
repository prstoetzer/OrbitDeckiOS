import Foundation
import Combine
import SatelliteKit

// ===========================================================================
//  RotatorController.swift — antenna rotator orchestration
//
//  Mirrors RigController: owns the configured rotator + its transport and runs a
//  GCD-timer pointing loop that aims the antenna at the selected satellite. Ports
//  CardSat's pointing behavior: azimuth-range conventions (0–360 / ±180 / 0–450
//  overlap with a lookahead pre-commit), flip mode for overhead passes, alignment
//  offsets, magnetic-vs-true correction, deadband, pre-position lead before AOS,
//  and park on LOS/disconnect.
//
//  Beyond the satellite: Sun/Moon/fixed targets, manual jog/stop, position
//  read-back with stall detection, a self-test and a passive TX/RX monitor
//  (CardSat's rotator manual, self-test and monitor screens).
// ===========================================================================

@MainActor
final class RotatorController: ObservableObject {
    @Published var config = RotatorConfig() {
        // CAT locks onto its engaged satellite from the same AOS lead (see EngagementLock).
        didSet { EngagementLock.aosLeadSec = Double(max(0, config.leadSec)) }
    }
    @Published var connected = false
    @Published var connecting = false
    @Published var statusText = "Not connected"
    @Published var errorText = ""
    @Published var commandedAz: Double = 0      // last commanded TRUE azimuth (pre-mag), in the rotator's range
    @Published var commandedEl: Double = 0
    @Published var flipActive = false           // the current/upcoming pass is flown flipped
    @Published var lastTx = ""                  // live send telemetry for the Home card
    private var txSeq = 0

    /// What the loop points at. Setting it commands the new target at once; anything
    /// but `.satellite` pauses satellite tracking until it is set back.
    @Published var target: RotatorTarget = .satellite {
        didSet {
            holding = false; stalled = false
            lastAz = nil; lastEl = nil                     // bypass the deadband for the new target
            if (target == .satellite) != (oldValue == .satellite) { releaseEngaged() }
            retick()
        }
    }
    /// `stopMotion()` was called: nothing is sent until a target is set again.
    @Published private(set) var holding = false
    /// Bumped by `stopMotion()`. A point command captures it before waiting for the link
    /// and is dropped if a stop came in meanwhile, so an in-flight tick can't undo a stop.
    private var motionGeneration = 0

    // Position read-back (protocols with a position query, on a transport that replies).
    @Published private(set) var actualAz: Double?      // reported azimuth (+ declination if magnetic), comparable to `commandedAz`
    @Published private(set) var actualEl: Double?
    @Published private(set) var readBackError = ""
    @Published private(set) var stalled = false        // commanded away, but the reported position isn't moving
    private var lastPollAt: Date?
    private var pollFailures = 0
    private var sentAz: Double?                        // last mechanical position actually sent (after declination)
    private var sentEl: Double?
    private var progressRef: (az: Double, el: Double)?
    private var lastProgressAt = Date()
    private static let pollIntervalSec = 1.0
    private static let pollBackoffSec = 5.0            // after repeated unanswered queries
    private static let stallSec = 10.0

    /// The satellite the loop is flying. A selection change mid-pass doesn't slew the
    /// antenna away: the engaged satellite is kept and `pendingSwitch` offers the new one.
    struct PendingSwitch: Equatable { let id: UInt; let name: String }
    @Published private(set) var engagedSatelliteID: UInt?
    @Published private(set) var engagedSatelliteName = ""
    @Published private(set) var pendingSwitch: PendingSwitch?
    private var keptForSatID: UInt?                    // "Keep" pressed for this selection
    private var seenAutoEventID: Int?
    private weak var autoSwitch: AutoSwitchController?
    private enum Mode { case idle, tracking, prepositioning, parked }
    private var mode: Mode = .idle

    // Monitor: a bounded trace of every frame sent/received. Nothing is formatted or
    // stored while it's off.
    @Published var monitorEnabled = false
    @Published private(set) var monitorLines: [RotatorMonitorLine] = []
    private var monitorSeq = 0
    private static let monitorCap = 500

    // Self-test
    @Published private(set) var selfTestSteps: [RotatorSelfTestStep] = []
    @Published private(set) var selfTestRunning = false

    /// Serializes transport I/O so a manual command, a stop or a position query never
    /// interleaves with the loop's own send/reply exchange.
    private var ioBusy = false

    /// `commandedAz` as a 0–360° compass heading for display (the ±180° and 0–450°
    /// ranges command values outside 0–360, e.g. −86° or 405°).
    var displayAz: Double {
        let a = wrap360(commandedAz.rounded())
        return a >= 360 ? 0 : a
    }

    /// `actualAz` as a 0–360° compass heading, nil without a read-back.
    var displayActualAz: Double? {
        guard let actualAz else { return nil }
        let a = wrap360(actualAz.rounded())
        return a >= 360 ? 0 : a
    }

    /// Read-back is configured and the protocol/transport can deliver it.
    var readBackActive: Bool { config.readBack && config.proto.supportsReadBack && canReadReplies }

    private weak var store: OrbitStore?
    private var transport: CATTransport?
    private var timer: DispatchSourceTimer?
    private var isTicking = false
    private var lastAz: Double?
    private var lastEl: Double?
    private var lastSendAt: Date?
    private static let keepaliveSec = 2.0
    private var parked = false
    private var wantConnection = false      // operator intent — false after a manual disconnect()
    private var reconnecting = false
    private var az450PreCommit = false
    private var plan: PassPlan?             // the pass being tracked / pre-positioned for
    private var noPlanKey: PlanKey?         // negative cache: no pass found for these inputs…
    private var noPlanUntil: Date?          // …until this time (avoids a 10-day scan every tick)
    private var spidSetEchoes: Bool?        // SPID: does this controller reply to a SET? (nil = not yet known)

    /// The inputs a pass plan (and its flip decision) depends on. A change re-plans.
    private struct PlanKey: Equatable {
        let satID: UInt
        let latitude: Double
        let longitude: Double
        let azOffsetDeg: Int
        let minElevationDeg: Double
        let azRange: RotAzRange
        let flip: Bool
    }

    /// One real pass, keyed by its TRUE AOS (not "now" for a pass already in progress),
    /// with the flip decision made once over the whole pass and held until LOS.
    private struct PassPlan {
        let key: PlanKey
        let aos: Date
        let los: Date
        let aosAzimuth: Double
        let flip: Bool
    }

    private static let configKey = "orbitdeck.rotatorConfig"

    /// `autoSwitch`: its selections are authoritative and retarget even mid-pass.
    func attach(_ store: OrbitStore, autoSwitch: AutoSwitchController? = nil) {
        self.store = store
        self.autoSwitch = autoSwitch
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(RotatorConfig.self, from: data) {
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
        guard config.isConfigured else { errorText = "Configure a rotator first."; return }
        connecting = true; wantConnection = true; errorText = ""; statusText = "Connecting…"; persist()
        let t = makeTransport(); transport = t
        // Reconnect if the link drops unexpectedly (server hiccup, Wi-Fi blip); never on a
        // caller-initiated disconnect.
        t.onDisconnect = { [weak self] in Task { @MainActor in self?.handleDrop() } }
        Task {
            do {
                try await t.connect()
                connected = true; connecting = false; statusText = "Connected"
                lastAz = nil; lastEl = nil; lastSendAt = nil; parked = false; az450PreCommit = false
                plan = nil; noPlanKey = nil; noPlanUntil = nil; spidSetEchoes = nil
                holding = false; stalled = false; actualAz = nil; actualEl = nil; readBackError = ""
                lastPollAt = nil; pollFailures = 0; sentAz = nil; sentEl = nil; progressRef = nil
                releaseEngaged()
                await tick()          // send an initial position immediately
                startLoop()
            } catch {
                connecting = false; connected = false
                errorText = error.localizedDescription; statusText = "Connection failed."
                transport = nil
            }
        }
    }

    func disconnect() {
        timer?.cancel(); timer = nil
        wantConnection = false
        let t = transport; transport = nil
        connected = false; statusText = "Not connected"; flipActive = false
        actualAz = nil; actualEl = nil; stalled = false; pendingSwitch = nil
        let parkFrame = RotatorCodec.point(config.proto, az: Double(config.parkAz), el: Double(config.parkEl),
                                           azimuthOnly: config.azimuthOnly)
        if monitorEnabled, t != nil { monitor(true, parkFrame) }
        Task {
            if let t {
                try? await t.send(parkFrame)
                await t.disconnect()
            }
        }
    }

    /// A live link drop after a good connect: stop the loop and reconnect after a short
    /// backoff so pointing survives a brief server/Wi-Fi blip. Never fires on a
    /// caller-initiated disconnect (which clears `wantConnection` first).
    private func handleDrop() {
        guard connected, wantConnection, !reconnecting else { return }
        reconnecting = true
        connected = false
        timer?.cancel(); timer = nil
        actualAz = nil; actualEl = nil; stalled = false
        statusText = "Connection lost — reconnecting…"
        ODLog.shared.log("rotator link dropped — reconnecting", category: "rotator")
        let old = transport; transport = nil
        Task {
            if let old { await old.disconnect() }
            await Self.gcdDelay(2)
            reconnecting = false
            guard wantConnection, !connected, !connecting else { return }
            connect()
        }
    }

    /// Foreground restore: reconnect if the operator had connected but the link died while
    /// the app was backgrounded/suspended. Called from the scene-phase handler on `.active`.
    func resumeIfNeeded() {
        guard wantConnection, !connected, !connecting, !reconnecting else { return }
        ODLog.shared.log("foreground: restoring dropped rotator connection", category: "rotator")
        connect()
    }

    private func makeTransport() -> CATTransport {
        if config.proto.isNetwork {
            let port = UInt16(max(1, min(65535, config.port)))
            // PstRotator: bind the local source port to dest+1, as CardSat does.
            let localPort: UInt16? = (config.proto == .pstRotator && port < 65535) ? port + 1 : nil
            return RotatorNetworkTransport(host: config.host, port: port,
                                           udp: config.proto == .pstRotator, localPort: localPort)
        }
        let uuid = UUID(uuidString: config.bleIdentifier) ?? UUID()
        return BLESerialTransport(identifier: uuid)
    }

    /// Suspend for `seconds` on a GCD timer (never a MainActor `Task.sleep`).
    private static func gcdDelay(_ seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    // MARK: Pointing loop

    private func startLoop() {
        timer?.cancel()
        let ms = max(200, config.updateMs)
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

    /// Run one tick now (after a target change), waiting out a tick in progress. Not
    /// while a rotctld-server client has paused tracking: it owns the rotator until it
    /// lets go (`serverResumeTracking`).
    private func retick() {
        guard connected, !serverTrackingPaused else { return }
        Task {
            while isTicking { await Self.gcdDelay(0.05) }
            guard connected, !serverTrackingPaused else { return }
            isTicking = true
            await tick()
            isTicking = false
        }
    }

    func tick() async {
        guard connected, let store, !selfTestRunning else { return }
        if !holding {
            switch target {
            case .satellite: await trackSatellite(store)
            case .sun, .moon: await trackBody(store, sun: target == .sun)
            case .fixed(let az, let el): await holdFixed(az: az, el: el)
            }
        }
        await pollPositionIfDue()
    }

    private func trackSatellite(_ store: OrbitStore) async {
        guard let selected = store.selectedSatellite else { return }
        let sat = engagedSatellite(store, selected: selected)
        let observer = store.preferences.observer
        let now = Date()
        guard let look = try? OrbitPredictor.look(sat, observer: observer, at: now) else { return }

        // The pass plan (true AOS/LOS + flip decision) is computed once per real pass and
        // held until LOS, so flip can't toggle mid-pass as the remaining track shrinks.
        let plan = passPlan(sat: sat, observer: observer, look: look, now: now)
        let flipPass = plan?.flip ?? false
        let elMax = flipPass ? 180.0 : 90.0

        if look.elevation >= config.minElevationDeg, look.elevation >= 0 {
            // --- Tracking ---
            parked = false
            // Slew-rate lead: aim where the satellite WILL be after the mechanical lag, so
            // the antenna arrives with it on a fast overhead pass. Gate stays on the current
            // look (visibility); only the aim point looks ahead. 0 = off (unchanged behavior).
            let aim = (config.trackLeadSec > 0
                       ? (try? OrbitPredictor.look(sat, observer: observer, at: now.addingTimeInterval(Double(config.trackLeadSec))))
                       : nil) ?? look
            let (az, el) = mechanical(az: aim.azimuth, el: aim.elevation, flip: flipPass)
            // 450° overlap: pre-commit to the upper turn if a North wrap is imminent.
            if config.azRange == .az450, config.azLookSec > 0, !flipPass,
               let ahead = try? OrbitPredictor.look(sat, observer: observer, at: now.addingTimeInterval(Double(config.azLookSec))) {
                let aheadAz = wrap360(ahead.azimuth + Double(config.azOffsetDeg))
                if wrap360(az) <= 90, aheadAz > 270 { az450PreCommit = true }
            }
            flipActive = flipPass
            mode = .tracking
            await sendTarget(az: normalizeAz(az), el: min(elMax, max(0, el)))
            statusText = "Tracking \(sat.name)"
        } else if config.leadSec > 0, let plan, plan.aos > now,
                  plan.aos.timeIntervalSince(now) <= Double(config.leadSec) {
            // --- Pre-position to the AOS bearing at the horizon (flip held from here) ---
            parked = false; az450PreCommit = false
            let (az, el) = mechanical(az: plan.aosAzimuth, el: 0, flip: flipPass)
            flipActive = flipPass
            mode = .prepositioning
            await sendTarget(az: normalizeAz(az), el: min(elMax, max(0, el)))
            statusText = "Pre-positioning · AOS in \(ODFormat.duration(plan.aos.timeIntervalSince(now)))"
        } else {
            // --- Park --- (resent on the keepalive cadence like any other target)
            az450PreCommit = false
            parked = true
            flipActive = false
            mode = .parked
            await sendTarget(az: normalizeAz(Double(config.parkAz)), el: Double(config.parkEl))
            statusText = "Parked"
        }
    }

    /// Sun or Moon (sun-noise G/T checks, EME). Below the horizon: park or hold, per setting.
    private func trackBody(_ store: OrbitStore, sun: Bool) async {
        let name = sun ? "Sun" : "Moon"
        let look = Self.bodyLook(sun: sun, site: store.preferences.observer, at: Date())
        flipActive = false; az450PreCommit = false
        if look.el >= 0 {
            parked = false
            let (az, el) = mechanical(az: look.az, el: look.el, flip: false)
            await sendTarget(az: normalizeAz(az), el: min(90, max(0, el)))
            statusText = String(format: "Tracking %@ · el %.0f°", name, look.el)
        } else if config.belowHorizon == .park {
            parked = true
            await sendTarget(az: normalizeAz(Double(config.parkAz)), el: Double(config.parkEl))
            statusText = "\(name) below horizon · parked"
        } else {
            statusText = "\(name) below horizon · holding"
        }
    }

    /// A manual az/el (true bearing; alignment offsets applied like any target).
    private func holdFixed(az: Double, el: Double) async {
        parked = false; flipActive = false; az450PreCommit = false
        let elMax = config.flipEnabled ? 180.0 : 90.0
        let (a, e) = mechanical(az: az, el: el, flip: false)
        await sendTarget(az: normalizeAz(a), el: min(elMax, max(0, e)))
        statusText = config.azimuthOnly ? String(format: "Manual · az %.0f°", az)
                                        : String(format: "Manual · az %.0f° el %.0f°", az, el)
    }

    /// Topocentric Sun/Moon az/el. The Moon is corrected for parallax (up to ~1°, which
    /// matters for EME); the Sun's parallax is negligible.
    static func bodyLook(sun: Bool, site: ObserverSite, at date: Date) -> (az: Double, el: Double) {
        if sun {
            let s = FeatureEngine.sunMoon(site: site, at: date)
            return (s.sunAzimuth, s.sunElevation)
        }
        let jd = date.julianDate
        let moon = FeatureEngine.moonSolution(jd)
        let d2r = Double.pi / 180
        let lst = FeatureEngine.gmstRadians(jd) + site.longitude * d2r
        let r = FeatureEngine.earthRadiusKm + site.altitudeMeters / 1000
        let cosLat = cos(site.latitude * d2r)
        let v = Vector(moon.vector.x * moon.distanceKm - r * cosLat * cos(lst),
                       moon.vector.y * moon.distanceKm - r * cosLat * sin(lst),
                       moon.vector.z * moon.distanceKm - r * sin(site.latitude * d2r))
        let look = FeatureEngine.vectorToAltAz(v, site: site, julianDay: jd)
        return (look.azimuth, look.elevation)
    }

    // MARK: Engaged-satellite lock

    /// The satellite to fly this tick. A new selection made while the engaged satellite
    /// is in its locked window (`EngagementLock`: the AOS lead through LOS — the same rule
    /// CAT uses) is offered, not obeyed; automatic switching and the shared "Follow
    /// selection while connected" setting retarget at once. Once the engaged pass ends,
    /// the selection is adopted.
    private func engagedSatellite(_ store: OrbitStore, selected: SatelliteRecord) -> SatelliteRecord {
        var autoPick = false
        if let event = autoSwitch?.lastEvent, event.id != seenAutoEventID {
            seenAutoEventID = event.id
            autoPick = event.norad == selected.id
        }
        if let id = engagedSatelliteID, id != selected.id, !autoPick, !EngagementLock.followSelection,
           let engaged = store.satellites.first(where: { $0.id == id }),
           EngagementLock.holds(engaged, observer: store.preferences.observer) {
            let offer = keptForSatID == selected.id ? nil : PendingSwitch(id: selected.id, name: selected.name)
            if pendingSwitch != offer { pendingSwitch = offer }
            return engaged
        }
        if engagedSatelliteID != selected.id {
            engagedSatelliteID = selected.id; engagedSatelliteName = selected.name; mode = .idle
        }
        if pendingSwitch != nil { pendingSwitch = nil }
        keptForSatID = nil
        return selected
    }

    /// "Switch": point at the newly selected satellite now.
    func switchToPending() {
        guard pendingSwitch != nil else { return }
        releaseEngaged()
        lastAz = nil; lastEl = nil
        retick()
    }

    /// "Keep": stay on the engaged satellite; don't ask again for this selection.
    func keepEngaged() {
        keptForSatID = pendingSwitch?.id
        pendingSwitch = nil
    }

    private func releaseEngaged() {
        engagedSatelliteID = nil; engagedSatelliteName = ""
        pendingSwitch = nil; keptForSatID = nil; mode = .idle
    }

    // MARK: Manual control

    /// Point at a fixed az/el (true bearing) now; satellite tracking pauses until the
    /// target is set back to `.satellite`.
    func pointManually(azimuth: Double, elevation: Double) {
        let elMax = config.flipEnabled ? 180.0 : 90.0
        target = .fixed(azimuth: wrap360(azimuth), elevation: min(elMax, max(0, elevation)))
    }

    /// Jog from the manual target (or, entering manual, from where the antenna is).
    func jog(azimuth dAz: Double = 0, elevation dEl: Double = 0) {
        let base: (az: Double, el: Double)
        if case .fixed(let a, let e) = target { base = (a, e) } else { base = currentTrueBearing() }
        pointManually(azimuth: base.az + dAz, elevation: base.el + dEl)
    }

    /// Go to the park position and hold there (manual).
    func parkNow() {
        pointManually(azimuth: Double(config.parkAz - config.azOffsetDeg),
                      elevation: Double(config.parkEl - config.elOffsetDeg))
    }

    /// Target picker: `.manual` holds the current bearing.
    func setTarget(kind: RotatorTargetKind) {
        switch kind {
        case .satellite: target = .satellite
        case .sun: target = .sun
        case .moon: target = .moon
        case .manual:
            guard target.kind != .manual else { return }
            let b = currentTrueBearing()
            pointManually(azimuth: b.az, elevation: b.el)
        }
    }

    /// Send the protocol's stop command and hold where the antenna is (nothing more is
    /// sent until a target is set). SAEBRTrack and URC have no stop: the rotator
    /// finishes its current move, then holds.
    func stopMotion() {
        let here = currentTrueBearing()
        target = .fixed(azimuth: here.az, elevation: here.el)
        holding = true
        motionGeneration += 1
        let bytes = RotatorCodec.stop(config.proto)
        guard connected else { return }
        statusText = bytes.isEmpty ? "Holding · \(config.proto.label) has no stop command" : "Stopped · holding"
        guard !bytes.isEmpty else { return }
        Task {
            let err = await withLink { () async -> String? in
                guard let t = self.transport else { return CATError.notConnected.localizedDescription }
                do { try await self.tx(t, bytes); return nil } catch { return error.localizedDescription }
            }
            txSeq += 1
            lastTx = "STOP #\(txSeq): \(err ?? "ok")"
        }
    }

    /// Where the antenna points as a true az/el (offsets and flip undone): the read-back
    /// position when there is one, else the last command.
    private func currentTrueBearing() -> (az: Double, el: Double) {
        var a = actualAz ?? commandedAz, e = actualEl ?? commandedEl
        a -= Double(config.azOffsetDeg); e -= Double(config.elOffsetDeg)
        if flipActive { a -= 180; e = 180 - e }
        return (wrap360(a), max(0, e))
    }

    // MARK: Pointing helpers

    /// Satellite look angles → mechanical rotator position: the flip transform first
    /// (az+180°, el = 180°−el), then the alignment offsets, which are mechanical and so
    /// apply the same way whether or not the pass is flipped.
    private func mechanical(az: Double, el: Double, flip: Bool) -> (Double, Double) {
        var a = az, e = el
        if flip { a += 180; e = 180 - e }
        return (a + Double(config.azOffsetDeg), e + Double(config.elOffsetDeg))
    }

    /// Send when the target moves beyond the deadband. On a fire-and-forget UDP
    /// path (PstRotator) also resend on the keepalive cadence to feed the receiver
    /// and self-heal a datagram dropped during path setup. Reliable transports
    /// (rotctld/TCP, BLE serial) send only on movement: re-issuing an unchanged
    /// SET buys nothing and can make some controllers restart an in-progress move.
    private func sendTarget(az: Double, el: Double) async {
        let db = Double(config.deadbandDeg)
        // An azimuth-only controller ignores elevation, so elevation changes alone
        // never warrant a resend.
        let elMoved = !config.azimuthOnly && abs(el - (lastEl ?? 0)) >= db
        let moved = lastAz == nil || abs(az - (lastAz ?? 0)) >= db || elMoved
        let keepalive = (config.proto == .pstRotator)
            && (lastSendAt == nil || Date().timeIntervalSince(lastSendAt ?? .distantPast) >= Self.keepaliveSec)
        if moved || keepalive { await command(az: az, el: el) }
    }

    private func command(az: Double, el: Double) async {
        let sendAz = az - declination
        let generation = motionGeneration
        let err = await sendPoint(az: sendAz, el: el, generation: generation)
        // Stopped while this point waited for the link: it was dropped, not sent.
        guard generation == motionGeneration else { return }
        commandedAz = az; commandedEl = el          // show the true bearing
        txSeq += 1
        lastTx = err == nil ? "TX #\(txSeq): ok" : "TX #\(txSeq): \(err ?? "")"
        lastAz = az; lastEl = el; lastSendAt = Date()
        sentAz = sendAz; sentEl = max(0, el)
    }

    /// Send a mechanical position (offsets/declination already applied). Returns nil on
    /// success, else the error text. With a `generation` (the pointing loop's sends), the
    /// point is dropped — returning nil, sending nothing — if `stopMotion()` ran while it
    /// waited for the link.
    private func sendPoint(az: Double, el: Double, generation: Int? = nil) async -> String? {
        await withLink { () async -> String? in
            if let generation, generation != self.motionGeneration { return nil }
            if self.config.proto == .spid, self.canReadReplies { return await self.spidCommand(az: az, el: el) }
            guard let t = self.transport else { return CATError.notConnected.localizedDescription }
            var err: String?
            for datagram in RotatorCodec.pointDatagrams(self.config.proto, az: az, el: el, azimuthOnly: self.config.azimuthOnly) {
                do { try await self.tx(t, datagram) }
                catch { err = error.localizedDescription }
            }
            return err
        }
    }

    /// Declination subtracted from commanded bearings when sending magnetic (else 0).
    private var declination: Double {
        guard config.magCorrect, let store else { return 0 }
        return Self.magneticDeclinationApprox(latitude: store.preferences.observer.latitude,
                                              longitude: store.preferences.observer.longitude)
    }

    /// Run `body` with exclusive use of the transport.
    private func withLink<T>(_ body: () async -> T) async -> T {
        while ioBusy { await Self.gcdDelay(0.02) }
        ioBusy = true
        defer { ioBusy = false }
        return await body()
    }

    /// Send, tapping the monitor.
    private func tx(_ t: CATTransport, _ bytes: [UInt8]) async throws {
        if monitorEnabled { monitor(true, bytes) }
        try await t.send(bytes)
    }

    /// Read, tapping the monitor.
    private func rx(_ t: CATTransport, maxWait: TimeInterval) async -> [UInt8] {
        let bytes = await t.readAvailable(maxWait: maxWait)
        if monitorEnabled, !bytes.isEmpty { monitor(false, bytes) }
        return bytes
    }

    /// Whether the transport delivers replies (BLE serial, TCP). PstRotator's UDP path is
    /// one-way from the loop's point of view, so it stays fire-and-forget.
    private var canReadReplies: Bool { config.proto.isSerial || config.proto.usesTCP }

    /// SPID Rot2Prog SET with reply validation. MD-01/02 answer a SET with the 12-byte
    /// position frame; an original Rot2Prog doesn't, so when no reply arrives the link is
    /// verified with a STATUS query instead (and later SETs skip the wait for an echo).
    /// A garbled, short or missing reply resends the SET up to 3 times with a short GCD
    /// delay, then logs. Returns nil on success, else the error text for the Home card.
    private func spidCommand(az: Double, el: Double) async -> String? {
        guard let t = transport else { return CATError.notConnected.localizedDescription }
        let set = RotatorCodec.point(.spid, az: az, el: el)
        let retries = 3
        var lastError = "no valid SPID reply"
        for attempt in 0...retries {
            if attempt > 0 { await Self.gcdDelay(0.15) }
            _ = await rx(t, maxWait: 0)                      // drop stale bytes
            do { try await tx(t, set) }
            catch { lastError = error.localizedDescription; continue }
            if spidSetEchoes != false {
                let (frame, got) = await readSpidFrame(t, timeout: 0.4)
                if frame { spidSetEchoes = true; return nil }
                if got { lastError = "garbled SPID reply"; continue }   // something came back, but not a frame
            }
            // No echo to the SET: confirm the controller is alive with a STATUS query.
            do { try await tx(t, RotatorCodec.spidStatus) }
            catch { lastError = error.localizedDescription; continue }
            let (frame, got) = await readSpidFrame(t, timeout: 0.6)
            if frame {
                if spidSetEchoes == nil { spidSetEchoes = false }
                return nil
            }
            lastError = got ? "garbled SPID reply" : "no SPID reply"
        }
        ODLog.shared.log("SPID: \(lastError) after \(retries) retries (az \(Int(az.rounded())) el \(Int(el.rounded())))",
                         category: "rotator")
        return "\(lastError) after \(retries) retries"
    }

    /// Accumulate reply bytes (BLE can split a frame across notifications) until a valid
    /// 12-byte Rot2Prog frame is present or the timeout passes. Returns whether a valid
    /// frame arrived and whether any bytes arrived at all.
    private func readSpidFrame(_ t: CATTransport, timeout: TimeInterval) async -> (Bool, Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var buf: [UInt8] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            buf += await rx(t, maxWait: remaining)
            if RotatorCodec.spidReply(buf) != nil { return (true, true) }
            if buf.count > 64 { break }                      // a stream of junk, not a frame
        }
        return (false, !buf.isEmpty)
    }

    /// Azimuth to the configured axis convention (+ 450° overlap pre-commit).
    private func normalizeAz(_ azIn: Double) -> Double {
        let az = wrap360(azIn)
        switch config.azRange {
        case .az360: return az
        case .az180: return az > 180 ? az - 360 : az
        case .az450: return (az <= 90 && az450PreCommit) ? az + 360 : az
        }
    }

    private func wrap360(_ deg: Double) -> Double {
        var a = deg.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    /// Smallest angle between two azimuths (0…180°).
    private func angularDiff(_ a: Double, _ b: Double) -> Double {
        let d = wrap360(a - b)
        return min(d, 360 - d)
    }

    // MARK: Position read-back

    /// Poll the position at a modest rate (≥ 1 s; every 5 s after repeated silence).
    private func pollPositionIfDue() async {
        guard readBackActive else { return }
        let base = max(Self.pollIntervalSec, Double(config.updateMs) / 1000)
        let interval = pollFailures >= 3 ? Self.pollBackoffSec : base
        if let last = lastPollAt, Date().timeIntervalSince(last) < interval { return }
        lastPollAt = Date()
        if let p = await readPosition() {
            pollFailures = 0
            actualAz = p.az + declination; actualEl = p.el
            if !readBackError.isEmpty { readBackError = "" }
            evaluateStall(p)
        } else {
            pollFailures += 1
            if pollFailures == 3 {
                actualAz = nil; actualEl = nil; stalled = false
                readBackError = "No position reply"
                ODLog.shared.log("rotator: no position reply to \(config.proto.label) query", category: "rotator")
            }
        }
    }

    /// One position query, in the controller's own (mechanical) units. Text replies
    /// are accumulated until their terminator (BLE splits frames); at the timeout a
    /// best-effort parse of whatever arrived.
    func readPosition(timeout: TimeInterval = 0.6) async -> (az: Double, el: Double)? {
        let proto = config.proto, azOnly = config.azimuthOnly
        guard canReadReplies, let query = RotatorCodec.positionQuery(proto, azimuthOnly: azOnly) else { return nil }
        return await withLink { () async -> (az: Double, el: Double)? in
            guard let t = self.transport else { return nil }
            _ = await self.rx(t, maxWait: 0)        // drop stale replies (e.g. rotctld's RPRT 0 to a SET)
            do { try await self.tx(t, query) } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            var buf: [UInt8] = []
            while deadline.timeIntervalSinceNow > 0 {
                buf += await self.rx(t, maxWait: deadline.timeIntervalSinceNow)
                if let p = RotatorCodec.completePosition(proto, buf, azimuthOnly: azOnly) { return p }
                if buf.count > 256 { break }
            }
            return RotatorCodec.parsePosition(proto, buf, azimuthOnly: azOnly)
        }
    }

    /// Stall: the reported position is away from the last command but hasn't moved a
    /// degree in `stallSec`. Arriving (within tolerance) or any movement resets the clock.
    private func evaluateStall(_ p: (az: Double, el: Double)) {
        let now = Date()
        guard let sAz = sentAz, let sEl = sentEl, !holding else {
            progressRef = p; lastProgressAt = now; setStalled(false); return
        }
        let tol = max(4, Double(config.deadbandDeg) + 1)
        let azErr = angularDiff(p.az, sAz)
        let elErr = config.azimuthOnly ? 0 : abs(p.el - sEl)
        if azErr <= tol, elErr <= tol {
            progressRef = p; lastProgressAt = now; setStalled(false); return
        }
        guard let ref = progressRef else { progressRef = p; lastProgressAt = now; return }
        if angularDiff(p.az, ref.az) >= 1 || (!config.azimuthOnly && abs(p.el - ref.el) >= 1) {
            progressRef = p; lastProgressAt = now; setStalled(false); return
        }
        if now.timeIntervalSince(lastProgressAt) >= Self.stallSec { setStalled(true) }
    }

    private func setStalled(_ v: Bool) {
        guard v != stalled else { return }
        stalled = v
        if v {
            ODLog.shared.log(String(format: "rotator stalled: commanded az %.0f el %.0f, reported az %.0f el %.0f",
                                    sentAz ?? 0, sentEl ?? 0, progressRef?.az ?? 0, progressRef?.el ?? 0),
                             category: "rotator")
        }
    }

    // MARK: Monitor

    private func monitor(_ outgoing: Bool, _ bytes: [UInt8]) {
        monitorSeq += 1
        monitorLines.append(RotatorMonitorLine(id: monitorSeq, date: Date(), outgoing: outgoing,
                                               text: Self.render(bytes, binary: config.proto == .spid)))
        if monitorLines.count > Self.monitorCap { monitorLines.removeFirst(monitorLines.count - Self.monitorCap) }
    }

    func clearMonitor() { monitorLines.removeAll() }

    /// The trace as plain text for Copy / Share.
    var monitorText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return monitorLines.map { "\(f.string(from: $0.date)) \($0.outgoing ? ">" : "<") \($0.text)" }
            .joined(separator: "\n")
    }

    /// Text protocols as ASCII (CR/LF shown as \r \n); binary (SPID) or unprintable as hex.
    static func render(_ bytes: [UInt8], binary: Bool) -> String {
        let printable = bytes.allSatisfy { (0x20...0x7E).contains($0) || $0 == 0x0D || $0 == 0x0A }
        if binary || !printable { return bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
        return String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: Self-test

    /// Readiness, position read, a null move (command path, no motion), a +5° azimuth
    /// exercise slew with movement detection, and a return to start. The pointing loop
    /// is paused while it runs and re-commands its target afterwards.
    func runSelfTest() {
        guard !selfTestRunning else { return }
        selfTestRunning = true
        selfTestSteps = []
        Task {
            while isTicking { await Self.gcdDelay(0.05) }
            await performSelfTest()
            selfTestRunning = false
            lastAz = nil; lastEl = nil
            retick()
        }
    }

    private func beginStep(_ title: String) -> Int {
        let id = selfTestSteps.count
        selfTestSteps.append(RotatorSelfTestStep(id: id, title: title))
        return id
    }

    private func endStep(_ id: Int, _ result: RotatorSelfTestStep.Result, _ detail: String, hint: String = "") {
        selfTestSteps[id].result = result
        selfTestSteps[id].detail = detail
        selfTestSteps[id].hint = hint
    }

    private func performSelfTest() async {
        let proto = config.proto
        var s = beginStep("Link ready")
        guard connected, transport != nil else {
            endStep(s, .fail, "Not connected (\(proto.label)).",
                    hint: "Connect from the Home rotator card, then run the test again.")
            return
        }
        let link = proto.isNetwork ? "\(proto.usesTCP ? "TCP" : "UDP") \(config.host):\(config.port)"
                                   : "BLE serial · \(config.bleName)"
        endStep(s, .pass, "\(proto.label) · \(link)")

        s = beginStep("Read position")
        guard proto.supportsReadBack, canReadReplies else {
            endStep(s, .info, "\(proto.label) has no position query OrbitDeck can use, so movement can't be verified.",
                    hint: proto == .pstRotator ? "PstRotator reports its position on another UDP port; watch PstRotator's own display."
                                               : "Watch the antenna while it's pointed from the Home card or Manual control.")
            s = beginStep("Command path")
            let az = sentAz ?? Double(config.parkAz), el = sentEl ?? Double(config.parkEl)
            if let err = await sendPoint(az: az, el: el) {
                endStep(s, .fail, "Send failed: \(err)", hint: "Check the host/port or BLE adapter.")
            } else {
                endStep(s, .info, String(format: "Re-sent the current position (az %.0f° el %.0f°); delivery can't be confirmed without a reply.", az, el))
            }
            return
        }
        guard let start = await readPosition(timeout: 1.0) else {
            endStep(s, .fail, "No valid position reply.",
                    hint: proto.isSerial ? "Check the protocol, the controller's baud rate (set on the BLE adapter), TX/RX wiring, and that the controller is in computer/remote mode."
                                         : "Check that the server is running, the host/port are right, and (rotctld) the rotator model it was started with.")
            return
        }
        let azOnly = config.azimuthOnly
        func fmt(_ p: (az: Double, el: Double)) -> String {
            azOnly ? String(format: "az %.1f°", p.az) : String(format: "az %.1f° el %.1f°", p.az, p.el)
        }
        endStep(s, .pass, fmt(start))

        s = beginStep("Null move (no motion expected)")
        if let err = await sendPoint(az: start.az, el: start.el) {
            endStep(s, .fail, "Command failed: \(err)", hint: "The controller rejected or didn't acknowledge the move command.")
            return
        }
        await Self.gcdDelay(1.5)
        if let p = await readPosition(timeout: 1.0) {
            let d = max(angularDiff(p.az, start.az), azOnly ? 0 : abs(p.el - start.el))
            if d <= 2 {
                endStep(s, .pass, String(format: "Command accepted; position held (Δ %.1f°).", d))
            } else {
                endStep(s, .fail, String(format: "Moved %.1f° on a null move (now %@).", d, fmt(p)),
                        hint: "The controller may report in different units than it accepts. Check the azimuth range setting (0–360 / ±180 / 0–450) matches the controller.")
                return
            }
        } else {
            endStep(s, .fail, "No position reply after the command.",
                    hint: "The command may have upset the controller. Check the protocol choice (e.g. GS-232A vs Easycomm).")
            return
        }

        s = beginStep("Exercise slew +5° azimuth — the antenna moves")
        var to = start.az + 5
        let azMax: Double = switch config.azRange { case .az360: 360; case .az180: 180; case .az450: 450 }
        if to > azMax { to = start.az - 5 }
        if let err = await sendPoint(az: to, el: start.el) {
            endStep(s, .fail, "Command failed: \(err)")
            return
        }
        var moved = 0.0, reached = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            await Self.gcdDelay(1)
            if let p = await readPosition() {
                moved = angularDiff(p.az, start.az)
                if angularDiff(p.az, to) <= 1.5 { reached = true; break }
            }
        }
        if reached {
            endStep(s, .pass, String(format: "Reached az %.1f°.", to))
        } else if moved >= 1 {
            endStep(s, .pass, String(format: "Movement detected: %.1f° in 8 s (target az %.1f°).", moved, to),
                    hint: "A slow rotator or a controller with its own deadband may not finish a 5° step in 8 s.")
        } else {
            endStep(s, .fail, "No azimuth movement detected in 8 s.",
                    hint: "Check rotator power, the control cable, limit switches, and that the controller is in computer/remote mode. Some controllers ignore moves smaller than their own deadband.")
        }

        s = beginStep("Return to start")
        if let err = await sendPoint(az: start.az, el: start.el) {
            endStep(s, .fail, "Command failed: \(err)")
            return
        }
        let back = Date().addingTimeInterval(10)
        var home = false
        while Date() < back {
            await Self.gcdDelay(1)
            if let p = await readPosition(), angularDiff(p.az, start.az) <= 1.5 { home = true; break }
        }
        if home { endStep(s, .pass, "Back at \(fmt(start)).") }
        else { endStep(s, .info, "Commanded back to \(fmt(start)); not confirmed within 10 s.") }
    }

    // MARK: Pass plan

    /// The pass to fly: the one in progress (with its TRUE AOS), else the next one that
    /// reaches the tracking threshold. Cached until its LOS so the flip decision is made
    /// once per pass and can't change as the remaining track shrinks after TCA.
    private func passPlan(sat: SatelliteRecord, observer: ObserverSite, look: LiveLook, now: Date) -> PassPlan? {
        // Location rounded to ~1 km so a device-location observer's small GPS updates
        // don't re-plan (and re-search the pass) every tick.
        let key = PlanKey(satID: sat.id, latitude: (observer.latitude * 100).rounded() / 100,
                          longitude: (observer.longitude * 100).rounded() / 100,
                          azOffsetDeg: config.azOffsetDeg, minElevationDeg: config.minElevationDeg,
                          azRange: config.azRange, flip: config.flipEnabled)
        // Hold the plan a little past LOS so a marginal end-of-pass sample doesn't re-plan.
        if let p = plan, p.key == key, now <= p.los.addingTimeInterval(30) { return p }
        if noPlanKey == key, let until = noPlanUntil, now < until { return nil }

        let minEl = max(0, config.minElevationDeg)
        var found: PredictedPass?
        if look.elevation >= 0, let current = passInProgress(sat: sat, observer: observer, now: now) {
            if current.maxElevation >= minEl {
                found = current
            } else {
                // The pass overhead now never reaches the threshold: plan for the next one.
                found = try? OrbitPredictor.predictPasses(sat, observer: observer, from: current.los.addingTimeInterval(60),
                                                          minElevation: minEl, maxCount: 1).first
            }
        } else {
            found = try? OrbitPredictor.predictPasses(sat, observer: observer, from: now,
                                                      minElevation: minEl, maxCount: 1).first
        }
        guard let pass = found else {
            plan = nil; noPlanKey = key; noPlanUntil = now.addingTimeInterval(60)
            return nil
        }
        let flip = config.flipEnabled && crossesSeam(pass, sat: sat, observer: observer)
        let p = PassPlan(key: key, aos: pass.aos, los: pass.los, aosAzimuth: pass.aosAzimuth, flip: flip)
        plan = p; noPlanKey = nil; noPlanUntil = nil
        if flip {
            ODLog.shared.log("flip mode on for \(sat.name) pass AOS \(pass.aos)", category: "rotator")
        }
        return p
    }

    /// The pass the satellite is in right now, with its real AOS. `predictPasses` from
    /// "now" would start an in-progress pass at now, so walk back to a time below the
    /// horizon and predict forward from there.
    private func passInProgress(sat: SatelliteRecord, observer: ObserverSite, now: Date) -> PredictedPass? {
        var t = now
        var below: Date?
        for _ in 0..<720 {                                   // up to 12 h back, 60 s steps
            t = t.addingTimeInterval(-60)
            guard let l = try? OrbitPredictor.look(sat, observer: observer, at: t) else { break }
            if l.elevation < 0 { below = t; break }
        }
        if let below,
           let p = try? OrbitPredictor.predictPasses(sat, observer: observer, from: below, minElevation: 0, maxCount: 1).first,
           p.aos <= now.addingTimeInterval(60), p.los >= now.addingTimeInterval(-60) {
            return p
        }
        // Up for the whole look-back (GEO, long HEO apogee): the window from now is
        // stable enough, as it is cached until its LOS.
        return try? OrbitPredictor.predictPasses(sat, observer: observer, from: now, minElevation: 0, maxCount: 1).first
    }

    /// Does this pass cross the rotator's azimuth seam (0/360° — or 180° on a ±180°
    /// rotator), needing flip? Sampled over the whole pass from its true AOS.
    private func crossesSeam(_ pass: PredictedPass, sat: SatelliteRecord, observer: ObserverSite) -> Bool {
        let step = max(5, pass.duration / 1500)
        guard let path = try? OrbitPredictor.skyPath(sat, observer: observer, pass: pass, step: step) else { return false }
        var prev: Double?
        for point in path {
            var az = wrap360(point.azimuth + Double(config.azOffsetDeg))
            if config.azRange == .az180, az > 180 { az -= 360 }
            if let p = prev, abs(az - p) > 180 { return true }
            prev = az
        }
        return false
    }

    /// Dipole approximation of magnetic declination (matches DeepParityEngine).
    static func magneticDeclinationApprox(latitude: Double, longitude: Double) -> Double {
        let d2r = Double.pi / 180
        let lat = latitude * d2r
        let poleLat = 80.7 * d2r
        let dlon = (-72.7 - longitude) * d2r
        let y = sin(dlon) * cos(poleLat)
        let x = cos(lat) * sin(poleLat) - sin(lat) * cos(poleLat) * cos(dlon)
        var bearing = atan2(y, x) * 180 / .pi
        while bearing > 180 { bearing -= 360 }
        while bearing <= -180 { bearing += 360 }
        return bearing
    }
}

// MARK: - rotctld server bridge

/// Entry points for the built-in Hamlib rotctld server (`RotctldServer`, in
/// RotatorNetwork.swift). Like CardSat, positions from an external client are sent to
/// the rotator verbatim — no alignment offsets or magnetic correction, since the client
/// owns its own calibration — and a set-position pauses OrbitDeck's own tracking so the
/// two don't fight. `serverResumeTracking()` hands control back.
extension RotatorController {
    /// True while connected with OrbitDeck's pointing loop stopped by an external client.
    var serverTrackingPaused: Bool { connected && timer == nil && !reconnecting }

    /// The configured azimuth range and maximum elevation, for `\dump_state`.
    var serverLimits: (minAz: Double, maxAz: Double, maxEl: Double) {
        let el = config.flipEnabled ? 180.0 : 90.0
        switch config.azRange {
        case .az360: return (0, 360, el)
        case .az180: return (-180, 180, el)
        case .az450: return (0, 450, el)
        }
    }

    /// Last commanded position (mechanical, as sent).
    var serverPosition: (az: Double, el: Double) { (commandedAz, commandedEl) }

    /// Pause tracking and point at `az`/`el`. False when no rotator is connected.
    func serverPoint(az: Double, el: Double) async -> Bool {
        guard connected, transport != nil else { return false }
        await serverPauseTracking()
        var a = az
        switch config.azRange {
        case .az360: a = wrap360(a)
        case .az180: a = wrap360(a); if a > 180 { a -= 360 }
        case .az450: if a < 0 || a > 450 { a = wrap360(a) }
        }
        let e = min(serverLimits.maxEl, max(0, el))
        return await serverSend(az: a, el: e)
    }

    /// Pause tracking and send the protocol's stop command (if it has one).
    func serverStop() async -> Bool {
        guard connected, transport != nil else { return false }
        await serverPauseTracking()
        let bytes = RotatorCodec.stop(config.proto)
        guard !bytes.isEmpty else { return true }
        return await withLink { () async -> Bool in
            guard let t = self.transport else { return false }
            do { try await self.tx(t, bytes); return true } catch { return false }
        }
    }

    /// Pause tracking and move to the configured park position.
    func serverPark() async -> Bool {
        guard connected, transport != nil else { return false }
        await serverPauseTracking()
        return await serverSend(az: Double(config.parkAz), el: Double(config.parkEl))
    }

    /// Restart OrbitDeck's own pointing loop after external control.
    func serverResumeTracking() {
        guard connected, timer == nil, !reconnecting else { return }
        lastAz = nil; lastEl = nil; lastSendAt = nil
        startLoop()
        statusText = "Tracking resumed"
        ODLog.shared.log("rotctld server: external control ended — OrbitDeck tracking resumed", category: "rotator")
    }

    private func serverPauseTracking() async {
        guard timer != nil else { return }
        timer?.cancel(); timer = nil
        // Let an in-flight tick finish so its send can't land after ours.
        var waited = 0.0
        while isTicking, waited < 3 { await Self.gcdDelay(0.02); waited += 0.02 }
        flipActive = false
        statusText = "External control (rotctld server)"
        ODLog.shared.log("rotctld server: external client is pointing — OrbitDeck tracking paused", category: "rotator")
    }

    private func serverSend(az: Double, el: Double) async -> Bool {
        commandedAz = az; commandedEl = el
        txSeq += 1
        // Through the link lock and the monitor, like OrbitDeck's own sends.
        let errText = await sendPoint(az: az, el: el) ?? ""
        let ok = errText.isEmpty
        lastTx = ok ? "TX #\(txSeq): ok (rotctld server)" : "TX #\(txSeq): \(errText)"
        lastAz = az; lastEl = el; lastSendAt = Date()
        return ok
    }
}
