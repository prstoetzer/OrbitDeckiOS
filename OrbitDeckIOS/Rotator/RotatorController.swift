import Foundation
import Combine

// ===========================================================================
//  RotatorController.swift — antenna rotator orchestration
//
//  Mirrors RigController: owns the configured rotator + its transport and runs a
//  GCD-timer pointing loop that aims the antenna at the selected satellite. Ports
//  CardSat's pointing behavior: azimuth-range conventions (0–360 / ±180 / 0–450
//  overlap with a lookahead pre-commit), flip mode for overhead passes, alignment
//  offsets, magnetic-vs-true correction, deadband, pre-position lead before AOS,
//  and park on LOS/disconnect.
// ===========================================================================

@MainActor
final class RotatorController: ObservableObject {
    @Published var config = RotatorConfig()
    @Published var connected = false
    @Published var connecting = false
    @Published var statusText = "Not connected"
    @Published var errorText = ""
    @Published var commandedAz: Double = 0      // last commanded TRUE azimuth (pre-mag), in the rotator's range
    @Published var commandedEl: Double = 0
    @Published var flipActive = false           // the current/upcoming pass is flown flipped
    @Published var lastTx = ""                  // live send telemetry for the Home card
    private var txSeq = 0

    /// `commandedAz` as a 0–360° compass heading for display (the ±180° and 0–450°
    /// ranges command values outside 0–360, e.g. −86° or 405°).
    var displayAz: Double {
        let a = wrap360(commandedAz.rounded())
        return a >= 360 ? 0 : a
    }

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

    func attach(_ store: OrbitStore) {
        self.store = store
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
        let proto = config.proto, parkAz = Double(config.parkAz), parkEl = Double(config.parkEl)
        let azOnly = config.azimuthOnly
        Task {
            if let t {
                try? await t.send(RotatorCodec.point(proto, az: parkAz, el: parkEl, azimuthOnly: azOnly))
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

    func tick() async {
        guard connected, let store, let sat = store.selectedSatellite else { return }
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
            await sendTarget(az: normalizeAz(az), el: min(elMax, max(0, el)))
            statusText = "Tracking \(sat.name)"
        } else if config.leadSec > 0, let plan, plan.aos > now,
                  plan.aos.timeIntervalSince(now) <= Double(config.leadSec) {
            // --- Pre-position to the AOS bearing at the horizon (flip held from here) ---
            parked = false; az450PreCommit = false
            let (az, el) = mechanical(az: plan.aosAzimuth, el: 0, flip: flipPass)
            flipActive = flipPass
            await sendTarget(az: normalizeAz(az), el: min(elMax, max(0, el)))
            statusText = "Pre-positioning · AOS in \(ODFormat.duration(plan.aos.timeIntervalSince(now)))"
        } else {
            // --- Park --- (resent on the keepalive cadence like any other target)
            az450PreCommit = false
            parked = true
            flipActive = false
            await sendTarget(az: normalizeAz(Double(config.parkAz)), el: Double(config.parkEl))
            statusText = "Parked"
        }
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
        commandedAz = az; commandedEl = el          // show the true bearing
        var sendAz = az
        if config.magCorrect, let store {
            sendAz -= Self.magneticDeclinationApprox(latitude: store.preferences.observer.latitude,
                                                     longitude: store.preferences.observer.longitude)
        }
        txSeq += 1
        var ok = true; var errText = ""
        if config.proto == .spid, canReadReplies {
            errText = await spidCommand(az: sendAz, el: el) ?? ""
            ok = errText.isEmpty
        } else {
            for datagram in RotatorCodec.pointDatagrams(config.proto, az: sendAz, el: el, azimuthOnly: config.azimuthOnly) {
                do { try await transport?.send(datagram) }
                catch { ok = false; errText = error.localizedDescription }
            }
        }
        lastTx = ok ? "TX #\(txSeq): ok" : "TX #\(txSeq): \(errText)"
        lastAz = az; lastEl = el; lastSendAt = Date()
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
            _ = await t.readAvailable(maxWait: 0)            // drop stale bytes
            do { try await t.send(set) }
            catch { lastError = error.localizedDescription; continue }
            if spidSetEchoes != false {
                let (frame, got) = await readSpidFrame(t, timeout: 0.4)
                if frame { spidSetEchoes = true; return nil }
                if got { lastError = "garbled SPID reply"; continue }   // something came back, but not a frame
            }
            // No echo to the SET: confirm the controller is alive with a STATUS query.
            do { try await t.send(RotatorCodec.spidStatus) }
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
            buf += await t.readAvailable(maxWait: remaining)
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
