import CoreBluetooth
import Foundation

/// Serves the Receive screen's payment request to nearby phones as a Bluetooth LE GATT server.
///
/// Advertises only the service UUID (no device name) while `start` is in effect. The owner calls `stop`
/// when the Receive screen leaves the foreground or the nearby setting is off.
@MainActor
final class NearbyPaymentAdvertiser: NSObject, ObservableObject {
    @Published private(set) var isAdvertising = false

    private var manager: CBPeripheralManager?
    private var request: Data?
    private var isServiceAdded = false

    /// Starts serving `request` (a payment URI), or updates the served request while running.
    func start(request uri: String) {
        guard let encoded = NearbyProtocol.encodeRequest(uri) else {
            Logger.warn("Nearby request is empty or too large to serve", context: "NearbyPaymentAdvertiser")
            stop()
            return
        }
        request = encoded
        if let manager {
            publishIfReady(manager)
        } else {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        request = nil
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            manager.delegate = nil
        }
        manager = nil
        isServiceAdded = false
        isAdvertising = false
    }

    private func publishIfReady(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn, request != nil else {
            isAdvertising = false
            return
        }
        guard isServiceAdded else {
            manager.add(Self.makeService())
            return
        }
        if !manager.isAdvertising {
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [NearbyProtocol.serviceUUID]])
        }
    }

    private static func makeService() -> CBMutableService {
        let service = CBMutableService(type: NearbyProtocol.serviceUUID, primary: true)
        service.characteristics = ([NearbyProtocol.metaUUID] + NearbyProtocol.dataUUIDs).map {
            CBMutableCharacteristic(type: $0, properties: [.read], value: nil, permissions: [.readable])
        }
        return service
    }

    private func handleStateUpdate(_ manager: CBPeripheralManager) {
        guard manager === self.manager else { return }
        if manager.state == .poweredOn {
            publishIfReady(manager)
        } else {
            isServiceAdded = false
            isAdvertising = false
        }
    }

    private func handleServiceAdded(_ manager: CBPeripheralManager, error: Error?) {
        guard manager === self.manager else { return }
        if let error {
            Logger.error(error, context: "Nearby GATT service")
            return
        }
        isServiceAdded = true
        publishIfReady(manager)
    }

    private func handleAdvertisingStarted(_ manager: CBPeripheralManager, error: Error?) {
        guard manager === self.manager else { return }
        if let error {
            Logger.error(error, context: "Nearby advertising")
            isAdvertising = false
            return
        }
        isAdvertising = request != nil
    }

    private func handleRead(_ manager: CBPeripheralManager, request read: CBATTRequest) {
        guard let request, let value = NearbyProtocol.value(for: read.characteristic.uuid, request: request) else {
            manager.respond(to: read, withResult: .attributeNotFound)
            return
        }
        guard let served = NearbyProtocol.read(value, at: read.offset) else {
            manager.respond(to: read, withResult: .invalidOffset)
            return
        }
        read.value = served
        manager.respond(to: read, withResult: .success)
    }
}

/// The manager delivers callbacks on the main queue (queue: nil), so they run on the main actor.
extension NearbyPaymentAdvertiser: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { handleStateUpdate(peripheral) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd _: CBService, error: Error?) {
        MainActor.assumeIsolated { handleServiceAdded(peripheral, error: error) }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated { handleAdvertisingStarted(peripheral, error: error) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated { handleRead(peripheral, request: request) }
    }
}
