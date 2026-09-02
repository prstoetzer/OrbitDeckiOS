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

/// How far the RS-BA1 handshake got. On a connect timeout we turn the furthest stage
/// reached into an actionable message — most 9700-vs-705 failures are environmental
/// (reachability / Network Control off / a session already open), not byte bugs, and a
/// single "timed out" hid where it stalled.
enum IcomConnectStage: Int, Comparable {
    case socket = 0          // UDP socket opened, are-you-there sent
    case controlUp           // got i-am-here + ready, login sent
    case loginAccepted       // login reply OK, auth sent
    case authAccepted        // auth reply OK
    case connInfoSent        // ConnInfo request sent
    case connInfoAccepted    // ConnInfo accepted, serial stream starting
    case serialUp            // serial opened → connected

    static func < (a: IcomConnectStage, b: IcomConnectStage) -> Bool { a.rawValue < b.rawValue }

    /// What to tell the operator if the handshake stalled at (i.e. never advanced past) this stage.
    var timeoutDiagnostic: String {
        switch self {
        case .socket:
            return "No reply from the radio. Check it's reachable on this network (the IC-9700 uses its wired Ethernet jack — put it on the same subnet as your Wi-Fi), Network Control is ON, and the IP/port are correct."
        case .controlUp:
            return "The radio answered but did not accept the login. Check the network username/password (a User1 login with Network Control enabled)."
        case .loginAccepted, .authAccepted:
            return "The radio accepted the login but not the connection — it may already have an active network session. Close RS-BA1 Remote Utility / wfview or power-cycle the radio, then retry."
        case .connInfoSent, .connInfoAccepted:
            return "The connection was set up but the CI-V serial stream did not open. Power-cycle the radio and retry."
        case .serialUp:
            return "Connected."
        }
    }
}

final class IcomNetworkTransport: NSObject, CATTransport, @unchecked Sendable {
    private let host: String
    private let basePort: UInt16
    private let username: String
    private let password: String
    private let modelName: String
    private let queue = DispatchQueue(label: "org.orbitdeck.cat.icomnet")

    /// Furthest handshake stage reached (for a stage-aware timeout message + logging).
    private var stage: IcomConnectStage = .socket
    private func advance(to s: IcomConnectStage) {
        guard s > stage || s == .socket else { return }
        stage = s
        ODLog.shared.log("icom-net stage → \(s) (\(host):\(basePort))", category: "cat")
    }

