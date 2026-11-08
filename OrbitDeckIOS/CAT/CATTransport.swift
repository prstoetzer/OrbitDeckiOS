import Foundation
import CoreBluetooth

// ===========================================================================
//  CATTransport.swift — transport abstraction + BLE UART serial transport
//
//  A CAT transport moves bytes to/from a radio. `BLESerialTransport` drives a
//  BLE UART adapter (Nordic UART Service or a generic write+notify pair) wired to
//  a radio's CI-V / Yaesu / Kenwood serial port; `IcomNetworkTransport`
//  (IcomNetwork.swift) speaks Icom's RS-BA1 over Wi-Fi. Both present the same
//  interface: send raw bytes (complete CI-V/Yaesu/Kenwood frames), read whatever
//  has arrived.
//
//  iOS supports only BLE here — generic Bluetooth Classic (SPP) adapters need
//  MFi and cannot be opened by a normal app.
// ===========================================================================

enum CATError: LocalizedError {
    case bluetoothUnavailable
    case deviceNotFound
    case notConnected
    case connectTimeout
    case characteristicsNotFound
    case network(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Bluetooth is off or unavailable. Enable Bluetooth in Settings."
        case .deviceNotFound: "The BLE adapter could not be found. Make sure it is powered and in range."
        case .notConnected: "The radio link is not connected."
        case .connectTimeout: "Timed out connecting to the radio."
        case .characteristicsNotFound: "The BLE adapter does not expose a usable UART service."
        case .network(let m): m
        }
    }
}

/// Common transport interface used by `RigController`.
protocol CATTransport: AnyObject, Sendable {
    func connect() async throws
    func disconnect() async
    func send(_ bytes: [UInt8]) async throws
    /// Return bytes received so far, waiting up to `maxWait` for the first byte.
    func readAvailable(maxWait: TimeInterval) async -> [UInt8]
    var isConnected: Bool { get }
    /// Fired once when the link drops UNEXPECTEDLY after a successful connect — never on a
    /// caller-initiated `disconnect()`. The transport cleans up its own sockets/session
    /// first (so a reconnect doesn't collide with a zombie session), then calls this so
    /// the owner (RigController) can stop the loop and reconnect.
    var onDisconnect: (@Sendable () -> Void)? { get set }
}

