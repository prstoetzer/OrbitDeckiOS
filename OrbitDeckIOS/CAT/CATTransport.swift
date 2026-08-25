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
        lock.lock(); connected = false; lock.unlock()
        finishConnect(.failure(error ?? CATError.notConnected))
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
