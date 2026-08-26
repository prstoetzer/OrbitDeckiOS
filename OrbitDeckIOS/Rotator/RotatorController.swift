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
    @Published var commandedAz: Double = 0      // last commanded TRUE azimuth (pre-mag)
    @Published var commandedEl: Double = 0
    @Published var lastTx = ""                  // live send telemetry for the Home card
    private var txSeq = 0

    private weak var store: OrbitStore?
    private var transport: CATTransport?
    private var timer: DispatchSourceTimer?
    private var isTicking = false
    private var lastAz: Double?
    private var lastEl: Double?
    private var lastSendAt: Date?
    private static let keepaliveSec = 2.0
    private var parked = false
    private var az450PreCommit = false
    private var flipCachePassID: Date?
    private var flipCacheValue = false

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
        connecting = true; errorText = ""; statusText = "Connecting…"; persist()
        let t = makeTransport(); transport = t
        Task {
            do {
                try await t.connect()
                connected = true; connecting = false; statusText = "Connected"
                lastAz = nil; lastEl = nil; lastSendAt = nil; parked = false; az450PreCommit = false; flipCachePassID = nil
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
        let t = transport; transport = nil
        connected = false; statusText = "Not connected"
        let proto = config.proto, parkAz = Double(config.parkAz), parkEl = Double(config.parkEl)
        Task {
            if let t {
                try? await t.send(RotatorCodec.point(proto, az: parkAz, el: parkEl))
                await t.disconnect()
            }
        }
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

        let pass = try? OrbitPredictor.predictPasses(sat, observer: observer,
                                                     minElevation: max(0, config.minElevationDeg), maxCount: 1).first
        let flipPass = config.flip ? needsFlip(pass, sat: sat, observer: observer) : false

        if look.elevation >= config.minElevationDeg, look.elevation >= 0 {
            // --- Tracking ---
            parked = false
            var az = look.azimuth + Double(config.azOffsetDeg)
            var el = look.elevation + Double(config.elOffsetDeg)
            if config.flip, flipPass { az += 180; el = 180 - el }
            // 450° overlap: pre-commit to the upper turn if a North wrap is imminent.
            if config.azRange == .az450, config.azLookSec > 0, !(config.flip && flipPass),
               let ahead = try? OrbitPredictor.look(sat, observer: observer, at: now.addingTimeInterval(Double(config.azLookSec))) {
                let aheadAz = wrap360(ahead.azimuth + Double(config.azOffsetDeg))
                if wrap360(az) <= 90, aheadAz > 270 { az450PreCommit = true }
            }
            let cmdAz = normalizeAz(az)
            let elMax = (config.flip && flipPass) ? 180.0 : 90.0
            let cmdEl = min(elMax, max(0, el))
            await sendTarget(az: cmdAz, el: cmdEl)
            statusText = "Tracking \(sat.name)"
        } else if config.leadSec > 0, let pass, pass.aos > now,
                  pass.aos.timeIntervalSince(now) <= Double(config.leadSec) {
            // --- Pre-position to the AOS bearing at the horizon ---
            parked = false; az450PreCommit = false
            var az = pass.aosAzimuth + Double(config.azOffsetDeg)
            var el = Double(config.elOffsetDeg)
            if config.flip, flipPass { az += 180; el = 180 - el }
            let cmdAz = normalizeAz(az)
            let elMax = (config.flip && flipPass) ? 180.0 : 90.0
            let cmdEl = min(elMax, max(0, el))
            await sendTarget(az: cmdAz, el: cmdEl)
            statusText = "Pre-positioning · AOS in \(ODFormat.duration(pass.aos.timeIntervalSince(now)))"
        } else {
            // --- Park --- (resent on the keepalive cadence like any other target)
            az450PreCommit = false
            parked = true
            await sendTarget(az: normalizeAz(Double(config.parkAz)), el: Double(config.parkEl))
            statusText = "Parked"
        }
    }

    // MARK: Pointing helpers

    /// Send when the target moves beyond the deadband. On a fire-and-forget UDP
    /// path (PstRotator) also resend on the keepalive cadence to feed the receiver
    /// and self-heal a datagram dropped during path setup. Reliable transports
    /// (rotctld/TCP, BLE serial) send only on movement: re-issuing an unchanged
    /// SET buys nothing and can make some controllers restart an in-progress move.
    private func sendTarget(az: Double, el: Double) async {
        let db = Double(config.deadbandDeg)
        let moved = lastAz == nil || abs(az - (lastAz ?? 0)) >= db || abs(el - (lastEl ?? 0)) >= db
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
        for datagram in RotatorCodec.pointDatagrams(config.proto, az: sendAz, el: el) {
            do { try await transport?.send(datagram) }
            catch { ok = false; errText = error.localizedDescription }
        }
        lastTx = ok ? "TX #\(txSeq): ok" : "TX #\(txSeq): \(errText)"
        lastAz = az; lastEl = el; lastSendAt = Date()
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

    /// Does this pass cross the 0/360° azimuth seam (needing flip)? Sampled once
    /// per pass and cached.
    private func needsFlip(_ pass: PredictedPass?, sat: SatelliteRecord, observer: ObserverSite) -> Bool {
        guard let pass else { return false }
        if flipCachePassID == pass.id { return flipCacheValue }
        var result = false
        var prev: Double?
        let n = 24
        for i in 0...n {
            let t = pass.aos.addingTimeInterval(pass.duration * Double(i) / Double(n))
            guard let l = try? OrbitPredictor.look(sat, observer: observer, at: t) else { continue }
            let az = wrap360(l.azimuth + Double(config.azOffsetDeg))
            if let p = prev, abs(az - p) > 180 { result = true; break }
            prev = az
        }
        flipCachePassID = pass.id; flipCacheValue = result
        return result
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