/// BLE UART serial transport (CoreBluetooth). Thread-safety is hand-managed with
/// a dedicated queue + lock, so the type is `@unchecked Sendable`.
final class BLESerialTransport: NSObject, CATTransport, @unchecked Sendable {
    // Nordic UART Service — the de-facto standard for BLE-serial adapters.
    // Computed (not stored) so the non-Sendable CBUUID isn't a shared global.
    static var nusService: CBUUID { CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") }
    static var nusRX: CBUUID { CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") }  // write
    static var nusTX: CBUUID { CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") }  // notify

    /// A specific GATT service to bind to, by UUID string: write + notify
    /// characteristics. The BLE KISS TNC API (hessu/aprs-specs BLE-KISS-API.md, used
    /// by the B.B. Link for the TH-D74/D75) is service 00000001-…, app→TNC write
    /// 00000002-…, TNC→app notify 00000003-… (all -ba2a-46c9-ae49-01b0961f68bb).
    struct GATTBinding: Sendable {
        let service: String
        let write: String
        let notify: String
        static let bleKISS = GATTBinding(service: "00000001-BA2A-46C9-AE49-01B0961F68BB",
                                         write: "00000002-BA2A-46C9-AE49-01B0961F68BB",
                                         notify: "00000003-BA2A-46C9-AE49-01B0961F68BB")
    }
    /// nil = the CAT behavior: prefer NUS, else the first write/notify pair found.
    private let binding: GATTBinding?

    private let identifier: UUID
    private let queue = DispatchQueue(label: "org.orbitdeck.cat.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private let lock = NSLock()
    private var rxBuffer: [UInt8] = []
    private var lastRxNanos: UInt64 = 0
    private var connectCont: CheckedContinuation<Void, Error>?
    private var poweredOn = false
    private var wantConnect = false
    private var connected = false
    private var scanning = false

    var onDisconnect: (@Sendable () -> Void)?

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    init(identifier: UUID, binding: GATTBinding? = nil) {
        self.identifier = identifier
        self.binding = binding
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectCont = cont
                self.wantConnect = true
                // Fail if we never reach a connected state in time. Route through
                // finishConnect so the scan is stopped and intent cleared.
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, self.connectCont != nil else { return }
                    self.wantConnect = false
                    self.finishConnect(.failure(CATError.connectTimeout))
                }
                self.tryConnect()
            }
        }
    }

    private func tryConnect() {
        guard poweredOn, wantConnect else { return }
        // Prefer a known (bonded/connected) peripheral; otherwise scan and match by
        // identifier — a freshly discovered adapter isn't retrievable until paired.
        if let p = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connectPeripheral(p)
        } else if !scanning {
            scanning = true
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func connectPeripheral(_ p: CBPeripheral) {
        if scanning { central.stopScan(); scanning = false }
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        if scanning { central.stopScan(); scanning = false }
        guard let c = connectCont else { return }
        connectCont = nil
        switch result {
        case .success: connected = true; c.resume()
        case .failure(let e): c.resume(throwing: e)
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.wantConnect = false
                self.connected = false
                if self.scanning { self.central.stopScan(); self.scanning = false }
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                // Resolve a still-pending connect (disconnect tapped mid-connect).
                if let c = self.connectCont { self.connectCont = nil; c.resume(throwing: CATError.notConnected) }
                cont.resume()
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected, let p = peripheral, let ch = writeChar else { throw CATError.notConnected }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        // Chunk to the link's real maximum write (a write longer than it is silently
        // dropped without response), capped at a conservative 180 bytes.
        let chunk = max(20, min(180, p.maximumWriteValueLength(for: type)))
        var i = 0
        while i < bytes.count {
            let slice = Array(bytes[i..<min(i + chunk, bytes.count)])
            queue.async { p.writeValue(Data(slice), for: ch, type: type) }
            i += chunk
        }
    }

    func readAvailable(maxWait: TimeInterval) async -> [UInt8] {
        // Poll on the BLE queue (reliable GCD timing), resuming once the reply has
        // gone quiet for ~80 ms or the hard deadline passes. No Task.sleep, so this
        // never stalls the main thread.
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            queue.async {
                let start = DispatchTime.now().uptimeNanoseconds
                let cap = UInt64(maxWait * 1_000_000_000)
                func poll() {
                    let now = DispatchTime.now().uptimeNanoseconds
                    self.lock.lock()
                    let hasData = !self.rxBuffer.isEmpty
                    let quiet = now &- self.lastRxNanos > 80_000_000
                    self.lock.unlock()
                    if (hasData && quiet) || (now &- start) > cap {
                        self.lock.lock(); let out = self.rxBuffer; self.rxBuffer.removeAll(); self.lock.unlock()
                        cont.resume(returning: out)
                    } else {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { poll() }
                    }
                }
                poll()
            }
        }
    }
}

// CoreBluetooth delegates all run on `queue`.
extension BLESerialTransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = (central.state == .poweredOn)
        if !poweredOn, connectCont != nil { finishConnect(.failure(CATError.bluetoothUnavailable)); return }
        tryConnect()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == identifier else { return }
        connectPeripheral(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(binding.map { [CBUUID(string: $0.service)] })
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(.failure(error ?? CATError.deviceNotFound))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock(); let wasConnected = connected; connected = false; lock.unlock()
        if connectCont != nil {
            finishConnect(.failure(error ?? CATError.notConnected))
        } else if wasConnected, wantConnect {
            // Live drop after a good connect (adapter out of range / powered off), not a
            // caller-initiated disconnect (which clears wantConnect first).
            onDisconnect?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { finishConnect(.failure(CATError.characteristicsNotFound)); return }
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        if let binding {
            // Bound service: take exactly its characteristics, nothing else (an adapter's
            // OTA or config service must never receive packet data).
            guard service.uuid == CBUUID(string: binding.service) else { return }
            for c in chars {
                if c.uuid == CBUUID(string: binding.write) { writeChar = c }
                if c.uuid == CBUUID(string: binding.notify) { notifyChar = c; peripheral.setNotifyValue(true, for: c) }
            }
            if writeChar != nil, notifyChar != nil { finishConnect(.success(())) }
            return
        }
        for c in chars {
            if c.uuid == Self.nusRX || (writeChar == nil && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse))) {
                // Prefer the NUS write characteristic if present.
                if c.uuid == Self.nusRX || writeChar == nil { writeChar = c }
            }
            if c.uuid == Self.nusTX || (notifyChar == nil && c.properties.contains(.notify)) {
                if c.uuid == Self.nusTX || notifyChar == nil {
                    notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
        }
        if writeChar != nil, notifyChar != nil { finishConnect(.success(())) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        lock.lock(); rxBuffer.append(contentsOf: data); lastRxNanos = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }
}

/// Icom native Bluetooth CI-V (IC-705 / IC-905). The radio exposes a single GATT
/// characteristic (write + notify) in its own service and only opens the CI-V bus
/// after a short sign-in: our ID as a 36-character ASCII UUID string, a 16-byte
/// device name, then a fixed token. The radio answers each with an `FE F1 00 cc … FD`
/// config frame and grants bus access with `FE F1 00 64 FD`. The name is only
/// answered while the radio is in Pairing Reception. Protocol behavior per K7MDL2's
/// IC-705 BLE example. Thread-safety is hand-managed with a dedicated queue + lock,
/// so the type is `@unchecked Sendable`.
final class IComBLESerialTransport: NSObject, CATTransport, @unchecked Sendable {
    /// Name shown in the radio's Pairing/Connect list. Must be exactly 16 bytes.
    static let ourDeviceName = "ORBITDECK APP   "

    // Icom UART service; one characteristic carries both directions.
    // Computed (not stored) so the non-Sendable CBUUID isn't a shared global.
    static var icomService: CBUUID { CBUUID(string: "14CF8001-1EC2-D408-1B04-2EB270F14203") }
    static var icomCharacteristic: CBUUID { CBUUID(string: "14CF8002-1EC2-D408-1B04-2EB270F14203") }

    /// Stable per-install ID the radio uses (with the name) to remember this pairing.
    static var installationID: String {
        let key = "OrbitDeckIOS.installationUUID"
        if let id = UserDefaults.standard.string(forKey: key), id.count == 36 { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    enum BLEError: LocalizedError, Equatable {
        case accessNotGranted
        var errorDescription: String? {
            switch self {
            case .accessNotGranted: "The radio did not grant CI-V access over Bluetooth."
            }
        }
    }

    private let identifier: UUID
    private let queue = DispatchQueue(label: "org.orbitdeck.cat.icomble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ioChar: CBCharacteristic?

    private let lock = NSLock()
    private var rxBuffer: [UInt8] = []
    private var lastRxNanos: UInt64 = 0
    private var configSeen: Set<UInt8> = []     // sign-in replies received (cmd bytes)
    private var connectCont: CheckedContinuation<Void, Error>?
    private var poweredOn = false
    private var wantConnect = false
    private var connected = false
    private var scanning = false

    var onDisconnect: (@Sendable () -> Void)?

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    init(identifier: UUID) {
        self.identifier = identifier
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func connect() async throws {
        try await connectGATT()
        do {
            try await signIn()
        } catch {
            await disconnect()
            throw error
        }
        lock.withLock { connected = true }
    }

    private func connectGATT() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectCont = cont
                self.wantConnect = true
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, self.connectCont != nil else { return }
                    self.wantConnect = false
                    self.finishConnect(.failure(CATError.connectTimeout))
                }
                self.tryConnect()
            }
        }
    }

    /// Sign in to the radio's CI-V bus. Each step waits briefly for its reply so the
    /// writes don't collide; only the final access grant is required.
    private func signIn() async throws {
        lock.withLock { configSeen.removeAll(); rxBuffer.removeAll() }
        write(CATCodec.civBLEConfigFrame(cfgCommand: 0x61, payload: Array(Self.installationID.utf8)))
        _ = await awaitConfig(0x61, timeout: 0.5)
        write(CATCodec.civBLEConfigFrame(cfgCommand: 0x62, payload: Array(Self.ourDeviceName.utf8)))
        _ = await awaitConfig(0x62, timeout: 0.5)
        write(CATCodec.civBLEConfigFrame(cfgCommand: 0x63, payload: [0xEE, 0x39, 0x09, 0x10]))
        guard await awaitConfig(0x64, timeout: 5) else { throw BLEError.accessNotGranted }
        ODLog.shared.log("icom BT: CI-V access granted", category: "cat")
    }

    private func write(_ bytes: [UInt8]) {
        queue.async {
            guard let p = self.peripheral, let ch = self.ioChar else { return }
            p.writeValue(Data(bytes), for: ch, type: .withResponse)
        }
    }

    /// Wait (on the BLE queue) until a sign-in reply with `cmd` arrives or `timeout` passes.
    private func awaitConfig(_ cmd: UInt8, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                let deadline = DispatchTime.now() + timeout
                @Sendable func poll() {
                    self.lock.lock(); let seen = self.configSeen.contains(cmd); self.lock.unlock()
                    if seen || DispatchTime.now() >= deadline {
                        cont.resume(returning: seen)
                    } else {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { poll() }
                    }
                }
                poll()
            }
        }
    }

    private func tryConnect() {
        guard poweredOn, wantConnect else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connectPeripheral(p)
        } else if !scanning {
            scanning = true
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func connectPeripheral(_ p: CBPeripheral) {
        if scanning { central.stopScan(); scanning = false }
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        if scanning { central.stopScan(); scanning = false }
        guard let c = connectCont else { return }
        connectCont = nil
        switch result {
        case .success: c.resume()
        case .failure(let e): c.resume(throwing: e)
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.wantConnect = false
                self.lock.lock(); self.connected = false; self.lock.unlock()
                if self.scanning { self.central.stopScan(); self.scanning = false }
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                if let c = self.connectCont { self.connectCont = nil; c.resume(throwing: CATError.notConnected) }
                cont.resume()
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw CATError.notConnected }
        let chunk = 180
        var i = 0
        while i < bytes.count {
            write(Array(bytes[i..<min(i + chunk, bytes.count)]))
            i += chunk
        }
    }

    func readAvailable(maxWait: TimeInterval) async -> [UInt8] {
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            queue.async {
                let start = DispatchTime.now().uptimeNanoseconds
                let cap = UInt64(maxWait * 1_000_000_000)
                @Sendable func poll() {
                    let now = DispatchTime.now().uptimeNanoseconds
                    self.lock.lock()
                    let hasData = !self.rxBuffer.isEmpty
                    let quiet = now &- self.lastRxNanos > 80_000_000
                    self.lock.unlock()
                    if (hasData && quiet) || (now &- start) > cap {
                        self.lock.lock(); let out = self.rxBuffer; self.rxBuffer.removeAll(); self.lock.unlock()
                        cont.resume(returning: out)
                    } else {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { poll() }
                    }
                }
                poll()
            }
        }
    }

    /// Pull complete `FE F1 00 cc … FD` sign-in frames out of `rxBuffer` (so the CI-V
    /// parser never sees them) and record their command bytes. Call with `lock` held.
    private func extractConfigFrames() {
        var i = 0
        while i + 3 < rxBuffer.count {
            guard rxBuffer[i] == 0xFE, rxBuffer[i + 1] == 0xF1, rxBuffer[i + 2] == 0x00 else { i += 1; continue }
            guard let end = rxBuffer[(i + 3)...].firstIndex(of: 0xFD) else { return }   // incomplete
            let cmd = rxBuffer[i + 3]
            if cmd == 0x63, end > i + 4 {
                ODLog.shared.log("icom BT: token reply \(rxBuffer[i + 4] == 0x01 ? "pairing accepted" : "already paired")", category: "cat")
            }
            configSeen.insert(cmd)
            rxBuffer.removeSubrange(i...end)
        }
    }
}

// CoreBluetooth delegates all run on `queue`.
extension IComBLESerialTransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = (central.state == .poweredOn)
        if !poweredOn, connectCont != nil { finishConnect(.failure(CATError.bluetoothUnavailable)); return }
        tryConnect()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == identifier else { return }
        connectPeripheral(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.icomService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(.failure(error ?? CATError.deviceNotFound))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock(); let wasConnected = connected; connected = false; lock.unlock()
        if connectCont != nil {
            finishConnect(.failure(error ?? CATError.notConnected))
        } else if wasConnected, wantConnect {
            // Live drop after a good connect, not a caller-initiated disconnect.
            onDisconnect?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.icomService }) else {
            finishConnect(.failure(CATError.characteristicsNotFound)); return
        }
        peripheral.discoverCharacteristics([Self.icomCharacteristic], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == Self.icomCharacteristic }) else {
            finishConnect(.failure(CATError.characteristicsNotFound)); return
        }
        ioChar = c
        peripheral.setNotifyValue(true, for: c)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.icomCharacteristic else { return }
        // Only start the sign-in once notifications are on, or the replies are lost.
        if let error { finishConnect(.failure(error)) } else { finishConnect(.success(())) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        lock.lock()
        rxBuffer.append(contentsOf: data)
        lastRxNanos = DispatchTime.now().uptimeNanoseconds
        extractConfigFrames()
        lock.unlock()
    }
}

