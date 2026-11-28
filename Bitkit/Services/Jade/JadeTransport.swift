import BitkitCore
import Combine
import Foundation

/// The app's side of the Jade links, next to core's own use of the same transport.
protocol JadeTransportControlling: AnyObject, Sendable {
    /// Paths whose link dropped without the app closing it.
    var externalDisconnects: AnyPublisher<String, Never> { get }
    /// Fires when Bluetooth turns back on after having been off.
    var bluetoothPoweredOn: AnyPublisher<Void, Never> { get }

    /// Closes the link to `path` off the main thread, waiting briefly for the disconnect.
    func disconnectDevice(path: String) async
    func closeAllConnections() async
    /// Cancels every link without waiting. Safe to call on the main thread.
    func releaseAllImmediately()
    func setPairedPaths(_ paths: Set<String>)
}

/// The byte pipe between core's Jade protocol and Bluetooth.
///
/// Core owns the CBOR framing, the pinserver exchange and every deadline; this only moves bytes over
/// the Nordic UART Service. Core calls every callback on one of its blocking threads, so blocking here
/// is expected, and the results carry plain text core shows to the user.
final class JadeTransport: JadeTransportCallback, JadeTransportControlling, @unchecked Sendable {
    static let shared = JadeTransport(driver: JadeBLEManager.shared)

    private static let minimumScanDuration: TimeInterval = 0.5
    private static let maximumScanDuration: TimeInterval = 15
    private static let logContext = "JadeBLE"
    /// jade-client-rs `MAX_CHUNK_BYTES`, which its own serial transport uses too.
    private static let serialChunkSize: UInt32 = 509

    private let driver: JadeBLEDriving
    private let emulator: JadeEmulatorLink
    private let isTrezorBridgeEnabled: () -> Bool
    private let emulatorDisconnects = PassthroughSubject<String, Never>()

    init(
        driver: JadeBLEDriving,
        emulator: JadeEmulatorLink = .shared,
        isTrezorBridgeEnabled: @escaping () -> Bool = { Env.trezorBridgeEnabled }
    ) {
        self.driver = driver
        self.emulator = emulator
        self.isTrezorBridgeEnabled = isTrezorBridgeEnabled
    }

    var externalDisconnects: AnyPublisher<String, Never> {
        driver.externalDisconnects.merge(with: emulatorDisconnects).eraseToAnyPublisher()
    }

    var bluetoothPoweredOn: AnyPublisher<Void, Never> {
        driver.bluetoothPoweredOn
    }

    static func scanDuration(timeoutMs: UInt32) -> TimeInterval {
        min(max(Double(timeoutMs) / 1000, minimumScanDuration), maximumScanDuration)
    }

    static func errorCode(for error: Error) -> JadeTransportErrorCode? {
        (error as? JadeBLEError)?.transportErrorCode
    }

    // MARK: - JadeTransportControlling

    func disconnectDevice(path: String) async {
        if emulator.isEmulatorPath(path) {
            emulator.closeDevice(path: path)
            return
        }
        await runOffMainThread { $0.close(path: path) }
    }

    func closeAllConnections() async {
        emulator.closeAll()
        await runOffMainThread { $0.closeAll() }
    }

    func releaseAllImmediately() {
        emulator.closeAll()
        driver.releaseAllImmediately()
    }

    func setPairedPaths(_ paths: Set<String>) {
        driver.setPairedPaths(paths)
    }

    /// A closed emulator socket counts as the Jade going away, as a dropped Bluetooth link does.
    private func onEmulatorResult(path: String, errorCode: JadeTransportErrorCode?) {
        guard errorCode == .disconnected else { return }
        emulatorDisconnects.send(path)
    }

    // MARK: - JadeTransportCallback

    func scanDevices(timeoutMs: UInt32) -> [JadeNativeDevice] {
        // Bridge and emulator runs (journeys and E2E) have no Jade nearby, and in the simulator the central
        // never powers on, so a Bluetooth scan would only add its wait to every search pass.
        if emulator.enabled {
            return emulator.scanDevices()
        }
        guard !isTrezorBridgeEnabled() else {
            Logger.debug("Skipped the Jade Bluetooth scan while the Trezor Bridge is enabled", context: Self.logContext)
            return []
        }
        let discoveries = driver.scan(duration: Self.scanDuration(timeoutMs: timeoutMs))
        Logger.info("Found \(discoveries.count) Jade device(s)", context: Self.logContext)
        return discoveries.map {
            JadeNativeDevice(path: $0.path, transport: .bluetooth, name: $0.name, serialNumber: nil)
        }
    }

    func openDevice(path: String) -> JadeTransportResult {
        if emulator.isEmulatorPath(path) {
            return emulator.open(path: path)
        }
        do {
            try driver.open(path: path)
            return Self.success
        } catch {
            return Self.failure(error)
        }
    }

    func closeDevice(path: String) -> JadeTransportResult {
        if emulator.isEmulatorPath(path) {
            return emulator.closeDevice(path: path)
        }
        driver.close(path: path)
        return Self.success
    }

    func writeChunk(path: String, data: Data) -> JadeTransportResult {
        if emulator.isEmulatorPath(path) {
            let result = emulator.write(path: path, data: data)
            onEmulatorResult(path: path, errorCode: result.errorCode)
            return result
        }
        do {
            try driver.write(path: path, data: data)
            return Self.success
        } catch {
            Logger.warn("Jade write of \(data.count) bytes failed: \(error.localizedDescription)", context: Self.logContext)
            return Self.failure(error)
        }
    }

    func readChunk(path: String, timeoutMs: UInt32) -> JadeTransportReadResult {
        if emulator.isEmulatorPath(path) {
            let result = emulator.read(path: path, timeoutMs: timeoutMs)
            onEmulatorResult(path: path, errorCode: result.errorCode)
            return result
        }
        do {
            let data = try driver.read(path: path, timeout: Double(timeoutMs) / 1000)
            return JadeTransportReadResult(success: true, data: data, error: "", errorCode: nil)
        } catch {
            return JadeTransportReadResult(success: false, data: Data(), error: error.localizedDescription, errorCode: Self.errorCode(for: error))
        }
    }

    func getChunkSize(path: String) -> UInt32 {
        if emulator.isEmulatorPath(path) {
            return Self.serialChunkSize
        }
        return driver.chunkSize(path: path)
    }

    // MARK: - Helpers

    private static let success = JadeTransportResult(success: true, error: "", errorCode: nil)

    private static func failure(_ error: Error) -> JadeTransportResult {
        JadeTransportResult(success: false, error: error.localizedDescription, errorCode: errorCode(for: error))
    }

    private func runOffMainThread(_ work: @escaping (JadeBLEDriving) -> Void) async {
        let driver = driver
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                work(driver)
                continuation.resume()
            }
        }
    }
}
