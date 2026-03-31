import CoreBluetooth
import Foundation
import Observation

/// Manages CoreBluetooth operations for Trezor BLE devices
/// Handles device discovery, connection, and GATT communication
@Observable
class TrezorBLEManager: NSObject {
    static let shared = TrezorBLEManager()

    // MARK: - BLE Constants

    /// Trezor BLE Service UUID
    static let serviceUUID = CBUUID(string: "8c000001-a59b-4d58-a9ad-073df69fa1b1")
    /// Write Characteristic UUID (for sending data to device)
    static let writeCharUUID = CBUUID(string: "8c000002-a59b-4d58-a9ad-073df69fa1b1")
    /// Notify Characteristic UUID (for receiving data from device)
    static let notifyCharUUID = CBUUID(string: "8c000003-a59b-4d58-a9ad-073df69fa1b1")
    /// Client Characteristic Configuration Descriptor UUID (for enabling notifications)
    static let cccdUUID = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")
    /// BLE chunk size for Trezor THP protocol
    static let chunkSize: UInt32 = 244

    // MARK: - Timeouts

    private static let connectionTimeoutSeconds: TimeInterval = 30
    private static let discoveryTimeoutSeconds: TimeInterval = 10
    private static let readTimeoutSeconds: TimeInterval = 5
    private static let writeTimeoutSeconds: TimeInterval = 5
    /// Number of write retry attempts (matching Android's BLE_WRITE_RETRY_COUNT)
    private static let writeMaxAttempts = 3
    /// Delay between write retry attempts (matching Android's BLE_WRITE_RETRY_DELAY_MS)
    private static let writeRetryDelayNs: UInt64 = 100_000_000
    /// Inter-write delay for BLE stability (20ms between writes)
    private static let writeInterDelayNs: UInt64 = 20_000_000

    // MARK: - Properties

    private var centralManager: CBCentralManager?
    private let centralQueue = DispatchQueue(label: "trezor.ble.central", qos: .userInteractive)

    /// Discovered peripherals keyed by device path (ble:{identifier})
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private let peripheralsLock = NSLock()

    /// Currently connected peripheral
    private var connectedPeripheral: CBPeripheral?
    private var connectedPath: String?

    /// GATT characteristics
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    /// Queue for received notification data chunks
    private var readQueue = BlockingQueue<Data>()

    /// Continuation for connection completion
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectionError: Error?

    /// Continuation for write completion
    private var writeContinuation: CheckedContinuation<Void, Error>?

    /// Continuation for service discovery
    private var serviceDiscoveryContinuation: CheckedContinuation<Void, Error>?

    /// Lock protecting all continuation properties from concurrent access.
    /// Timeouts fire on DispatchQueue.global() while delegate callbacks fire on
    /// centralQueue — without synchronization both can resume the same continuation.
    private let continuationLock = NSLock()

    // MARK: - Continuation Helpers