// MARK: - Device scanner (for the Settings picker)

/// A BLE peripheral the user can pick as their CAT adapter.
struct BLEDevice: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Scans for nearby BLE peripherals so the operator can choose their adapter.
@MainActor
final class BLEScanner: NSObject, ObservableObject {
    @Published var devices: [BLEDevice] = []
    @Published var isScanning = false
    @Published var poweredOn = false

    private var central: CBCentralManager?
    private var wantScan = false

    func start() {
        wantScan = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        beginScanIfReady()
    }

    func stop() {
        wantScan = false
        central?.stopScan()
        isScanning = false
    }

    /// Begin the actual scan once Bluetooth is powered on. Called both from
    /// `start()` and from the state callback, so a scan requested before Bluetooth
    /// is ready still starts as soon as it powers on.
    private func beginScanIfReady() {
        guard wantScan, let central, central.state == .poweredOn else { return }
        devices.removeAll()
        // Scan for everything — BLE UART adapters (incl. the B.B. Link) don't all
        // advertise a filterable service UUID.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = (central.state == .poweredOn)
        Task { @MainActor in
            self.poweredOn = on
            if on { self.beginScanIfReady() } else { self.isScanning = false }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Show the advertised name, else the cached peripheral name, else a stub —
        // never drop a device just because it advertises without a name.
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Unnamed device"
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            if let idx = self.devices.firstIndex(where: { $0.id == id }) {
                // Prefer a real name once one arrives; keep the freshest RSSI.
                let best = (self.devices[idx].name == "Unnamed device") ? name : self.devices[idx].name
                self.devices[idx] = BLEDevice(id: id, name: best, rssi: rssi)
            } else {
                self.devices.append(BLEDevice(id: id, name: name, rssi: rssi))
            }
            self.devices.sort { $0.rssi > $1.rssi }
        }
    }
}

