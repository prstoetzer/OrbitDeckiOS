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
    func postConnect() async throws
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

    init(identifier: UUID) {
        self.identifier = identifier
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
    
    func postConnect() async throws { /* no-op */ }

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
        // Chunk to a conservative MTU so large ASCII commands still get through.
        let chunk = 180
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
        peripheral.discoverServices(nil)
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


/// ICOM BLE UART serial transport (CoreBluetooth). Thread-safety is hand-managed with
/// a dedicated queue + lock, so the type is `@unchecked Sendable`.
final class IComBLESerialTransport: NSObject, CATTransport, @unchecked Sendable {
    // Bluetooth device name - must be exactly 16 bytes, can be padded with spaces
    static let ourDeviceName: String = "ORBITDECK APP   "
    
    // Icom UART Service and characteristics UUIDs.
    // Computed (not stored) so the non-Sendable CBUUID isn't a shared global.
    static var icomService: CBUUID { CBUUID(string: "14CF8001-1EC2-D408-1B04-2EB270F14203") }
    static var icomRXCharacteristic: CBUUID { CBUUID(string: "14CF8002-1EC2-D408-1B04-2EB270F14203") }  // write
    static var icomTXCharacteristic: CBUUID { CBUUID(string: "14CF8002-1EC2-D408-1B04-2EB270F14203") }  // notify

    private let identifier: UUID
    private let queue = DispatchQueue(label: "org.orbitdeck.cat.icomble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private let lock = NSLock()
    private var rxBuffer: [UInt8] = []
    private var lastRxNanos: UInt64 = 0
    private var connectCont: CheckedContinuation<Void, Error>?
    private var writeResponseContinuation: CheckedContinuation<Data, Error>?
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
    
    func postConnect() async throws {
        // random uuid identifying our app: 136108e3-4ab4-4900-b1b8-e1d6b2706ade
        let deviceUUIDBytes: [UInt8] = [
            0x13, 0x61, 0x08, 0xE3,
            0x4A, 0xB4,
            0x49, 0x00,
            0xB1, 0xB8,
            0xE1, 0xD6, 0xB2, 0x70, 0x6A, 0xDE
        ]
        
        let deviceUUIDMessage = CATCodec.civBLEConfigFrame(cfgCommand: 0x61, payload: deviceUUIDBytes)
        
        let deviceNameBytes: [UInt8] = Array(IComBLESerialTransport.ourDeviceName.utf8)
        let deviceNameMessage = CATCodec.civBLEConfigFrame(cfgCommand: 0x62, payload: deviceNameBytes)
        
        let tokenMessage = CATCodec.civBLEConfigFrame(cfgCommand: 0x63, payload: [0xEE, 0x39, 0x09, 0x10])
        let civAccessGrantedReply = CATCodec.civBLEConfigFrame(cfgCommand: 0x64, payload: [])
        
        // Step 1: Send 'device UUID' message
        _ = try await sendCommandAndWaitForReply(deviceUUIDMessage)

        // Step 2: Send 'device name' message
        do {
            _ = try await sendCommandAndWaitForReply(deviceNameMessage)
        } catch BLEError.commandTimeout {
            // Ignore timeout exception intentionally as the radio only replies until it is registered for the first time
        } catch {
            throw error
        }
        
        // Step 3: Send 'token' message
        do {
            let tokenMessageReply = try await sendCommandAndWaitForReply(tokenMessage)
            
            if tokenMessageReply != Data(civAccessGrantedReply) {
                throw PairingError.accessGrantedMismatch(expected: civAccessGrantedReply.description, received: tokenMessageReply.description)
            }
        } catch {
            throw error
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
        // Chunk to a conservative MTU so large ASCII commands still get through.
        let chunk = 180
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
    
    
func sendCommandAndWaitForReply(_ bytes: [UInt8]) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            // Task for sending and consequent waiting for reply
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self.writeResponseContinuation = continuation
                    self.lock.unlock()
                    
                    guard isConnected, let p = peripheral, let ch = writeChar else {
                        self.clearContinuation(with: .failure(CATError.notConnected))
                        return
                    }
                    p.writeValue(Data(bytes), for: ch, type: .withResponse)
                }
            }
            
            // Task handling timeout (sleep)
            group.addTask {
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000) // 3 seconds
                throw BLEError.commandTimeout
            }
            
            // whichever task completes first, wins
            do {
                let firstResult = try await group.next()!
                group.cancelAll()
                return firstResult
            } catch {
                group.cancelAll()
                // if the timeout task has won, clean up the Bluetooth continuation
                self.clearContinuation(with: .failure(CATError.notConnected))
                throw error
            }
        }
    }

    
    
    // Helper method to atomically clear and resume the continuation under a lock
    private func clearContinuation(with result: Result<Data, Error>) {
        self.lock.lock()
        guard let continuation = self.writeResponseContinuation else {
            self.lock.unlock()
            return
        }
        self.writeResponseContinuation = nil
        self.lock.unlock()
        
        // Resume outside of the lock scope to prevent potential deadlocks
        continuation.resume(with: result)
    }
    
    enum PairingError: Error, CustomStringConvertible {
        case accessGrantedMismatch(expected: String, received: String)
        
        var description: String {
            switch self {
            case .accessGrantedMismatch(let expected, let received):
                return "Expected receiving CI-V access granted reply from radio (\(expected)), but received (\(received))"
            }
        }
    }

    enum BLEError: Error, LocalizedError {
        case commandTimeout
        
        var errorDescription: String? {
            switch self {
            case .commandTimeout:
                return "The radio did not respond to the BT command in time (timeout)."
            }
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
        peripheral.discoverServices(nil)
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
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            // Use Icom read/write characteristic if present.
            if c.uuid == Self.icomRXCharacteristic || (writeChar == nil && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse))) {
                if c.uuid == Self.icomRXCharacteristic || writeChar == nil { writeChar = c }
            }
            if c.uuid == Self.icomTXCharacteristic || (notifyChar == nil && c.properties.contains(.notify)) {
                if c.uuid == Self.icomTXCharacteristic || notifyChar == nil {
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
        
        // Unblock the awaiting async execution thread
        if let error = error {
            self.clearContinuation(with: .failure(error))
        } else {
            self.clearContinuation(with: .success(data))
        }
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
