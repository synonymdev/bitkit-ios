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

    private let driver: JadeBLEDriving
    private let isTrezorBridgeEnabled: () -> Bool

    init(driver: JadeBLEDriving, isTrezorBridgeEnabled: @escaping () -> Bool = { Env.trezorBridgeEnabled }) {
        self.driver = driver
        self.isTrezorBridgeEnabled = isTrezorBridgeEnabled
    }

    var externalDisconnects: AnyPublisher<String, Never> {
        driver.externalDisconnects
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
        await runOffMainThread { $0.close(path: path) }
    }

    func closeAllConnections() async {
        await runOffMainThread { $0.closeAll() }
    }

    func releaseAllImmediately() {
        driver.releaseAllImmediately()
    }

    func setPairedPaths(_ paths: Set<String>) {
        driver.setPairedPaths(paths)
    }

    // MARK: - JadeTransportCallback

    func scanDevices(timeoutMs: UInt32) -> [JadeNativeDevice] {
        // Bridge runs (journeys and E2E) have no Jade nearby, and in the simulator the central never powers
        // on, so a Bluetooth scan would only add its wait to every search pass.
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
        do {
            try driver.open(path: path)
            return Self.success
        } catch {
            return Self.failure(error)
        }
    }

    func closeDevice(path: String) -> JadeTransportResult {
        driver.close(path: path)
        return Self.success
    }

    func writeChunk(path: String, data: Data) -> JadeTransportResult {
        do {
            try driver.write(path: path, data: data)
            return Self.success
        } catch {
            Logger.warn("Jade write of \(data.count) bytes failed: \(error.localizedDescription)", context: Self.logContext)
            return Self.failure(error)
        }
    }

    func readChunk(path: String, timeoutMs: UInt32) -> JadeTransportReadResult {
        do {
            let data = try driver.read(path: path, timeout: Double(timeoutMs) / 1000)
            return JadeTransportReadResult(success: true, data: data, error: "", errorCode: nil)
        } catch {
            return JadeTransportReadResult(success: false, data: Data(), error: error.localizedDescription, errorCode: Self.errorCode(for: error))
        }
    }

    func getChunkSize(path: String) -> UInt32 {
        driver.chunkSize(path: path)
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
