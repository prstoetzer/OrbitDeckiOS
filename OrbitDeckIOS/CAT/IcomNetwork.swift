import Foundation
import Network

// ===========================================================================
//  IcomNetwork.swift — Icom RS-BA1 (network CAT) UDP transport
//
//  Byte-exact port of CardSat's icomnet.cpp / ICOM_LAN_PROTOCOL.md. Opens the
//  Control (port) and Serial/CI-V (port+1) UDP streams — never Audio — runs the
//  bootstrap → login → auth → ConnInfo → serial-open state machine, keeps the
//  link alive with idle/ping packets, and tunnels raw CI-V frames.
//
//  *** The full network path is untestable without a real IC-9700/IC-705 and is
//  flagged for on-hardware verification. *** The one item CardSat calls out is
//  whether the radio tolerates the audio stream never being opened; the ConnInfo
//  field offsets are the least-certain part of the wire format.
// ===========================================================================

final class IcomNetworkTransport: NSObject, CATTransport, @unchecked Sendable {
    private let host: String
    private let basePort: UInt16
    private let username: String
    private let password: String
    private let modelName: String
    private let queue = DispatchQueue(label: "org.orbitdeck.cat.icomnet")

    private var control: RSStream?
    private var serial: RSStream?
    private var authID = [UInt8](repeating: 0, count: 6)
    private var a8replyID = [UInt8](repeating: 0, count: 16)
    private var authOK = false
    private var connectCont: CheckedContinuation<Void, Error>?
    private var connected = false
    private var reauthTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private var rxCIV: [UInt8] = []

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    init(host: String, port: UInt16, username: String, password: String, modelName: String) {
        self.host = host
        self.basePort = port
        self.username = username
        self.password = password
        self.modelName = modelName
        super.init()
    }