// ===========================================================================
//  Hamlib-compatible network servers (rigctld / rotctld)
//
//  OrbitDeck can act as a Hamlib "NET rigctl" / "NET rotctl" server so Gpredict,
//  SatPC32, WSJT-X or a logger on the LAN drives (or reads) the radio and rotator
//  through OrbitDeck's own links, like CardSat's built-in servers. The line protocol
//  is implemented from Hamlib's public rigctld(1)/rotctld(1) documentation.
//
//  `HamlibLineServer` is the transport: an NWListener plus one NWConnection per client,
//  all on one private serial queue (never the main thread). Lines are handed one at a
//  time per client to a @MainActor handler; replies go back on the queue. Buffers are
//  bounded (line length, queued lines, client count) and only LAN peers are accepted.
// ===========================================================================

import Network
import UIKit

/// One parsed Hamlib command line.
struct HamlibCommand: Sendable {
    /// Long command name ("get_freq"); short commands are mapped through a table, and an
    /// unknown short command keeps its character as the name.
    let name: String
    let args: [String]
    /// Extended-response separator ("\n" for `+`, else the `;`, `|` or `,` used); nil = normal.
    let separator: String?
}

/// What a command produced; `HamlibProtocol.reply` turns it into wire text.
enum HamlibResult: Sendable {
    case values([(label: String, value: String)])
    case ok
    case error(Int)
    case raw(String)
    case quit
}

enum HamlibProtocol {
    // Hamlib error codes (negated in "RPRT -n").
    static let eInval = 1, eNotImplemented = 4, eIO = 6, eNotAvailable = 11

    /// Parse a line: optional extended-response prefix (`+`, `;`, `|`, `,`), then either a
    /// `\long_name args…` or a one-character short command followed by its arguments.
    static func parse(_ lineIn: String, shortNames: [Character: String]) -> HamlibCommand? {
        var line = Substring(lineIn.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = line.first else { return nil }
        var sep: String?
        if "+;|,".contains(first) {
            sep = first == "+" ? "\n" : String(first)
            line = line.dropFirst().drop(while: { $0 == " " })
        }
        guard let head = line.first else { return nil }
        if head == "\\" {
            let parts = line.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let name = parts.first else { return nil }
            return HamlibCommand(name: name, args: Array(parts.dropFirst()), separator: sep)
        }
        let args = line.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return HamlibCommand(name: shortNames[head] ?? String(head), args: args, separator: sep)
    }

    /// Wire text for a result, and whether to close the connection afterwards. Normal mode:
    /// a get prints its values one per line, a set prints `RPRT 0`, a failure `RPRT -n`.
    /// Extended mode: `name: args`, `Label: value` lines, then `RPRT n`, all joined by the
    /// separator.
    static func reply(_ cmd: HamlibCommand, _ result: HamlibResult) -> HamlibLineServer.Reply {
        switch result {
        case .quit: return .init(text: "", close: true)
        case .raw(let s): return .init(text: s, close: false)
        default: break
        }
        guard let sep = cmd.separator else {
            switch result {
            case .values(let v): return .init(text: v.map { $0.value + "\n" }.joined(), close: false)
            case .error(let n): return .init(text: "RPRT -\(n)\n", close: false)
            default: return .init(text: "RPRT 0\n", close: false)
            }
        }
        var out = cmd.name + ":" + cmd.args.map { " " + $0 }.joined() + sep
        var code = 0
        switch result {
        case .values(let v): for item in v { out += "\(item.label): \(item.value)" + sep }
        case .error(let n): code = -n
        default: break
        }
        out += "RPRT \(code)\n"
        return .init(text: out, close: false)
    }

    /// The device's IPv4 addresses a LAN client can reach (Wi-Fi, Personal Hotspot,
    /// wired Ethernet adapters) — never cellular or VPN tunnels.
    static func lanAddresses() -> [(interface: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let start = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let label = name == "en0" ? "Wi-Fi" : (name.hasPrefix("bridge") ? "Personal Hotspot" : name)
            result.append((label, addr))
        }
        return result
    }

    /// Whether a peer is on the local network (private, link-local or loopback address).
    static func isLocalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return isLocalV4([UInt8](a.rawValue))
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            if a.isLoopback || a.isLinkLocal { return true }
            if b[0] & 0xFE == 0xFC { return true }                                   // fc00::/7 ULA
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {      // ::ffff:a.b.c.d
                return isLocalV4(Array(b[12..<16]))
            }
            return false
        default: return false
        }
    }

    private static func isLocalV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 10 || b[0] == 127
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)
    }
}

