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
