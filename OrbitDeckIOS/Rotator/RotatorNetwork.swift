import Foundation
import Network

// ===========================================================================
//  RotatorNetwork.swift — TCP (rotctld) and UDP (PstRotator) transports
//
//  Both conform to the CAT `CATTransport` protocol, so the rotator controller
//  reuses the same send/read plumbing. Serial rotators reuse CAT's
//  `BLESerialTransport`; these cover the network protocols.
// ===========================================================================

/// Shared base: a single NWConnection (TCP or UDP) with byte send + queue-polled
/// read. Thread-safety is hand-managed on a private queue.
final class RotatorNetworkTransport: NSObject, CATTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let udp: Bool
    private let localPort: UInt16?          // bind source port (PstRotator: dest+1)
    private let queue = DispatchQueue(label: "org.orbitdeck.rot.net")
    private var conn: NWConnection?

    private let lock = NSLock()
    private var rxBuffer: [UInt8] = []
    private var lastRxNanos: UInt64 = 0
    private var connectCont: CheckedContinuation<Void, Error>?
    private var connected = false

    var onDisconnect: (@Sendable () -> Void)?

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    init(host: String, port: UInt16, udp: Bool, localPort: UInt16? = nil) {
        self.host = host; self.port = port; self.udp = udp; self.localPort = localPort
        super.init()
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectCont = cont
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, let c = self.connectCont else { return }
                    self.connectCont = nil
                    self.conn?.cancel()
                    c.resume(throwing: CATError.connectTimeout)
                }
                let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(self.host),
                                             port: NWEndpoint.Port(rawValue: self.port) ?? 4533)
                let params: NWParameters = self.udp ? .udp : .tcp
                // Bind the local source port (PstRotator sends feedback to dest+1 and
                // CardSat binds it), matching the reference implementation.
                if self.udp, let lp = self.localPort, let lport = NWEndpoint.Port(rawValue: lp) {
                    params.allowLocalEndpointReuse = true
                    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: lport)
                }
                let c = NWConnection(to: ep, using: params)
                self.conn = c
                c.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lock.lock(); self.connected = true; self.lock.unlock()
                        self.receiveLoop()
                        if let cc = self.connectCont { self.connectCont = nil; cc.resume() }
                    case .failed(let e), .waiting(let e):
                        if let cc = self.connectCont { self.connectCont = nil; cc.resume(throwing: CATError.network(e.localizedDescription)) }
                        else {
                            // Live drop after connect (not a caller-initiated disconnect,
                            // which cancels the connection and nils it first).
                            let wasConnected = self.lock.withLock { let w = self.connected; self.connected = false; return w }
                            if wasConnected { self.onDisconnect?() }
                        }
                    default: break
                    }
                }
                c.start(queue: self.queue)
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.lock.lock(); self.connected = false; self.lock.unlock()
                self.conn?.cancel(); self.conn = nil
                cont.resume()
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected, let conn else { throw CATError.notConnected }
        // Await the send completion so a real NWError surfaces (instead of being
        // silently dropped) — the controller shows it on the Home card.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                conn.send(content: Data(bytes), completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: CATError.network(error.localizedDescription)) }
                    else { cont.resume() }
                })
            }
        }
    }

    func readAvailable(maxWait: TimeInterval) async -> [UInt8] {
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            queue.async {
                let start = DispatchTime.now().uptimeNanoseconds
                let cap = UInt64(maxWait * 1_000_000_000)
                func poll() {
                    self.lock.lock()
                    let has = !self.rxBuffer.isEmpty
                    let quiet = DispatchTime.now().uptimeNanoseconds &- self.lastRxNanos > 80_000_000
                    self.lock.unlock()
                    if (has && quiet) || (DispatchTime.now().uptimeNanoseconds &- start) > cap {
                        let out = self.lock.withLock { let o = self.rxBuffer; self.rxBuffer.removeAll(); return o }
                        cont.resume(returning: out)
                    } else {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { poll() }
                    }
                }
                poll()
            }
        }
    }

    private func receiveLoop() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.rxBuffer.append(contentsOf: data)
                self.lastRxNanos = DispatchTime.now().uptimeNanoseconds
                self.lock.unlock()
            }
            if error == nil { self.receiveLoop() }
        }
    }
}

// MARK: - rotctld server

import UIKit

/// Built-in Hamlib rotctld server: lets a LAN client (Gpredict, …) drive whichever
/// rotator OrbitDeck is connected to, like CardSat's. A set-position, stop or park pauses
/// OrbitDeck's own tracking (the client owns pointing, verbatim — no OrbitDeck offsets or
/// magnetic correction); tracking resumes when the last controlling client disconnects,
/// sends `q`, or the operator taps Resume. `p` reports the last commanded position.
/// Transport and line framing are the shared `HamlibLineServer` (CATTransport.swift).
@MainActor
final class RotctldServer: ObservableObject {
    static let shared = RotctldServer()
    static let defaultPort = 4533
    private static let enabledKey = "orbitdeck.rotctldServer.enabled"
    private static let portKey = "orbitdeck.rotctldServer.port"