/// TCP line server shared by the rigctld and rotctld servers. All state lives on `queue`.
final class HamlibLineServer: @unchecked Sendable {
    struct Reply: Sendable {
        var text: String
        var close: Bool
    }
    enum Event: Sendable {
        case state(listening: Bool, error: String?, clients: Int)
        case clientAdded(id: Int, address: String)
        case clientGone(id: Int)
    }
    typealias Handler = @MainActor @Sendable (_ client: Int, _ line: String) async -> Reply

    static let maxClients = 8
    static let maxLineBytes = 1024
    static let maxQueuedLines = 64

    private final class Client {
        let conn: NWConnection
        var buffer: [UInt8] = []
        var overflow = false
        var pending: [String] = []
        var busy = false
        var eof = false
        init(conn: NWConnection) { self.conn = conn }
    }

    private let name: String
    private let queue: DispatchQueue
    private let handler: Handler
    private let onEvent: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var wanted = false
    private var listening = false
    private var lastError: String?
    private var clients: [Int: Client] = [:]
    private var nextID = 1

    init(name: String, handler: @escaping Handler, onEvent: @escaping @Sendable (Event) -> Void) {
        self.name = name
        self.queue = DispatchQueue(label: "org.orbitdeck.server.\(name)")
        self.handler = handler
        self.onEvent = onEvent
    }

    /// (Re)start listening on `port`, dropping any existing clients.
    func start(port: UInt16) {
        queue.async {
            self.closeAll()
            self.wanted = true
            self.port = port
            self.openListener()
        }
    }

    func stop() {
        queue.async {
            self.wanted = false
            self.closeAll()
        }
    }

    /// After returning to the foreground: reopen the listener if iOS tore it down.
    func ensureRunning() {
        queue.async {
            guard self.wanted else { return }
            if let l = self.listener {
                switch l.state {
                case .failed, .cancelled: break
                default: return
                }
            }
            self.openListener()
        }
    }

    // MARK: Listener (queue only)

    private func openListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        listening = false
        guard let p = NWEndpoint.Port(rawValue: port), port > 0 else {
            lastError = "Invalid port"; publish(); return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.prohibitedInterfaceTypes = [.cellular]
        let l: NWListener
        do { l = try NWListener(using: params, on: p) } catch {
            lastError = error.localizedDescription; publish(); scheduleRetry(); return
        }
        listener = l
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, l === self.listener else { return }
            switch state {
            case .ready:
                self.listening = true; self.lastError = nil; self.publish()
                ODLog.shared.log("\(self.name) server listening on TCP \(self.port)", category: "net")
            case .waiting(let e):
                self.listening = false; self.lastError = e.localizedDescription; self.publish()
            case .failed(let e):
                self.listening = false; self.lastError = e.localizedDescription
                ODLog.shared.log("\(self.name) server listener failed: \(e.localizedDescription)", category: "net")
                l.cancel(); self.listener = nil
                self.publish(); self.scheduleRetry()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
    }

    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.wanted, self.listener == nil else { return }
            self.openListener()
        }
    }

    private func closeAll() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        listening = false
        for id in Array(clients.keys) { close(id, notify: true) }
        publish()
    }

    private func publish() {
        onEvent(.state(listening: listening, error: lastError, clients: clients.count))
    }

    // MARK: Clients (queue only)

    private func accept(_ conn: NWConnection) {
        guard HamlibProtocol.isLocalPeer(conn.endpoint) else {
            ODLog.shared.log("\(name) server: refused non-LAN peer \(conn.endpoint)", category: "net")
            conn.cancel(); return
        }
        guard clients.count < Self.maxClients else {
            ODLog.shared.log("\(name) server: refused \(conn.endpoint) (client limit)", category: "net")
            conn.cancel(); return
        }
        let id = nextID; nextID += 1
        clients[id] = Client(conn: conn)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id, notify: true)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(id)
        var address = "\(conn.endpoint)"
        if case .hostPort(let h, _) = conn.endpoint { address = "\(h)" }
        if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }   // drop IPv6 scope
        ODLog.shared.log("\(name) server: client \(address) connected", category: "net")
        onEvent(.clientAdded(id: id, address: address))
        publish()
    }

    private func receive(_ id: Int) {
        guard let c = clients[id] else { return }
        c.conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, let c = self.clients[id] else { return }
            if let data, !data.isEmpty { self.ingest(id, c, data) }
            guard self.clients[id] != nil else { return }       // ingest may have closed it
            if isComplete || error != nil {
                c.eof = true
                if !c.busy, c.pending.isEmpty { self.close(id, notify: true) }
            } else {
                self.receive(id)
            }
        }
    }

    private func ingest(_ id: Int, _ c: Client, _ data: Data) {
        for b in data {
            if b == 0x0A {
                if !c.overflow {
                    let line = String(decoding: c.buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { c.pending.append(line) }
                }
                c.buffer.removeAll(keepingCapacity: true)
                c.overflow = false
            } else if c.buffer.count < Self.maxLineBytes {
                c.buffer.append(b)
            } else {
                c.overflow = true                               // over-long line: discard it
            }
        }
        if c.pending.count > Self.maxQueuedLines {
            ODLog.shared.log("\(name) server: client flooding commands — disconnected", category: "net")
            close(id, notify: true); return
        }
        pump(id)
    }

    /// Dispatch the next queued line to the handler (one in flight per client, in order).
    private func pump(_ id: Int) {
        guard let c = clients[id], !c.busy else { return }
        guard !c.pending.isEmpty else {
            if c.eof { close(id, notify: true) }
            return
        }
        c.busy = true
        let line = c.pending.removeFirst()
        let handler = self.handler
        let queue = self.queue
        Task { [weak self] in
            let reply = await handler(id, line)
            queue.async { [weak self] in self?.finish(id, reply) }
        }
    }

    private func finish(_ id: Int, _ reply: Reply) {
        guard let c = clients[id] else { return }
        c.busy = false
        if reply.close {
            c.conn.send(content: reply.text.isEmpty ? nil : Data(reply.text.utf8), isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close(id, notify: true) })
            return
        }
        if !reply.text.isEmpty {
            c.conn.send(content: Data(reply.text.utf8), completion: .contentProcessed { _ in })
        }
        pump(id)
    }

    private func close(_ id: Int, notify: Bool) {
        guard let c = clients.removeValue(forKey: id) else { return }
        c.conn.stateUpdateHandler = nil
        c.conn.cancel()
        if notify { onEvent(.clientGone(id: id)) }
        publish()
    }
}

