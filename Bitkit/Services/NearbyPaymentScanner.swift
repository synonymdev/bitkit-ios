import CoreBluetooth
import Foundation
import UIKit

/// Reads a payment request from the closest Bitkit phone showing its Receive screen over Bluetooth LE.
///
/// Scans for the nearby service while a payment scanner is open, connects to the strongest advertiser at
/// or above `NearbyProtocol.minRssi`, reads meta and the needed chunks, disconnects and delivers the request
/// once. A peripheral is not retried for `retryInterval` after an attempt.
@MainActor
final class NearbyPaymentScanner: NSObject, ObservableObject {
    @Published private(set) var authorization: CBManagerAuthorization = CBManager.authorization
    @Published private(set) var isScanning = false

    nonisolated static let retryInterval: TimeInterval = 10
    private static let selectionWindow: TimeInterval = 0.3
    private static let connectTimeout: TimeInterval = 8

    private var central: CBCentralManager?
    private var onRequest: ((String) async -> Void)?
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var lastAttempts: [UUID: Date] = [:]
    private var selectionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var connected: CBPeripheral?
    private var expectedLength: Int?
    private var chunks: [Data] = []

    var isAuthorized: Bool {
        authorization == .allowedAlways
    }

    /// Starts scanning when Bluetooth is already authorized. It never prompts; see `requestAuthorization`.
    func start(onRequest: @escaping (String) async -> Void) {
        self.onRequest = onRequest
        authorization = CBManager.authorization
        guard isAuthorized else { return }
        startCentral()
    }

    func stop() {
        onRequest = nil
        selectionTask?.cancel()
        selectionTask = nil
        disconnect()
        if let central {
            if central.state == .poweredOn {
                central.stopScan()
            }
            central.delegate = nil
        }
        central = nil
        candidates = [:]
        isScanning = false
    }

    /// Asks for Bluetooth permission, or opens Settings when it was denied before.
    func requestAuthorization() {
        authorization = CBManager.authorization
        switch authorization {
        case .notDetermined:
            // Creating the manager shows the system prompt; scanning starts once it is allowed.
            startCentral()
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            startCentral()
        }
    }

    private func startCentral() {
        if let central {
            scanIfReady(central)
        } else {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    private func scanIfReady(_ central: CBCentralManager) {
        guard central.state == .poweredOn, onRequest != nil, connected == nil else {
            isScanning = false
            return
        }
        central.scanForPeripherals(
            withServices: [NearbyProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
    }

    private func handleStateUpdate(_ central: CBCentralManager) {
        guard central === self.central else { return }
        authorization = CBManager.authorization
        if central.state == .poweredOn {
            scanIfReady(central)
        } else {
            isScanning = false
        }
    }

    private func handleDiscovery(_ peripheral: CBPeripheral, rssi: Int) {
        guard connected == nil, Self.isEligible(rssi: rssi),
              !Self.isDebounced(lastAttempts[peripheral.identifier], now: Date())
        else { return }
        if let existing = candidates[peripheral.identifier], existing.rssi >= rssi {
            return
        }
        candidates[peripheral.identifier] = (peripheral, rssi)
        guard selectionTask == nil else { return }
        selectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.selectionWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connectToStrongest()
        }
    }

    nonisolated static func isEligible(rssi: Int) -> Bool {
        // CoreBluetooth reports 127 when the RSSI is unavailable.
        rssi >= NearbyProtocol.minRssi && rssi < 127
    }

    nonisolated static func isDebounced(_ lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return false }
        return now.timeIntervalSince(lastAttempt) < retryInterval
    }

    private func connectToStrongest() {
        selectionTask = nil
        guard let central, connected == nil,
              let best = candidates.values.max(by: { $0.rssi < $1.rssi })
        else { return }
        candidates = [:]
        let peripheral = best.peripheral
        lastAttempts[peripheral.identifier] = Date()
        connected = peripheral
        expectedLength = nil
        chunks = []
        central.stopScan()
        isScanning = false
        peripheral.delegate = self
        central.connect(peripheral)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fail("timed out")
        }
    }

    private func fail(_ reason: String) {
        Logger.warn("Nearby read failed: \(reason)", context: "NearbyPaymentScanner")
        disconnect()
        if let central {
            scanIfReady(central)
        }
    }

    private func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let connected {
            connected.delegate = nil
            central?.cancelPeripheralConnection(connected)
        }
        connected = nil
        expectedLength = nil
        chunks = []
    }

    private func characteristic(_ uuid: CBUUID, of peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?
            .first { $0.uuid == NearbyProtocol.serviceUUID }?
            .characteristics?
            .first { $0.uuid == uuid }
    }

    private func readNext(_ peripheral: CBPeripheral) {
        guard let length = expectedLength else {
            guard let meta = characteristic(NearbyProtocol.metaUUID, of: peripheral) else {
                return fail("missing meta characteristic")
            }
            peripheral.readValue(for: meta)
            return
        }
        if chunks.count < NearbyProtocol.chunks(for: length) {
            guard let data = characteristic(NearbyProtocol.dataUUIDs[chunks.count], of: peripheral) else {
                return fail("missing data characteristic \(chunks.count)")
            }
            peripheral.readValue(for: data)
            return
        }
        guard let request = NearbyProtocol.decode(chunks: chunks, length: length) else {
            return fail("request does not match its announced length")
        }
        deliver(request)
    }

    private func deliver(_ request: String) {
        let onRequest = onRequest
        // One request per scanner session: stop before handing it over.
        stop()
        Task { await onRequest?(request) }
    }

    private func handleValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === connected else { return }
        if let error {
            return fail(error.localizedDescription)
        }
        let value = characteristic.value ?? Data()
        if characteristic.uuid == NearbyProtocol.metaUUID {
            guard let length = NearbyProtocol.requestLength(meta: value) else {
                return fail("unsupported meta")
            }
            expectedLength = length
        } else {
            chunks.append(value)
        }
        readNext(peripheral)
    }
}

/// The manager delivers callbacks on the main queue (queue: nil), so they run on the main actor.
extension NearbyPaymentScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { handleStateUpdate(central) }
    }

    nonisolated func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData _: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { handleDiscovery(peripheral, rssi: rssi) }
    }

    nonisolated func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === connected else { return }
            peripheral.discoverServices([NearbyProtocol.serviceUUID])
        }
    }

    nonisolated func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "connection failed"
        MainActor.assumeIsolated {
            guard peripheral === connected else { return }
            fail(reason)
        }
    }

    nonisolated func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connected else { return }
            fail("disconnected before the request was read")
        }
    }
}

extension NearbyPaymentScanner: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let reason = error?.localizedDescription
        MainActor.assumeIsolated {
            guard peripheral === connected else { return }
            if let reason {
                return fail(reason)
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == NearbyProtocol.serviceUUID }) else {
                return fail("service not found")
            }
            peripheral.discoverCharacteristics([NearbyProtocol.metaUUID] + NearbyProtocol.dataUUIDs, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor _: CBService, error: Error?) {
        let reason = error?.localizedDescription
        MainActor.assumeIsolated {
            guard peripheral === connected else { return }
            if let reason {
                return fail(reason)
            }
            readNext(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleValue(peripheral, characteristic: characteristic, error: error) }
    }
}