    /// Atomically take and nil-out a continuation so it can only be resumed once.
    private func takeConnectContinuation() -> CheckedContinuation<Void, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let cont = connectContinuation
        connectContinuation = nil
        return cont
    }

    private func takeWriteContinuation() -> CheckedContinuation<Void, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let cont = writeContinuation
        writeContinuation = nil
        return cont
    }

    private func takeServiceDiscoveryContinuation() -> CheckedContinuation<Void, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let cont = serviceDiscoveryContinuation
        serviceDiscoveryContinuation = nil
        return cont
    }

    private func takeNotificationContinuation() -> CheckedContinuation<Void, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let cont = notificationContinuation
        notificationContinuation = nil
        return cont
    }

    /// Atomically store a continuation.
    private func setConnectContinuation(_ cont: CheckedContinuation<Void, Error>) {
        continuationLock.lock()
        connectContinuation = cont
        continuationLock.unlock()
    }

    private func setWriteContinuation(_ cont: CheckedContinuation<Void, Error>) {
        continuationLock.lock()
        writeContinuation = cont
        continuationLock.unlock()
    }

    private func setServiceDiscoveryContinuation(_ cont: CheckedContinuation<Void, Error>) {
        continuationLock.lock()
        serviceDiscoveryContinuation = cont
        continuationLock.unlock()
    }

    private func setNotificationContinuation(_ cont: CheckedContinuation<Void, Error>) {
        continuationLock.lock()
        notificationContinuation = cont
        continuationLock.unlock()
    }

    // MARK: - Observable State

    private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    private(set) var isScanning: Bool = false
    private(set) var bluetoothState: CBManagerState = .unknown

    // MARK: - Initialization

    private override init() {
        super.init()
        // CBCentralManager is created lazily via ensureStarted() to avoid
        // triggering the BLE stack and permission dialogs at app launch.
    }

    /// Create CBCentralManager on first use. Must be called before any BLE operation.
    func ensureStarted() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(delegate: self, queue: centralQueue)
    }

    // MARK: - Debug Logging

    /// Log to both Logger and in-app TrezorDebugLog
    private func debugLog(_ message: String) {
        Logger.debug(message, context: "TrezorBLEManager")
        Task { @MainActor in
            TrezorDebugLog.shared.log("[BLE] \(message)")
        }
    }

    // MARK: - Scanning

    /// Start scanning for Trezor BLE devices
    func startScanning() {
        ensureStarted()

        guard centralManager?.state == .poweredOn else {
            debugLog("Cannot scan: BT not powered on (state: \(centralManager?.state.rawValue ?? -1))")
            return
        }

        guard !isScanning else {
            debugLog("Already scanning")
            return
        }

        debugLog("Scan started")

        peripheralsLock.lock()
        discoveredPeripherals.removeAll()
        peripheralsLock.unlock()

        Task { @MainActor in
            self.discoveredDevices.removeAll()
            self.isScanning = true
        }

        centralManager?.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Stop scanning for devices
    func stopScanning() {
        guard isScanning else { return }

        debugLog("Scan stopped")
        centralManager?.stopScan()

        Task { @MainActor in
            self.isScanning = false
        }
    }

    /// Get all discovered devices as NativeDeviceInfo for FFI
    func enumerateDevices() -> [DiscoveredBLEDevice] {
        peripheralsLock.lock()
        defer { peripheralsLock.unlock() }
        return discoveredDevices
    }

    // MARK: - Connection

    /// Continuation for notification state change
    private var notificationContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Connection Retry Configuration

    private static let connectMaxAttempts = 3

    /// Connect to a BLE device by path with automatic retry
    /// After force-quit, the Trezor may drop the first connection while cleaning up
    /// stale state from the previous app session. Retrying after a delay allows the
    /// Trezor to finish cleanup and accept a stable connection.
    /// - Parameter path: Device path in format "ble:{identifier}"
    func connect(path: String) async throws {
        guard path.hasPrefix("ble:") else {
            throw TrezorBLEError.invalidPath(path)
        }

        var lastError: Error = TrezorBLEError.connectionFailed

        for attempt in 1 ... Self.connectMaxAttempts {
            do {
                debugLog("Connect attempt \(attempt)/\(Self.connectMaxAttempts) for \(path)")
                try await connectOnce(path: path)
                debugLog("Connect attempt \(attempt) succeeded")
                return // Success
            } catch {
                lastError = error
                debugLog("Connect attempt \(attempt)/\(Self.connectMaxAttempts) failed: \(error.localizedDescription)")

                // Don't retry "Peer removed pairing information" — requires user action
                // (forget device in iOS Settings → Bluetooth)
                if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
                    debugLog("Stale iOS bonding detected — user must forget device in Settings")
                    throw TrezorBLEError.pairingInformationRemoved
                }

                // Clean up before retry
                cleanupConnectionState()

                if attempt < Self.connectMaxAttempts {
                    // Increasing delay: 1s, 2s — gives Trezor time to clean up stale state
                    let delaySeconds = UInt64(attempt)
                    try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                }
            }
        }

        throw lastError
    }

    /// Clean up connection state without clearing the discoveredPeripherals cache
    /// This preserves the freshly-scanned peripheral reference for reconnection
    private func cleanupConnectionState() {
        if let existingPeripheral = connectedPeripheral {
            if let notifyChar = notifyCharacteristic {
                existingPeripheral.setNotifyValue(false, for: notifyChar)
            }
            centralManager?.cancelPeripheralConnection(existingPeripheral)
        }
        connectedPeripheral = nil
        connectedPath = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        readQueue.clear()
    }

    /// Single connection attempt — performs the full BLE connection sequence
    private func connectOnce(path: String) async throws {
        // Clean up any stale connection state (preserves discoveredPeripherals cache)
        cleanupConnectionState()

        debugLog("connectOnce: \(path)")

        // Try to get peripheral from cache first
        var peripheral: CBPeripheral?

        peripheralsLock.lock()
        peripheral = discoveredPeripherals[path]
        peripheralsLock.unlock()

        // If not in cache, try retrieving by UUID (works for previously bonded devices)
        if peripheral == nil {
            let uuidString = path.replacingOccurrences(of: "ble:", with: "")
            if let uuid = UUID(uuidString: uuidString) {
                let retrieved = centralManager?.retrievePeripherals(withIdentifiers: [uuid]) ?? []
                peripheral = retrieved.first
                if let p = peripheral {
                    peripheralsLock.lock()
                    discoveredPeripherals[path] = p
                    peripheralsLock.unlock()
                    debugLog("Retrieved peripheral by UUID: \(path)")
                }
            }
        }

        guard let peripheral = peripheral else {
            debugLog("Peripheral not found in cache or by UUID: \(path)")
            throw TrezorBLEError.deviceNotFound(path)
        }

        debugLog("Peripheral found: \(peripheral.identifier) state=\(peripheral.state.rawValue)")

        // Handle stale or transitioning OS-level connection from previous app session
        // After force-quit, iOS may keep the BLE connection alive briefly. Connecting
        // to an already-connected peripheral can produce a stale GATT session that
        // the Trezor then drops. Cancel it first and wait for disconnect to complete.
        if peripheral.state == .connected || peripheral.state == .connecting {
            debugLog("Cancelling stale connection (state: \(peripheral.state.rawValue))")
            centralManager?.cancelPeripheralConnection(peripheral)
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms for disconnect to complete
        }

        // Step 1: Connect to peripheral
        debugLog("CBConnect starting...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setConnectContinuation(continuation)
            self.connectionError = nil

            centralManager?.connect(peripheral, options: nil)

            // Set up timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.connectionTimeoutSeconds) { [weak self] in
                self?.takeConnectContinuation()?.resume(throwing: TrezorBLEError.connectionTimeout)
            }
        }

        connectedPeripheral = peripheral
        connectedPath = path
        peripheral.delegate = self

        // Step 2: Get MTU (synchronous on iOS — no delegate callback needed)
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        debugLog("MTU: \(mtu) bytes")

        // Step 3: Discover services and characteristics
        debugLog("Discovering services...")
        try await discoverServicesAndCharacteristics(peripheral: peripheral)

        // Step 4: Enable notifications and wait for confirmation
        guard let notifyChar = notifyCharacteristic else {
            throw TrezorBLEError.characteristicNotFound("notify")
        }

        debugLog("Enabling notifications...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setNotificationContinuation(continuation)
            peripheral.setNotifyValue(true, for: notifyChar)

            // Timeout for notification enable
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                // Don't fail, just continue
                self?.takeNotificationContinuation()?.resume()
            }
        }

        // Step 5: Stabilization delay (like Android's BLE_CONNECTION_STABILIZATION_MS)
        // Keep this short (500ms) to avoid delaying the THP handshake start —
        // the Trezor may timeout if the handshake doesn't begin promptly.
        debugLog("Stabilization (500ms)...")
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        guard connectedPeripheral != nil, connectedPeripheral?.state == .connected else {
            debugLog("Connection LOST during stabilization")
            throw TrezorBLEError.connectionFailed
        }

        debugLog("Connection READY: \(path)")
    }

    private func discoverServicesAndCharacteristics(peripheral: CBPeripheral) async throws {
        // Discover Trezor service
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setServiceDiscoveryContinuation(continuation)
            peripheral.discoverServices([Self.serviceUUID])

            // Timeout for service discovery
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.discoveryTimeoutSeconds) { [weak self] in
                self?.takeServiceDiscoveryContinuation()?.resume(throwing: TrezorBLEError.serviceNotFound)
            }
        }

        // Get the Trezor service
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            throw TrezorBLEError.serviceNotFound
        }

        // Discover characteristics
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setServiceDiscoveryContinuation(continuation)
            peripheral.discoverCharacteristics([Self.writeCharUUID, Self.notifyCharUUID], for: service)

            // Timeout for characteristic discovery
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.discoveryTimeoutSeconds) { [weak self] in
                self?.takeServiceDiscoveryContinuation()?.resume(throwing: TrezorBLEError.characteristicNotFound("discovery timeout"))
            }
        }

        // Get characteristics
        guard let characteristics = service.characteristics else {
            throw TrezorBLEError.characteristicNotFound("any")
        }

        writeCharacteristic = characteristics.first(where: { $0.uuid == Self.writeCharUUID })
        notifyCharacteristic = characteristics.first(where: { $0.uuid == Self.notifyCharUUID })

        guard writeCharacteristic != nil else {
            throw TrezorBLEError.characteristicNotFound("write")
        }
        guard notifyCharacteristic != nil else {
            throw TrezorBLEError.characteristicNotFound("notify")
        }

        debugLog("Found write and notify characteristics")
    }

    /// Disconnect from currently connected device
    func disconnect(path: String) {
        guard path == connectedPath, let peripheral = connectedPeripheral else {
            debugLog("Disconnect ignored (not connected): \(path)")
            return
        }

        debugLog("Disconnecting: \(path)")

        if let notifyChar = notifyCharacteristic {
            peripheral.setNotifyValue(false, for: notifyChar)
        }

        centralManager?.cancelPeripheralConnection(peripheral)

        connectedPeripheral = nil
        connectedPath = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        readQueue.clear()
    }

    // MARK: - Read/Write Operations

    /// Read a chunk from the device (blocks until data received or timeout)
    /// - Parameter path: Device path
    /// - Returns: Data chunk read from device
    func readChunk(path: String) throws -> Data {
        guard path == connectedPath else {
            debugLog("readChunk: not connected")
            throw TrezorBLEError.notConnected
        }

        // Block waiting for notification data
        guard let data = readQueue.poll(timeout: Self.readTimeoutSeconds) else {
            debugLog("readChunk: TIMEOUT")
            throw TrezorBLEError.readTimeout
        }

        debugLog("readChunk: \(data.count) bytes")
        return data
    }

    /// Write a chunk to the device with retry logic.
    ///
    /// BLE writes use `.withResponse`, so a timeout means the data was NOT
    /// delivered to the device (the GATT stack guarantees delivery confirmation).
    /// Retrying is therefore safe — the device never received the previous attempt.
    /// This matches Android's `BLE_WRITE_RETRY_COUNT = 3` pattern.
    ///
    /// - Parameters:
    ///   - path: Device path
    ///   - data: Data chunk to write
    func writeChunk(path: String, data: Data) async throws {
        guard path == connectedPath, let peripheral = connectedPeripheral else {
            debugLog("writeChunk: not connected")
            throw TrezorBLEError.notConnected
        }

        // Validate connection state (prevents writes to stale peripherals)
        guard peripheral.state == .connected else {
            debugLog("writeChunk: peripheral state=\(peripheral.state.rawValue)")
            throw TrezorBLEError.notConnected
        }

        guard let writeChar = writeCharacteristic else {
            throw TrezorBLEError.characteristicNotFound("write")
        }

        var lastError: Error = TrezorBLEError.writeTimeout

        for attempt in 1 ... Self.writeMaxAttempts {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.setWriteContinuation(continuation)

                    peripheral.writeValue(data, for: writeChar, type: .withResponse)

                    // Set up timeout
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.writeTimeoutSeconds) { [weak self] in
                        self?.takeWriteContinuation()?.resume(throwing: TrezorBLEError.writeTimeout)
                    }
                }

                // Success — apply inter-write delay for BLE stability
                try await Task.sleep(nanoseconds: Self.writeInterDelayNs)
                return
            } catch {
                lastError = error
                debugLog("writeChunk attempt \(attempt)/\(Self.writeMaxAttempts) failed: \(error.localizedDescription)")

                // Only retry timeout errors — non-timeout errors (e.g. disconnection)
                // indicate an unrecoverable state
                guard case TrezorBLEError.writeTimeout = error else {
                    throw error
                }

                if attempt < Self.writeMaxAttempts {
                    try await Task.sleep(nanoseconds: Self.writeRetryDelayNs)
                }
            }
        }

        throw lastError
    }

}