    private var control: RSStream?
    private var serial: RSStream?
    private var authID = [UInt8](repeating: 0, count: 6)
    private var a8replyID = [UInt8](repeating: 0, count: 16)
    private var authOK = false
    private var connectCont: CheckedContinuation<Void, Error>?
    private var connected = false
    private var reauthTimer: DispatchSourceTimer?
    var onDisconnect: (@Sendable () -> Void)?

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
                self.stage = .socket
                self.queue.asyncAfter(deadline: .now() + 25) { [weak self] in
                    guard let self, let c = self.connectCont else { return }
                    self.connectCont = nil
                    let msg = self.stage.timeoutDiagnostic
                    ODLog.shared.log("icom-net connect TIMEOUT at stage \(self.stage): \(msg)", category: "cat")
                    self.teardown()          // close sockets + cancel timers on timeout
                    c.resume(throwing: CATError.network(msg))
                }
                self.startControl()
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { self.teardown(); cont.resume() }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected, let serial else { throw CATError.notConnected }
        queue.async { serial.sendCIV(bytes) }
    }

    func readAvailable(maxWait: TimeInterval) async -> [UInt8] {
        // Poll on the network queue (GCD timing) rather than a MainActor
        // Task.sleep loop, which can stall the UI on this device. A CI-V reply
        // arrives as one datagram, so resume as soon as any bytes are present.
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            queue.async {
                let start = DispatchTime.now().uptimeNanoseconds
                let cap = UInt64(maxWait * 1_000_000_000)
                func poll() {
                    let has = self.lock.withLock { !self.rxCIV.isEmpty }
                    if has || (DispatchTime.now().uptimeNanoseconds &- start) > cap {
                        let out = self.lock.withLock { let o = self.rxCIV; self.rxCIV.removeAll(); return o }
                        cont.resume(returning: out)
                    } else {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { poll() }
                    }
                }
                poll()
            }
        }
    }

    // MARK: Audio stream (EXPERIMENTAL — RS-BA1 audio, unverified)
    //
    // CardSat never opens the audio stream, so this has no validated reference; the
    // packet layout is clean-roomed from the public kappanhang/wfview format
    // (16-bit signed LE PCM at the negotiated 16 kHz, payload at offset 24). It
    // reuses the same session (this stream does its own are-you-there bootstrap on
    // basePort+2, which the radio associates with the session advertised in
    // ConnInfo). Flagged for on-hardware verification against a real IC-9700/705.

    private var audio: RSStream?
    private var onAudioPCM: (([Int16]) -> Void)?
    // RX audio-stream diagnostics (throttled). The RS-BA1 audio path is unverified on
    // hardware, so these tell us whether the radio is actually sending RX audio, how fast,
    // and in what packet shape — turning "No RX audio this slot" into a concrete cause.
    // All touched only on `queue`.
    private var audioPktCount = 0
    private var audioSampleCount = 0
    private var audioSmallCount = 0
    private var audioLastLog = Date()
    private var audioLoggedFirst = false

    /// Sample rate negotiated in ConnInfo.
    var audioSampleRate: Double { 16_000 }

    /// Open the audio stream and deliver received PCM (16-bit signed) blocks.
    func startAudio(onPCM: @escaping ([Int16]) -> Void) {
        queue.async {
            guard self.connected, self.audio == nil else { return }
            self.onAudioPCM = onPCM
            self.audioPktCount = 0; self.audioSampleCount = 0; self.audioSmallCount = 0
            self.audioLoggedFirst = false; self.audioLastLog = Date()
            ODLog.shared.log("icom-net audio: opening stream on port \(self.basePort + 2)", category: "cat")
            let a = RSStream(host: self.host, port: self.basePort + 2, queue: self.queue)
            self.audio = a
            a.onReady = { [weak a] in a?.bootstrap() }
            a.onBootstrapped = { ODLog.shared.log("icom-net audio: stream bootstrapped — awaiting RX audio packets", category: "cat") }
            a.onPacket = { [weak self] pkt in self?.handleAudio(pkt) }
            a.onError = { e in ODLog.shared.log("icom-net audio socket error: \(e.localizedDescription)", category: "cat") }
            a.start()
        }
    }

    func stopAudio() {
        queue.async { self.audio?.close(); self.audio = nil; self.onAudioPCM = nil }
    }

    /// Send a block of PCM (16-bit signed) as a TX audio datagram.
    func sendAudioPCM(_ pcm: [Int16]) {
        queue.async { self.audio?.sendAudio(pcm) }
    }

    private func handleAudio(_ r: [UInt8]) {
        // One-time dump of the first packet's header so a log reveals the radio's audio
        // packet shape/codec (we assume 16-bit signed LE PCM starting at offset 24).
        if !audioLoggedFirst, r.count >= 24 {
            audioLoggedFirst = true
            let head = r.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            ODLog.shared.log("icom-net audio: first packet len=\(r.count) head=[\(head)]", category: "cat")
        }
        // Audio data packets are the large ones on this dedicated stream; PCM begins
        // at offset 24 (16-bit signed little-endian).
        guard r.count >= 64 else { audioSmallCount += 1; logAudioRateIfDue(); return }
        var pcm = [Int16](); pcm.reserveCapacity((r.count - 24) / 2)
        var i = 24
        while i + 1 < r.count { pcm.append(Int16(bitPattern: UInt16(r[i]) | (UInt16(r[i + 1]) << 8))); i += 2 }
        audioPktCount += 1; audioSampleCount += pcm.count
        logAudioRateIfDue()
        if !pcm.isEmpty { onAudioPCM?(pcm) }
    }

    /// Log the RX audio rate every ~2 s — packets, samples, derived samples/sec (vs the
    /// 16 kHz we need for a full slot), and small/ignored packets — so a tester's log shows
    /// whether audio is flowing, too slowly, or in a shape we don't parse. Zero rate logs
    /// after "bootstrapped" means the radio isn't sending RX audio at all.
    private func logAudioRateIfDue() {
        let now = Date()
        let dt = now.timeIntervalSince(audioLastLog)
        guard dt >= 2.0 else { return }
        let sps = dt > 0 ? Double(audioSampleCount) / dt : 0
        ODLog.shared.log(String(format: "icom-net audio: %d pkts, %d samples (~%.0f/s, need %.0f), %d small/ignored in %.1fs",
                                audioPktCount, audioSampleCount, sps, audioSampleRate, audioSmallCount, dt), category: "cat")
        audioPktCount = 0; audioSampleCount = 0; audioSmallCount = 0; audioLastLog = now
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
        control?.close(); serial?.close(); audio?.close()
        control = nil; serial = nil; audio = nil; onAudioPCM = nil
        connected = false; authOK = false
        // Resolve a still-pending connect (disconnect during the handshake). Safe
        // because finishConnect() nils connectCont before it calls teardown.
        if let c = connectCont { connectCont = nil; c.resume(throwing: CATError.notConnected) }
    }

    private func startControl() {
        let s = RSStream(host: host, port: basePort, queue: queue)
        control = s
        s.onReady = { [weak self] in self?.control?.bootstrap() }
        s.onBootstrapped = { [weak self] in self?.advance(to: .controlUp); self?.sendLogin() }
        s.onPacket = { [weak self] pkt in self?.handleControl(pkt) }
        s.onError = { [weak self] e in
            ODLog.shared.log("icom-net control socket error: \(e.localizedDescription)", category: "cat")
            self?.handleSocketError(e)
        }
        // The control stream is our liveness signal — the radio pings it periodically, so a
        // watchdog timeout here means the radio is gone even when the socket reports no error.
        s.onStale = { [weak self] in self?.handleStale() }
        s.start()
    }

    /// Watchdog fired on the control stream: the link is silently dead. Same recovery as a
    /// socket error — tear down cleanly (free the radio's session) and signal the owner to
    /// reconnect. Runs on the network queue; guarded so the two error paths act once.
    private func handleStale() {
        guard connected else { return }
        ODLog.shared.log("icom-net live drop (watchdog) — freeing session and signalling reconnect", category: "cat")
        teardown()
        onDisconnect?()
    }

    /// A socket error during the handshake fails the pending connect; one AFTER connect is
    /// a live drop (radio powered off, Wi-Fi blip, app suspended and iOS killed the UDP
    /// sockets). In that case tear down cleanly — `teardown()` sends the RS-BA1 disconnect
    /// so the radio frees its session and a reconnect doesn't hit "a session is already
    /// open" — then notify the owner exactly once.
    private func handleSocketError(_ e: Error) {
        if connectCont != nil { finishConnect(.failure(e)); return }
        guard connected else { return }        // already torn down by the first socket's error
        ODLog.shared.log("icom-net live drop — freeing session and signalling reconnect", category: "cat")
        teardown()
        onDisconnect?()
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
                ODLog.shared.log("icom-net login REJECTED (bad network username/password)", category: "cat")
                finishConnect(.failure(CATError.network("The radio rejected the network username/password. Check the User1 login and that Network Control is enabled.")))
                return
            }
            advance(to: .loginAccepted)
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
            if r[21] == 0x05 { advance(to: .authAccepted); authOK = true; maybeSendConnInfo() }
            return
        }
        // ConnInfo reply (0x90)
        if r.count >= 144, r[0] == 0x90, r[96] == 0x01 {
            advance(to: .connInfoAccepted)
            control.remoteSID = readBE(r, 8)
            control.localSID = readBE(r, 12)
            for i in 0..<6 { authID[i] = r[26 + i] }
            startSerial()
            startReauth()
            return
        }
        // Note: a 0x90 with r[96] != 1 is NOT necessarily a rejection — the radio also
        // sends benign 0x90 status frames during a normal, successful connect — so we
        // don't treat it as an error here (the connect timeout still catches a real stall).
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
        advance(to: .connInfoSent)
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
        s.onBootstrapped = { [weak self] in self?.serial?.openSerial { [weak self] in self?.advance(to: .serialUp); ODLog.shared.log("icom-net serial open — connected", category: "cat"); self?.finishConnect(.success(())) } }
        s.onCIV = { [weak self] frame in
            guard let self else { return }
            self.lock.lock(); self.rxCIV.append(contentsOf: frame); self.lock.unlock()
        }
        s.onError = { [weak self] e in
            ODLog.shared.log("icom-net serial socket error: \(e.localizedDescription)", category: "cat")
            self?.handleSocketError(e)
        }
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