    // MARK: CATTransport

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectCont = cont
                self.queue.asyncAfter(deadline: .now() + 25) { [weak self] in
                    guard let self, let c = self.connectCont else { return }
                    self.connectCont = nil; c.resume(throwing: CATError.connectTimeout)
                }
                self.startControl()
            }
        }
    }

    func disconnect() async {
        queue.sync {
            self.teardown()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected, let serial else { throw CATError.notConnected }
        queue.async { serial.sendCIV(bytes) }
    }

    func readAvailable(maxWait: TimeInterval) async -> [UInt8] {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            if lock.withLock({ !rxCIV.isEmpty }) { break }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return lock.withLock { let out = rxCIV; rxCIV.removeAll(); return out }
    }

    // MARK: State machine

    private func finishConnect(_ result: Result<Void, Error>) {
        guard let c = connectCont else { return }
        connectCont = nil
        switch result {
        case .success: connected = true; c.resume()
        case .failure(let e): teardown(); c.resume(throwing: e)
        }
    }

    private func teardown() {
        reauthTimer?.cancel(); reauthTimer = nil
        control?.close(); serial?.close()
        control = nil; serial = nil
        connected = false; authOK = false
    }

    private func startControl() {
        let s = RSStream(host: host, port: basePort, queue: queue)
        control = s
        s.onReady = { [weak self] in self?.control?.bootstrap() }
        s.onBootstrapped = { [weak self] in self?.sendLogin() }
        s.onPacket = { [weak self] pkt in self?.handleControl(pkt) }
        s.onError = { [weak self] e in self?.finishConnect(.failure(e)) }
        s.start()
    }

    private func sendLogin() {
        guard let control else { return }
        var p = [UInt8](repeating: 0, count: 128)
        p[0] = 0x80
        writeBE(&p, 8, control.localSID)
        writeBE(&p, 12, control.remoteSID)
        p[19] = 0x70; p[20] = 0x01
        let inner = control.nextInnerSeq()
        p[23] = UInt8(inner & 0xFF); p[24] = UInt8((inner >> 8) & 0xFF)
        p[26] = UInt8.random(in: 0...255); p[27] = UInt8.random(in: 0...255)
        let user = Self.passcode(username), pass = Self.passcode(password)
        for i in 0..<16 { p[64 + i] = user[i]; p[80 + i] = pass[i] }
        let app = Array("OrbitDeck".utf8)
        for (i, b) in app.prefix(16).enumerated() { p[96 + i] = b }
        control.trackedSend(p)
    }

    private func handleControl(_ r: [UInt8]) {
        guard let control else { return }
        // Login reply (0x60)
        if r.count >= 96, r[0] == 0x60, r[4] == 0x00 {
            if r.count >= 52, r[48] == 0xFF, r[49] == 0xFF, r[50] == 0xFF, r[51] == 0xFE {
                finishConnect(.failure(CATError.network("hams.at radio rejected the network username/password.")))
                return
            }
            for i in 0..<6 { authID[i] = r[26 + i] }
            sendAuth(magic: 0x02); sendAuth(magic: 0x05)
            return
        }
        // Capabilities (0xa8)
        if r.count >= 82, r[0] == 0xA8 {
            for i in 0..<16 { a8replyID[i] = r[66 + i] }
            maybeSendConnInfo()
            return
        }
        // Auth reply (0x40)
        if r.count >= 64, r[0] == 0x40 {
            if r[21] == 0x05 { authOK = true; maybeSendConnInfo() }
            return
        }
        // ConnInfo reply (0x90)
        if r.count >= 144, r[0] == 0x90, r[96] == 0x01 {
            control.remoteSID = readBE(r, 8)
            control.localSID = readBE(r, 12)
            for i in 0..<6 { authID[i] = r[26 + i] }
            startSerial()
            startReauth()
            return
        }
    }

    private func sendAuth(magic: UInt8) {
        guard let control else { return }
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = 0x40
        writeBE(&p, 8, control.localSID); writeBE(&p, 12, control.remoteSID)
        p[19] = 0x30; p[20] = 0x01; p[21] = magic
        let inner = control.nextInnerSeq()
        p[23] = UInt8(inner & 0xFF); p[24] = UInt8((inner >> 8) & 0xFF)
        for i in 0..<6 { p[26 + i] = authID[i] }
        control.trackedSend(p)
    }

    private var connInfoSent = false
    private func maybeSendConnInfo() {
        guard authOK, a8replyID.contains(where: { $0 != 0 }), !connInfoSent, let control else { return }
        connInfoSent = true
        var p = [UInt8](repeating: 0, count: 144)
        p[0] = 0x90
        writeBE(&p, 8, control.localSID); writeBE(&p, 12, control.remoteSID)
        p[19] = 0x80; p[20] = 0x01; p[21] = 0x03
        let inner = control.nextInnerSeq()
        p[23] = UInt8(inner & 0xFF); p[24] = UInt8((inner >> 8) & 0xFF)
        for i in 0..<6 { p[26 + i] = authID[i] }
        for i in 0..<16 { p[32 + i] = a8replyID[i] }
        let name = Array(modelName.utf8)
        for (i, b) in name.prefix(15).enumerated() { p[64 + i] = b }   // model name, plaintext
        let user = Self.passcode(username)
        for i in 0..<16 { p[96 + i] = user[i] }
        // Exact ConnInfo trailer from CardSat (icomnet.cpp sendConnInfo): sample-rate
        // words, then the serial (basePort+1) and audio (basePort+2) ports and a
        // tx-buffer-length word — all big-endian at these specific offsets.
        let sr: UInt16 = 16000
        let serP = basePort + 1, audP = basePort + 2, txb: UInt16 = 100
        p[112] = 0x01; p[113] = 0x01; p[114] = 0x04; p[115] = 0x04
        p[118] = UInt8(sr >> 8);   p[119] = UInt8(sr & 0xFF)
        p[122] = UInt8(sr >> 8);   p[123] = UInt8(sr & 0xFF)
        p[126] = UInt8(serP >> 8); p[127] = UInt8(serP & 0xFF)
        p[130] = UInt8(audP >> 8); p[131] = UInt8(audP & 0xFF)
        p[134] = UInt8(txb >> 8);  p[135] = UInt8(txb & 0xFF); p[136] = 0x01
        control.trackedSend(p)
    }

    private func startSerial() {
        let s = RSStream(host: host, port: basePort + 1, queue: queue)
        serial = s
        s.onReady = { [weak self] in self?.serial?.bootstrap() }
        s.onBootstrapped = { [weak self] in self?.serial?.openSerial { [weak self] in self?.finishConnect(.success(())) } }
        s.onCIV = { [weak self] frame in
            guard let self else { return }
            self.lock.lock(); self.rxCIV.append(contentsOf: frame); self.lock.unlock()
        }
        s.onError = { [weak self] e in self?.finishConnect(.failure(e)) }
        s.start()
    }

    private func startReauth() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.sendAuth(magic: 0x05) }
        t.resume()
        reauthTimer = t
    }

    // MARK: passcode() cipher (functional constant; required verbatim for interop)

    /// ASCII 32..126 → obfuscated byte (index p-32).
    private static let sequence: [UInt8] = [
        0x47,0x5d,0x4c,0x42,0x66,0x20,0x23,0x46,0x4e,0x57, // 32-41
        0x45,0x3d,0x67,0x76,0x60,0x41,0x62,0x39,0x59,0x2d, // 42-51
        0x68,0x7e,0x7c,0x65,0x7d,0x49,0x29,0x72,0x73,0x78, // 52-61
        0x21,0x6e,0x5a,0x5e,0x4a,0x3e,0x71,0x2c,0x2a,0x54, // 62-71
        0x3c,0x3a,0x63,0x4f,0x43,0x75,0x27,0x79,0x5b,0x35, // 72-81
        0x70,0x48,0x6b,0x56,0x6f,0x34,0x32,0x6c,0x30,0x61, // 82-91
        0x6d,0x7b,0x2f,0x4b,0x64,0x38,0x2b,0x2e,0x50,0x40, // 92-101
        0x3f,0x55,0x33,0x37,0x25,0x77,0x24,0x26,0x74,0x6a, // 102-111
        0x28,0x53,0x4d,0x69,0x22,0x5c,0x44,0x31,0x36,0x58, // 112-121
        0x3b,0x7a,0x51,0x5f,0x52,                           // 122-126
    ]

    static func passcode(_ s: String) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        let chars = Array(s.utf8)
        for i in 0..<min(16, chars.count) {
            var p = Int(chars[i]) + i
            if p > 126 { p = 32 + (p % 127) }
            if p >= 32, p <= 126 { out[i] = sequence[p - 32] }
        }
        return out
    }

    // MARK: byte helpers

    private func writeBE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8((v >> 24) & 0xFF); b[off+1] = UInt8((v >> 16) & 0xFF)
        b[off+2] = UInt8((v >> 8) & 0xFF); b[off+3] = UInt8(v & 0xFF)
    }
    private func readBE(_ b: [UInt8], _ off: Int) -> UInt32 {
        (UInt32(b[off]) << 24) | (UInt32(b[off+1]) << 16) | (UInt32(b[off+2]) << 8) | UInt32(b[off+3])
    }
}