// MARK: - CBCentralManagerDelegate

extension TrezorBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugLog("BT state: \(central.state.rawValue)")

        Task { @MainActor in
            self.bluetoothState = central.state
        }

        if central.state != .poweredOn && isScanning {
            Task { @MainActor in
                self.isScanning = false
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber)
    {
        let path = "ble:\(peripheral.identifier.uuidString)"
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String

        debugLog("didDiscover: \(name ?? "Unknown") \(path) RSSI=\(RSSI)")

        peripheralsLock.lock()
        discoveredPeripherals[path] = peripheral

        let device = DiscoveredBLEDevice(
            path: path,
            name: name,
            identifier: peripheral.identifier
        )

        // Update on main thread
        Task { @MainActor in
            if let index = self.discoveredDevices.firstIndex(where: { $0.path == path }) {
                self.discoveredDevices[index] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
        peripheralsLock.unlock()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debugLog("didConnect: \(peripheral.identifier)")

        takeConnectContinuation()?.resume()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugLog("didFailToConnect: \(peripheral.identifier) error: \(error?.localizedDescription ?? "Unknown")")

        takeConnectContinuation()?.resume(throwing: error ?? TrezorBLEError.connectionFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debugLog("didDisconnect: \(peripheral.identifier)\(error.map { " error: \($0.localizedDescription)" } ?? "")")

        let disconnectError = error ?? TrezorBLEError.connectionFailed

        // Resume any pending continuations so they fail-fast instead of hanging
        takeConnectContinuation()?.resume(throwing: disconnectError)
        takeServiceDiscoveryContinuation()?.resume(throwing: disconnectError)
        takeNotificationContinuation()?.resume(throwing: disconnectError)
        takeWriteContinuation()?.resume(throwing: disconnectError)

        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
            connectedPath = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            readQueue.clear()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension TrezorBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            debugLog("didDiscoverServices FAILED: \(error.localizedDescription)")
            takeServiceDiscoveryContinuation()?.resume(throwing: error)
        } else {
            debugLog("didDiscoverServices: \(peripheral.services?.count ?? 0) services")
            takeServiceDiscoveryContinuation()?.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            debugLog("didDiscoverCharacteristics FAILED: \(error.localizedDescription)")
            takeServiceDiscoveryContinuation()?.resume(throwing: error)
        } else {
            debugLog("didDiscoverCharacteristics: \(service.characteristics?.count ?? 0) chars")
            takeServiceDiscoveryContinuation()?.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            debugLog("didUpdateValue ERROR: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == Self.notifyCharUUID, let data = characteristic.value else {
            return
        }

        debugLog("didUpdateValue: \(data.count) bytes")
        readQueue.offer(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            debugLog("didWriteValue FAILED: \(error.localizedDescription)")
            takeWriteContinuation()?.resume(throwing: error)
        } else {
            takeWriteContinuation()?.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            debugLog("didUpdateNotificationState FAILED: \(error.localizedDescription)")
            takeNotificationContinuation()?.resume(throwing: error)
        } else {
            debugLog("didUpdateNotificationState: \(characteristic.uuid) isNotifying=\(characteristic.isNotifying)")
            takeNotificationContinuation()?.resume()
        }
    }
}

// MARK: - Supporting Types

/// Represents a discovered BLE Trezor device
struct DiscoveredBLEDevice: Identifiable, Equatable {
    let path: String
    let name: String?
    let identifier: UUID

    var id: String { path }
}

/// Errors specific to BLE operations
enum TrezorBLEError: LocalizedError {
    case invalidPath(String)
    case deviceNotFound(String)
    case connectionFailed
    case connectionTimeout
    case notConnected
    case serviceNotFound
    case characteristicNotFound(String)
    case pairingInformationRemoved
    case readTimeout
    case writeTimeout
    case writeFailed

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid BLE device path: \(path)"
        case let .deviceNotFound(path):
            return "Device not found: \(path)"
        case .connectionFailed:
            return "Failed to connect to Trezor"
        case .connectionTimeout:
            return "Connection to Trezor timed out"
        case .notConnected:
            return "Not connected to Trezor"
        case .pairingInformationRemoved:
            return "Stale Bluetooth pairing. Go to iOS Settings → Bluetooth, forget your Trezor device, then put it back in pairing mode and try again."
        case .serviceNotFound:
            return "Trezor BLE service not found"
        case let .characteristicNotFound(name):
            return "Trezor BLE characteristic not found: \(name)"
        case .readTimeout:
            return "Timed out waiting for Trezor response"
        case .writeTimeout:
            return "Timed out sending data to Trezor"
        case .writeFailed:
            return "Failed to send data to Trezor"
        }
    }
}

// MARK: - BlockingQueue

/// Thread-safe blocking queue for BLE notification data
private class BlockingQueue<T> {
    private var queue: [T] = []
    private let lock = NSCondition()

    func offer(_ item: T) {
        lock.lock()
        queue.append(item)
        lock.signal()
        lock.unlock()
    }

    func poll(timeout: TimeInterval) -> T? {
        lock.lock()
        defer { lock.unlock() }

        let deadline = Date().addingTimeInterval(timeout)

        while queue.isEmpty {
            if !lock.wait(until: deadline) {
                return nil // Timeout
            }
        }

        return queue.removeFirst()
    }

    func clear() {
        lock.lock()
        queue.removeAll()
        lock.unlock()
    }
}
