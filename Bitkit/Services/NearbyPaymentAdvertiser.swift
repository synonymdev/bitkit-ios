import CoreBluetooth
import Foundation

/// Serves the Receive screen's payment request to nearby phones as a Bluetooth LE GATT server.
///
/// Advertises only the service UUID (no device name) while `start` is in effect. The owner calls `stop`
/// when the Receive screen leaves the foreground or the nearby setting is off. It never asks for Bluetooth
/// permission: it runs only once the user allowed Bluetooth (from a payment scanner's Bluetooth button).
@MainActor
@Observable
final class NearbyPaymentAdvertiser: NSObject {
    private(set) var isAdvertising = false

    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var request: Data?
    @ObservationIgnored private var isServiceAdded = false
    @ObservationIgnored private var isAddingService = false
    /// The request each central started reading, so a request change mid-read cannot mix chunks.
    @ObservationIgnored private var requestsByCentral: [UUID: Data] = [:]
    @ObservationIgnored private let authorization: () -> CBManagerAuthorization

    init(authorization: @escaping () -> CBManagerAuthorization = { CBManager.authorization }) {
        self.authorization = authorization
    }

    /// Whether advertising may start without showing the Bluetooth permission prompt.
    var canAdvertise: Bool {
        authorization() == .allowedAlways
    }

    /// Starts serving `request` (a payment URI), or updates the served request while running.
    func start(request uri: String) {
        guard canAdvertise else {
            stop()
            return
        }
        guard let encoded = NearbyProtocol.encodeRequest(uri) else {
            Logger.warn("Nearby request is empty or too large to serve", context: "NearbyPaymentAdvertiser")
            stop()
            return
        }
        request = encoded
        if let manager {
            publishIfReady(manager)
        } else {
            manager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    func stop() {
        request = nil
        requestsByCentral = [:]
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            manager.delegate = nil
        }
        manager = nil
        isServiceAdded = false
        isAddingService = false
        isAdvertising = false
    }

    private func publishIfReady(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn, request != nil else {
            isAdvertising = false
            return
        }
        guard isServiceAdded else {
            guard !isAddingService else { return }
            isAddingService = true
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
            isAddingService = false
            isAdvertising = false
        }
    }

    private func handleServiceAdded(_ manager: CBPeripheralManager, error: Error?) {
        guard manager === self.manager else { return }
        isAddingService = false
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

    /// Test seam: sets the served request without Bluetooth.
    func setServedRequestForTesting(_ uri: String) {
        request = NearbyProtocol.encodeRequest(uri)
    }

    /// The request a central reads. It is snapshotted when the central reads meta, so its chunks always match the
    /// length it was told, even if Receive changes the request mid-read.
    func servedRequest(for central: UUID, characteristic: CBUUID) -> Data? {
        if characteristic == NearbyProtocol.metaUUID, let request {
            requestsByCentral[central] = request
            return request
        }
        return requestsByCentral[central] ?? request
    }

    private func handleRead(_ manager: CBPeripheralManager, request read: CBATTRequest) {
        let uuid = read.characteristic.uuid
        guard let request = servedRequest(for: read.central.identifier, characteristic: uuid),
              let value = NearbyProtocol.value(for: uuid, request: request)
        else {
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