    @Published private(set) var enabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var listening = false
    @Published private(set) var errorText: String?
    @Published private(set) var clientCount = 0
    @Published private(set) var lastCommand = ""
    @Published private(set) var externalControl = false

    private weak var rotator: RotatorController?
    private var core: HamlibLineServer!
    private var clientAddress: [Int: String] = [:]
    private var controllers = Set<Int>()
    private var lastCommandAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private static let shortNames: [Character: String] = [
        "p": "get_pos", "P": "set_pos", "S": "stop", "K": "park",
        "_": "get_info", "q": "quit", "Q": "quit",
    ]

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Self.enabledKey)
        let p = d.integer(forKey: Self.portKey)
        port = (1024...65535).contains(p) ? p : Self.defaultPort
        core = HamlibLineServer(name: "rotctld", handler: { [weak self] id, line in
            guard let self else { return .init(text: "RPRT -\(HamlibProtocol.eIO)\n", close: false) }
            return await self.handle(id, line)
        }, onEvent: { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        })
    }

    /// Called once at launch; starts the server if it was left enabled.
    func attach(_ rotator: RotatorController) {
        self.rotator = rotator
        if observers.isEmpty {
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.enabled == true { self?.core.ensureRunning() } }
            })
            observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.core.stop() }
            })
        }
        if enabled { core.start(port: UInt16(port)) }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { core.start(port: UInt16(port)) } else { core.stop(); releaseAll() }
    }

    func setPort(_ p: Int) {
        let p = min(65535, max(1024, p))
        guard p != port else { return }
        port = p
        UserDefaults.standard.set(p, forKey: Self.portKey)
        if enabled { releaseAll(); core.start(port: UInt16(p)) }
    }

    /// Operator override: hand pointing back to OrbitDeck's tracking now.
    func resumeTracking() { releaseAll() }

    private func apply(_ event: HamlibLineServer.Event) {
        switch event {
        case .state(let l, let e, let n):
            listening = l; errorText = e; clientCount = n
        case .clientAdded(let id, let address):
            clientAddress[id] = address
        case .clientGone(let id):
            endClient(id)
            clientAddress.removeValue(forKey: id)
        }
    }

    private func beginControl(_ id: Int) {
        if controllers.insert(id).inserted {
            ODLog.shared.log("rotctld server: \(clientAddress[id] ?? "client") is controlling the rotator", category: "rotator")
        }
        externalControl = true
    }

    private func endClient(_ id: Int) {
        guard controllers.remove(id) != nil else { return }
        if controllers.isEmpty { releaseAll() }
    }

    private func releaseAll() {
        let had = externalControl
        controllers.removeAll()
        externalControl = false
        if had { rotator?.serverResumeTracking() }
    }

    private func handle(_ id: Int, _ line: String) async -> HamlibLineServer.Reply {
        guard let cmd = HamlibProtocol.parse(line, shortNames: Self.shortNames) else { return .init(text: "", close: false) }
        let now = Date()
        if cmd.name != "get_pos" || now.timeIntervalSince(lastCommandAt) > 1 {
            lastCommandAt = now
            lastCommand = "\(clientAddress[id] ?? "?"): \(line.prefix(60))"
        }
        return HamlibProtocol.reply(cmd, await execute(id, cmd))
    }

    /// A number from a client, accepting a decimal comma (Gpredict in some locales).
    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    private func execute(_ id: Int, _ cmd: HamlibCommand) async -> HamlibResult {
        switch cmd.name {
        case "dump_state":
            // Protocol 0: version, model (2 = NET rotctl), then the az/el limits.
            let lim = rotator?.serverLimits ?? (minAz: 0, maxAz: 360, maxEl: 90)
            return .raw(String(format: "0\n2\n%.6f\n%.6f\n%.6f\n%.6f\n", lim.minAz, lim.maxAz, 0.0, lim.maxEl))
        case "get_info": return .values([("Info", "OrbitDeck")])
        case "quit":
            endClient(id)
            return .quit
        case "get_pos":
            guard let rot = rotator, rot.connected else { return .error(HamlibProtocol.eIO) }
            let p = rot.serverPosition
            return .values([("Azimuth", String(format: "%.6f", p.az)), ("Elevation", String(format: "%.6f", p.el))])
        case "set_pos":
            guard cmd.args.count >= 2, let az = Self.number(cmd.args[0]), let el = Self.number(cmd.args[1]),
                  az.isFinite, el.isFinite, (-360...720).contains(az), (-90...180).contains(el) else {
                return .error(HamlibProtocol.eInval)
            }
            guard let rot = rotator, rot.connected else { return .error(HamlibProtocol.eIO) }
            beginControl(id)
            return await rot.serverPoint(az: az, el: el) ? .ok : .error(HamlibProtocol.eIO)
        case "stop":
            guard let rot = rotator, rot.connected else { return .error(HamlibProtocol.eIO) }
            beginControl(id)
            return await rot.serverStop() ? .ok : .error(HamlibProtocol.eIO)
        case "park":
            guard let rot = rotator, rot.connected else { return .error(HamlibProtocol.eIO) }
            beginControl(id)
            return await rot.serverPark() ? .ok : .error(HamlibProtocol.eIO)
        default:
            return .error(HamlibProtocol.eNotImplemented)
        }
    }
}