// MARK: - RSStream: one RS-BA1 UDP stream (control or serial)

/// A single RS-BA1 UDP stream. All access is serialized on the shared queue, so
/// the type is `@unchecked Sendable`.
final class RSStream: @unchecked Sendable {
    let host: String
    let port: UInt16
    let queue: DispatchQueue
    private var conn: NWConnection?

    var localSID: UInt32 = UInt32.random(in: 1...UInt32.max)
    var remoteSID: UInt32 = 0
    private var trackedSeq: UInt16 = 1
    private var pingSeq: UInt16 = 0
    private var pingCounter: UInt32 = 0
    private var civSeq: UInt16 = 0
    private var innerSeq: UInt16 = 0
    private var retransmit: [UInt16: [UInt8]] = [:]
    private var lastTrackedSend = Date()

    private var keepalive: DispatchSourceTimer?
    private var bootstrapTimer: DispatchSourceTimer?
    private var bootstrapStage = 0

    var onReady: (() -> Void)?
    var onBootstrapped: (() -> Void)?
    var onPacket: (([UInt8]) -> Void)?
    var onCIV: (([UInt8]) -> Void)?
    var onError: ((Error) -> Void)?

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host; self.port = port; self.queue = queue
    }

    func start() {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                     port: NWEndpoint.Port(rawValue: port)!)
        let c = NWConnection(to: ep, using: .udp)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receiveLoop(); self.onReady?()
            case .failed(let e), .waiting(let e): self.onError?(CATError.network(e.localizedDescription))
            default: break
            }
        }
        c.start(queue: queue)
    }

    func close() {
        keepalive?.cancel(); keepalive = nil
        bootstrapTimer?.cancel(); bootstrapTimer = nil
        // Best-effort disconnect (pkt5 ×2).
        let p = header(len: 16, type: 0x0005, seq: 0)
        rawSend(p); rawSend(p)
        conn?.cancel(); conn = nil
    }

    private func receiveLoop() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle([UInt8](data)) }
            if error == nil { self.receiveLoop() }
        }
    }

    // MARK: bootstrap

    func bootstrap() {
        bootstrapStage = 1
        sendAreYouThere()
        // Retry until "i am here" arrives. iOS silently drops the first datagrams
        // while it shows the Local Network permission prompt, so a single send
        // (as before) would time out; CardSat likewise retries the connect.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.5, repeating: 1.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.bootstrapStage == 1 { self.sendAreYouThere() }
            else { self.bootstrapTimer?.cancel(); self.bootstrapTimer = nil }
        }
        t.resume()
        bootstrapTimer = t
    }

    private func sendAreYouThere() {
        let p = header(len: 16, type: 0x0003, seq: 0)      // are-you-there ×2
        rawSend(p); rawSend(p)
    }

    private func handle(_ r: [UInt8]) {
        guard r.count >= 16 else { return }
        // Ping: len==21 && bytes[1..6] == 00 00 00 07 00
        if r.count == 21, r[1] == 0, r[2] == 0, r[3] == 0, r[4] == 0x07, r[5] == 0 {
            replyPing(r); return
        }
        let type = UInt16(r[4]) | (UInt16(r[5]) << 8)
        // I-am-here (0x0004) → learn remoteSID, send are-you-ready
        if type == 0x0004, bootstrapStage == 1 {
            remoteSID = (UInt32(r[8]) << 24) | (UInt32(r[9]) << 16) | (UInt32(r[10]) << 8) | UInt32(r[11])
            bootstrapStage = 2
            bootstrapTimer?.cancel(); bootstrapTimer = nil
            let p = header(len: 16, type: 0x0006, seq: 1)   // are-you-ready ×2
            rawSend(p); rawSend(p)
            return
        }
        // Ready (0x0006) → bootstrap done
        if type == 0x0006, bootstrapStage == 2 {
            bootstrapStage = 3
            startKeepalive()
            onBootstrapped?()
            return
        }
        // Retransmit request (single 0x0001)
        if type == 0x0001, r.count >= 16 {
            let seq = UInt16(r[6]) | (UInt16(r[7]) << 8)
            if let pkt = retransmit[seq] { rawSend(pkt); rawSend(pkt) }
            return
        }
        // Serial CI-V data: len>=22 && r[16]==0xc1 && r[0]-0x15==r[17]
        if r.count >= 22, r[16] == 0xC1, Int(r[0]) - 0x15 == Int(r[17]) {
            let n = Int(r[17])
            if r.count >= 21 + n { onCIV?(Array(r[21..<(21 + n)])) }
            return
        }
        onPacket?(r)
    }

    private func replyPing(_ r: [UInt8]) {
        var p = r
        // swap local/remote SID, dir = reply
        for i in 0..<4 { let t = p[8+i]; p[8+i] = p[12+i]; p[12+i] = t }
        p[16] = 0x01
        rawSend(p)
    }

    // MARK: serial open + CI-V

    func openSerial(onOpen: @escaping () -> Void) {
        civSeq &+= 1
        var p = header(len: 22, type: 0x0000, seq: nextTracked())
        p[16] = 0xC0; p[17] = 0x01; p[18] = 0x00
        p[19] = UInt8(civSeq >> 8); p[20] = UInt8(civSeq & 0xFF)
        p[21] = 0x05                                       // open
        store(p); rawSend(p)
        // Like CardSat, the link is considered up once the serial-open is sent
        // (the radio does not send a distinct open reply).
        onOpen()
    }

    func sendCIV(_ frame: [UInt8]) {
        let n = frame.count
        // 21-byte header carrying a len field of 21+n, then the CI-V frame appended.
        var p = header(len: 21, type: 0x0000, seq: nextTracked(), lenField: 21 + n)
        p[16] = 0xC1; p[17] = UInt8(n); p[18] = 0x00
        civSeq &+= 1
        p[19] = UInt8(civSeq >> 8); p[20] = UInt8(civSeq & 0xFF)
        p.append(contentsOf: frame)
        store(p); rawSend(p)
    }

    // MARK: tracked send / keepalive

    func nextInnerSeq() -> UInt16 { let s = innerSeq; innerSeq &+= 1; return s }

    func trackedSend(_ packet: [UInt8]) {
        var p = packet
        let seq = nextTracked()
        p[6] = UInt8(seq & 0xFF); p[7] = UInt8((seq >> 8) & 0xFF)
        store(p, seq: seq); rawSend(p)
    }

    private func nextTracked() -> UInt16 { let s = trackedSeq; trackedSeq &+= 1; return s }
    private func store(_ p: [UInt8], seq: UInt16? = nil) {
        let s = seq ?? (UInt16(p[6]) | (UInt16(p[7]) << 8))
        retransmit[s] = p
        if retransmit.count > 64 { retransmit.removeValue(forKey: retransmit.keys.min() ?? s) }
        lastTrackedSend = Date()
    }

    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // idle pkt0 (backs off to 1 s after quiet), plus a ping
            let quiet = Date().timeIntervalSince(self.lastTrackedSend) > 1.0
            if !quiet || Int(Date().timeIntervalSinceReferenceDate * 10) % 10 == 0 {
                var idle = self.header(len: 16, type: 0x0000, seq: self.nextTracked())
                self.rawSend(idle); _ = idle
            }
            self.sendPing()
        }
        t.resume()
        keepalive = t
    }

    private func sendPing() {
        pingSeq &+= 1; pingCounter &+= 1
        var p = [UInt8](repeating: 0, count: 21)
        p[0] = 0x15
        p[4] = 0x07
        p[6] = UInt8(pingSeq & 0xFF); p[7] = UInt8((pingSeq >> 8) & 0xFF)
        writeBE(&p, 8, localSID); writeBE(&p, 12, remoteSID)
        p[16] = 0x00                                       // request
        p[17] = UInt8(pingCounter & 0xFF); p[18] = UInt8((pingCounter >> 8) & 0xFF)
        p[19] = UInt8((pingCounter >> 16) & 0xFF); p[20] = UInt8((pingCounter >> 24) & 0xFF)
        rawSend(p)
    }

    // MARK: raw send / header

    private func header(len: Int, type: UInt16, seq: UInt16, lenField: Int? = nil) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: len)
        let lf = lenField ?? len
        p[0] = UInt8(lf & 0xFF); p[1] = UInt8((lf >> 8) & 0xFF)
        p[4] = UInt8(type & 0xFF); p[5] = UInt8((type >> 8) & 0xFF)
        p[6] = UInt8(seq & 0xFF); p[7] = UInt8((seq >> 8) & 0xFF)
        writeBE(&p, 8, localSID); writeBE(&p, 12, remoteSID)
        return p
    }

    private func rawSend(_ p: [UInt8]) {
        conn?.send(content: Data(p), completion: .contentProcessed { _ in })
    }

    private func writeBE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8((v >> 24) & 0xFF); b[off+1] = UInt8((v >> 16) & 0xFF)
        b[off+2] = UInt8((v >> 8) & 0xFF); b[off+3] = UInt8(v & 0xFF)
    }
}