/// Built-in Hamlib rigctld server: lets a LAN client drive or read the radio through
/// OrbitDeck's CAT link. VFOA = downlink leg, VFOB = uplink leg ("Main"/"Sub" follow the
/// radio's MAIN = uplink setting). Frequencies are the radio's dial.
///
/// Doppler arbitration: reads never disturb OrbitDeck. The first set-frequency from a
/// client pauses OrbitDeck's own Doppler loop (the FT4 hold mechanism) for as long as
/// that client stays connected — Gpredict or WSJT-X then owns the dial. When the last
/// controlling client disconnects (or sends `q`, or the operator taps Resume) Doppler
/// resumes and re-commands both legs. Mode, split and PTT commands don't take control.
///
/// PTT: refused (`RPRT -11`) unless the operator turned on "Allow PTT from network
/// clients" (off by default). A client's key is released when that client disconnects or
/// quits, the server is turned off or moved to another port, OrbitDeck goes to the
/// background, or after `pttLimitSec` keyed (a safety limit).
@MainActor
final class RigctldServer: ObservableObject {
    static let shared = RigctldServer()
    static let defaultPort = 4532
    private static let enabledKey = "orbitdeck.rigctldServer.enabled"
    private static let portKey = "orbitdeck.rigctldServer.port"
    private static let allowPTTKey = "orbitdeck.rigctldServer.allowPTT"
    /// Longest a network client may keep the radio keyed before the server unkeys it.
    static let pttLimitSec: Double = 180

    @Published private(set) var enabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var listening = false
    @Published private(set) var errorText: String?
    @Published private(set) var clientCount = 0
    @Published private(set) var lastCommand = ""
    @Published private(set) var externalControl = false
    /// "Allow PTT from network clients" (persisted; off unless the operator turns it on).
    @Published private(set) var allowPTT: Bool
    /// True while a network client has the radio keyed through the server.
    @Published private(set) var clientKeyed = false

