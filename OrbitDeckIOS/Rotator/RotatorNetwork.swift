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