/// RS-BA1 keepalive/watchdog timing, from wfview (packettypes.h). The keepalive timer runs
/// at 100 ms (IDLE_PERIOD); we ping every 5th tick → 500 ms (PING_PERIOD) and check the
/// watchdog every 5th tick → 500 ms (WATCHDOG_PERIOD). The link is declared dead after this
/// many seconds with no inbound datagram. wfview uses 2 s on the constant-traffic audio/CIV
/// streams; we watch the CONTROL stream (the radio pings it every ~1–2 s) and use a more
/// forgiving 5 s so a brief Wi-Fi hiccup doesn't trip a needless reconnect.
private let kRSStaleSeconds: TimeInterval = 5.0
private let kRSPingEveryTicks = 5

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
    private var keepaliveTick = 0
    private var bootstrapTimer: DispatchSourceTimer?
    private var bootstrapStage = 0
    /// Set on the first `.ready`; a later `.waiting`→`.ready` recovery must not re-bootstrap
    /// or double-arm the receive loop.
    private var didStart = false

    // Liveness watchdog (mirrors wfview's per-stream lastReceived + WATCHDOG_PERIOD timer).
    private var lastReceived = Date()
    private var watchdogTimer: DispatchSourceTimer?
    private var staleFired = false

    var onReady: (() -> Void)?
    var onBootstrapped: (() -> Void)?
    var onPacket: (([UInt8]) -> Void)?
    var onCIV: (([UInt8]) -> Void)?
    var onError: ((Error) -> Void)?
    /// Fired once when no datagram has arrived for `kRSStaleSeconds` — a silently dead link
    /// (Wi-Fi dropped, radio powered off) that the UDP socket won't report as an error.
    var onStale: (() -> Void)?

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
            case .ready:
                // Bootstrap only on the FIRST ready. A `.waiting`→`.ready` recovery (a Wi-Fi
                // path blip healing) must NOT re-run the RS-BA1 handshake or start a second
                // receive loop — the session and the armed receive survive the gap.
                if !self.didStart { self.didStart = true; self.receiveLoop(); self.onReady?() }
                else { ODLog.shared.log("icom-net :\(self.port) path restored (.ready)", category: "cat") }
            case .waiting(let e):
                // Transient — no viable network path right now; Network.framework retries to
                // `.ready` on its own. Do NOT tear the session down here: doing so forced a
                // full re-login on every brief Wi-Fi blip. A genuinely dead link is still
                // caught by the 5 s data watchdog (`onStale`), which triggers a clean reconnect.
                ODLog.shared.log("icom-net :\(self.port) waiting (transient): \(String(describing: e))", category: "cat")
            case .failed(let e):
                // Fatal — the socket/path failed (e.g. the radio closed its port → ENOTCONN).
                self.onError?(CATError.network(e.localizedDescription))
            default: break
            }
        }
        c.start(queue: queue)
    }

    func close() {
        keepalive?.cancel(); keepalive = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        bootstrapTimer?.cancel(); bootstrapTimer = nil
        // Best-effort disconnect (pkt5 ×2).
        let p = header(len: 16, type: 0x0005, seq: 0)
        rawSend(p); rawSend(p)
        conn?.cancel(); conn = nil
    }

    private func receiveLoop() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.lastReceived = Date(); self.handle([UInt8](data)) }
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

    /// Send a TX audio datagram, tracked (retransmittable). Wire layout is wfview's
    /// `audio_packet` (packettypes.h): [0:4] len (LE, 24+payload), [6:8] tracked seq (LE),
    /// [8:12] localSID / [12:16] remoteSID, [16:18] ident 0x0080 (LE ⇒ byte 16 = 0x80),
    /// [18:20] audio sendseq (BE), [20:22] unused, [22:24] datalen (BE), [24:] 16-bit LE PCM.
    /// `datalen` is the payload BYTE count — NOT the sample count (the earlier clean-room
    /// version sent samples, i.e. half, so the radio misparsed every packet).
    func sendAudio(_ pcm: [Int16]) {
        let byteLen = pcm.count * 2
        let total = 24 + byteLen
        var p = [UInt8](repeating: 0, count: total)
        p[0] = UInt8(total & 0xFF); p[1] = UInt8((total >> 8) & 0xFF)
        let seq = nextTracked(); p[6] = UInt8(seq & 0xFF); p[7] = UInt8((seq >> 8) & 0xFF)
        writeBE(&p, 8, localSID); writeBE(&p, 12, remoteSID)
        p[16] = 0x80
        _audioSeq &+= 1
        p[18] = UInt8((_audioSeq >> 8) & 0xFF); p[19] = UInt8(_audioSeq & 0xFF)
        p[22] = UInt8((byteLen >> 8) & 0xFF); p[23] = UInt8(byteLen & 0xFF)
        var idx = 24
        for s in pcm { let u = UInt16(bitPattern: s); p[idx] = UInt8(u & 0xFF); p[idx + 1] = UInt8((u >> 8) & 0xFF); idx += 2 }
        store(p, seq: seq); rawSend(p)
    }
    private var _audioSeq: UInt16 = 0

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
        // Fresh liveness baseline as the link comes up, so the watchdog doesn't count the
        // handshake gap against us.
        lastReceived = Date(); staleFired = false; keepaliveTick = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.keepaliveTick += 1
            // Idle keepalive every tick (100 ms), matching wfview's IDLE_PERIOD. The old code
            // backed off to ~1 idle/s during quiet stretches — but a slot-gated FT4 pass leaves
            // the CI-V bus silent for whole 7.5 s slots, and that sparser keepalive appears to
            // let the radio time the session out (the drops arrive as a socket ENOTCONN, i.e.
            // the radio closing its port). wfview sends idle at 100 ms unconditionally.
            let idle = self.header(len: 16, type: 0x0000, seq: self.nextTracked())
            self.rawSend(idle)
            // Ping every 500 ms (PING_PERIOD), not every tick — matches wfview and spares
            // the link.
            if self.keepaliveTick % kRSPingEveryTicks == 0 { self.sendPing() }
            // Watchdog: same cadence. If the radio has gone silent past the stale window,
            // the socket may never error (Wi-Fi dropped / radio powered off), so declare it
            // dead ourselves — once — and let the owner tear down and reconnect.
            if self.keepaliveTick % kRSPingEveryTicks == 0,
               !self.staleFired, Date().timeIntervalSince(self.lastReceived) > kRSStaleSeconds {
                self.staleFired = true
                ODLog.shared.log("icom-net watchdog: no data for \(Int(kRSStaleSeconds))s — link is stale", category: "cat")
                self.onStale?()
            }
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