    private weak var rig: RigController?
    /// The client that keyed the radio (nil = the server hasn't keyed it).
    private var pttClient: Int? { didSet { clientKeyed = pttClient != nil } }
    /// Bumped on every key/release, so a stale safety-limit timer or a key that completes
    /// after a release can tell it's out of date.
    private var pttSeq = 0
    private var core: HamlibLineServer!
    private var clientVFO: [Int: RigRole] = [:]
    private var clientAddress: [Int: String] = [:]
    private var controllers = Set<Int>()
    private var ownsHold = false
    private var legMode: [RigRole: RigMode] = [:]
    private var lastCommandAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private static let shortNames: [Character: String] = [
        "f": "get_freq", "F": "set_freq", "m": "get_mode", "M": "set_mode",
        "v": "get_vfo", "V": "set_vfo", "s": "get_split_vfo", "S": "set_split_vfo",
        "i": "get_split_freq", "I": "set_split_freq", "x": "get_split_mode", "X": "set_split_mode",
        "t": "get_ptt", "T": "set_ptt", "_": "get_info", "q": "quit", "Q": "quit",
    ]

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Self.enabledKey)
        let p = d.integer(forKey: Self.portKey)
        port = (1024...65535).contains(p) ? p : Self.defaultPort
        allowPTT = d.bool(forKey: Self.allowPTTKey)        // absent → false
        core = HamlibLineServer(name: "rigctld", handler: { [weak self] id, line in
            guard let self else { return .init(text: "RPRT -\(HamlibProtocol.eIO)\n", close: false) }
            return await self.handle(id, line)
        }, onEvent: { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        })
    }

    /// Called once at launch; starts the server if it was left enabled.
    func attach(_ rig: RigController) {
        self.rig = rig
        if observers.isEmpty {
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.enabled == true { self?.core.ensureRunning() } }
            })
            observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.releasePTT("OrbitDeck is quitting"); self?.core.stop() }
            })
            // Nobody can watch a network-keyed transmitter once the app leaves the screen.
            observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.releasePTT("OrbitDeck went to the background") }
            })
        }
        if enabled { core.start(port: UInt16(port)) }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { core.start(port: UInt16(port)) } else { releasePTT("server turned off"); core.stop(); releaseAll() }
    }

    func setPort(_ p: Int) {
        let p = min(65535, max(1024, p))
        guard p != port else { return }
        port = p
        UserDefaults.standard.set(p, forKey: Self.portKey)
        if enabled { releasePTT("server port changed"); releaseAll(); core.start(port: UInt16(p)) }
    }

    func setAllowPTT(_ on: Bool) {
        guard on != allowPTT else { return }
        allowPTT = on
        UserDefaults.standard.set(on, forKey: Self.allowPTTKey)
        if !on { releasePTT("network PTT turned off") }
    }

    /// Operator override: hand the dial back to OrbitDeck's Doppler loop now.
    func resumeDoppler() { releaseAll() }

    /// Unkey a client-keyed radio now (operator button).
    func unkeyClient() { releasePTT("unkeyed by the operator") }

    /// Stop all: unkey anything a client keyed and hand the dial back to OrbitDeck.
    func releaseForStopAll() {
        releasePTT("Stop all")
        releaseAll()
    }

    // MARK: Events

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
        guard let rig else { return }
        if controllers.insert(id).inserted {
            ODLog.shared.log("rigctld server: \(clientAddress[id] ?? "client") is controlling the radio", category: "cat")
        }
        if rig.serverBeginExternalHold() { ownsHold = true }
        externalControl = true
    }

    private func endClient(_ id: Int) {
        clientVFO.removeValue(forKey: id)
        if pttClient == id { releasePTT("\(clientAddress[id] ?? "the client that keyed it") disconnected") }
        guard controllers.remove(id) != nil else { return }
        if controllers.isEmpty { releaseAll() }
    }

    private func releaseAll() {
        controllers.removeAll()
        if ownsHold { rig?.serverEndExternalHold(); ownsHold = false }
        externalControl = false
    }

    // MARK: PTT

    /// Unkey the radio if a network client keyed it (no-op otherwise, so FT4's or the
    /// operator's own transmission is never touched).
    private func releasePTT(_ reason: String) {
        guard pttClient != nil else { return }
        pttClient = nil
        pttSeq += 1
        ODLog.shared.log("rigctld server: PTT released — \(reason)", category: "cat")
        guard let rig else { return }
        Task { _ = await rig.serverSetPTT(false) }
    }

    /// `T 1` / `T 0` from a client.
    private func setPTT(_ id: Int, on: Bool) async -> HamlibResult {
        guard let rig, rig.connected else { return .error(HamlibProtocol.eIO) }
        guard on else {
            let ok = await rig.serverSetPTT(false)
            if pttClient != nil { pttClient = nil; pttSeq += 1 }
            return ok ? .ok : .error(HamlibProtocol.eNotAvailable)
        }
        guard allowPTT else {
            ODLog.shared.log("rigctld server: PTT from \(clientAddress[id] ?? "client") refused — network PTT is off", category: "cat")
            return .error(HamlibProtocol.eNotAvailable)
        }
        // Already keyed by a client: the safety limit keeps running from that key.
        if pttClient != nil, rig.serverPTT { return .ok }
        pttSeq += 1
        let seq = pttSeq
        pttClient = id
        let keyed = await rig.serverSetPTT(true)
        guard seq == pttSeq, pttClient == id else {
            // Released while keying (client gone, server off, backgrounded): make sure it's down.
            if keyed { _ = await rig.serverSetPTT(false) }
            return .error(HamlibProtocol.eIO)
        }
        guard keyed else {
            pttClient = nil; pttSeq += 1
            if let why = rig.pttBlockedReason { ODLog.shared.log("rigctld server: PTT refused — \(why)", category: "cat") }
            return .error(HamlibProtocol.eNotAvailable)
        }
        ODLog.shared.log("rigctld server: \(clientAddress[id] ?? "client") keyed the radio", category: "cat")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pttLimitSec) { [weak self] in
            Task { @MainActor in
                guard let self, self.pttSeq == seq, self.pttClient != nil else { return }
                self.releasePTT("keyed for \(Int(Self.pttLimitSec / 60)) minutes (safety limit)")
            }
        }
        return .ok
    }

    // MARK: Commands

    private func handle(_ id: Int, _ line: String) async -> HamlibLineServer.Reply {
        guard let cmd = HamlibProtocol.parse(line, shortNames: Self.shortNames) else { return .init(text: "", close: false) }
        // Throttled so a client polling get_freq many times a second doesn't churn the UI.
        let now = Date()
        if cmd.name.hasPrefix("set_") || now.timeIntervalSince(lastCommandAt) > 1 {
            lastCommandAt = now
            lastCommand = "\(clientAddress[id] ?? "?"): \(line.prefix(60))"
        }
        return HamlibProtocol.reply(cmd, await execute(id, cmd))
    }

    private func execute(_ id: Int, _ cmd: HamlibCommand) async -> HamlibResult {
        let vfo = clientVFO[id] ?? .downlink
        switch cmd.name {
        case "dump_state": return .raw(Self.dumpState)
        case "chk_vfo": return .raw("CHKVFO 0\n")
        case "get_powerstat": return .values([("Power Status", "1")])
        case "set_powerstat": return .ok
        case "get_info": return .values([("Info", "OrbitDeck")])
        case "quit":
            endClient(id)
            return .quit
        case "get_vfo": return .values([("VFO", vfo == .uplink ? "VFOB" : "VFOA")])
        case "set_vfo":
            guard let a = cmd.args.first, let leg = leg(named: a, current: vfo) else { return .error(HamlibProtocol.eInval) }
            clientVFO[id] = leg
            return .ok
        case "get_freq": return await getFreq(vfo, label: "Frequency")
        case "set_freq": return await setFreq(id, vfo, cmd.args)
        case "get_split_freq": return await getFreq(.uplink, label: "TX Frequency")
        case "set_split_freq": return await setFreq(id, .uplink, cmd.args)
        case "get_mode": return getMode(vfo, labels: ("Mode", "Passband"))
        case "set_mode": return await setMode(vfo, cmd.args)
        case "get_split_mode": return getMode(.uplink, labels: ("TX Mode", "TX Passband"))
        case "set_split_mode": return await setMode(.uplink, cmd.args)
        case "get_split_vfo":
            let split = rig?.serverHasLeg(.uplink) ?? false
            return .values([("Split", split ? "1" : "0"), ("TX VFO", split ? "VFOB" : "VFOA")])
        case "set_split_vfo":
            return .ok       // the satellite layout is fixed: RX on VFOA, TX on VFOB
        case "get_ptt": return .values([("PTT", rig?.serverPTT == true ? "1" : "0")])
        case "set_ptt":
            guard let a = cmd.args.first, let n = Int(a) else { return .error(HamlibProtocol.eInval) }
            return await setPTT(id, on: n != 0)
        default:
            return .error(HamlibProtocol.eNotImplemented)
        }
    }

    private func leg(named name: String, current: RigRole) -> RigRole? {
        switch name.lowercased() {
        case "vfoa", "rx", "vfo": return .downlink
        case "vfob", "tx": return .uplink
        case "currvfo": return current
        case "main": return (rig?.serverMainIsUplink ?? false) ? .uplink : .downlink
        case "sub": return (rig?.serverMainIsUplink ?? false) ? .downlink : .uplink
        default: return nil
        }
    }

    private func getFreq(_ leg: RigRole, label: String) async -> HamlibResult {
        guard let rig, rig.connected else { return .error(HamlibProtocol.eIO) }
        guard rig.serverHasLeg(leg) else { return .error(HamlibProtocol.eNotAvailable) }
        guard let hz = await rig.serverRigFrequency(leg: leg) else { return .error(HamlibProtocol.eIO) }
        return .values([(label, String(hz))])
    }

    private func setFreq(_ id: Int, _ leg: RigRole, _ args: [String]) async -> HamlibResult {
        guard let a = args.first, let v = Double(a), v >= 1, v < 1e11 else { return .error(HamlibProtocol.eInval) }
        guard let rig, rig.connected else { return .error(HamlibProtocol.eIO) }
        guard rig.serverHasLeg(leg) else { return .error(HamlibProtocol.eNotAvailable) }
        beginControl(id)
        let mode = legMode[leg] ?? rig.serverDerivedMode(leg: leg)
        return await rig.serverSetFrequency(leg: leg, hz: Int64(v.rounded()), mode: mode) ? .ok : .error(HamlibProtocol.eIO)
    }

    private func getMode(_ leg: RigRole, labels: (String, String)) -> HamlibResult {
        guard let rig, rig.connected else { return .error(HamlibProtocol.eIO) }
        guard rig.serverHasLeg(leg) else { return .error(HamlibProtocol.eNotAvailable) }
        let m = legMode[leg] ?? rig.serverDerivedMode(leg: leg) ?? .usb
        let (name, passband) = Self.hamlibMode(m)
        return .values([(labels.0, name), (labels.1, String(passband))])
    }

    private func setMode(_ leg: RigRole, _ args: [String]) async -> HamlibResult {
        guard let a = args.first else { return .error(HamlibProtocol.eInval) }
        if a == "?" { return .raw("AM CW USB LSB FM FMN PKTUSB PKTLSB PKTFM\n") }
        guard let mode = Self.rigMode(a) else { return .error(HamlibProtocol.eInval) }
        guard let rig, rig.connected else { return .error(HamlibProtocol.eIO) }
        guard rig.serverHasLeg(leg) else { return .error(HamlibProtocol.eNotAvailable) }
        legMode[leg] = mode
        return await rig.serverSetMode(leg: leg, mode: mode) ? .ok : .error(HamlibProtocol.eIO)
    }

    private static func hamlibMode(_ m: RigMode) -> (String, Int) {
        switch m {
        case .lsb: ("LSB", 2400)
        case .usb: ("USB", 2400)
        case .cw: ("CW", 500)
        case .fm: ("FM", 15000)
        case .fmn: ("FM", 10000)
        case .am: ("AM", 6000)
        case .data: ("PKTUSB", 2400)
        }
    }

    private static func rigMode(_ s: String) -> RigMode? {
        switch s.uppercased() {
        case "USB", "PKTUSB": .usb
        case "LSB", "PKTLSB": .lsb
        case "CW", "CWR": .cw
        case "FM", "PKTFM": .fm
        case "FMN": .fmn
        case "AM", "AMS": .am
        default: nil
        }
    }

    /// Minimal protocol-0 `\dump_state` so Hamlib NET rigctl (model 2) clients connect:
    /// version, model, ITU region, one RX and one TX range (100 kHz–1.3 GHz, AM/CW/USB/
    /// LSB/RTTY/FM/WFM modes, VFOA|VFOB), a 1 Hz tuning step, normal filters per mode,
    /// no RIT/XIT/IF shift, no announces/preamp/attenuator, no funcs/levels/parms.
    private static let dumpState = """
    0
    2
    2
    100000.000000 1300000000.000000 0x1ff -1 -1 0x3 0x0
    0 0 0 0 0 0 0
    100000.000000 1300000000.000000 0x1ff 1000 100000 0x3 0x0
    0 0 0 0 0 0 0
    0x1ff 1
    0 0
    0xc 2400
    0x2 500
    0x1 6000
    0x20 15000
    0 0
    0
    0
    0
    0
    0
    0
    0x0
    0x0
    0x0
    0x0
    0x0
    0x0

    """
}
