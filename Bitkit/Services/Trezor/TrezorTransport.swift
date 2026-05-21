import BitkitCore
import Combine
import CoreBluetooth
import Foundation

/// Implementation of TrezorTransportCallback protocol
/// Coordinates BLE and USB transports for Trezor device communication
final class TrezorTransport: TrezorTransportCallback {
    static let shared = TrezorTransport()

    private let bleManager = TrezorBLEManager.shared

    // MARK: - Pairing Code Handling

    /// Subject to notify UI when pairing code is needed
    let needsPairingCodePublisher = PassthroughSubject<Void, Never>()

    private var submittedPairingCode: String = ""
    private let pairingCodeLock = NSLock()

    /// Timeout for pairing code entry (2 minutes)
    private static let pairingCodeTimeoutSeconds: TimeInterval = 120

    private init() {}

    // MARK: - Debug Logging

    /// Log to both Logger and in-app TrezorDebugLog
    private func debugLog(_ message: String) {
        Logger.debug(message, context: "TrezorTransport")
        TrezorDebugLog.shared.log("[FFI] \(message)")
    }

    // MARK: - TrezorTransportCallback Implementation

    /// Enumerate all connected/discovered Trezor devices
    func enumerateDevices() -> [NativeDeviceInfo] {
        let bleDevices = bleManager.enumerateDevices()
        let devices = bleDevices.map { device in
            NativeDeviceInfo(
                path: device.path,
                transportType: "bluetooth",
                name: device.name,
                vendorId: nil,
                productId: nil
            )
        }

        debugLog("enumerateDevices: \(devices.count) devices")

        return devices
    }

    /// Open a connection to a device
    func openDevice(path: String) -> TrezorTransportWriteResult {
        debugLog("openDevice: \(path)")

        do {
            guard path.hasPrefix("ble:") else {
                throw TrezorTransportError.invalidPath(path)
            }

            // Synchronously start async connection
            // Note: This blocks the calling thread which is expected by Rust
            let semaphore = DispatchSemaphore(value: 0)
            var connectionError: Error?

            Task {
                do {
                    try await bleManager.connect(path: path)
                } catch {
                    connectionError = error
                }
                semaphore.signal()
            }

            semaphore.wait()

            if let error = connectionError {
                throw error
            }

            return TrezorTransportWriteResult(success: true, error: "")
        } catch {
            debugLog("openDevice FAILED: \(error.localizedDescription)")
            return TrezorTransportWriteResult(success: false, error: error.localizedDescription)
        }
    }

    /// Close a connection to a device
    func closeDevice(path: String) -> TrezorTransportWriteResult {
        debugLog("closeDevice: \(path)")

        guard path.hasPrefix("ble:") else {
            return TrezorTransportWriteResult(success: false, error: "Invalid device path: \(path)")
        }

        bleManager.disconnect(path: path)
        return TrezorTransportWriteResult(success: true, error: "")
    }

    /// Read a chunk of data from the device
    func readChunk(path: String) -> TrezorTransportReadResult {
        do {
            guard path.hasPrefix("ble:") else {
                throw TrezorTransportError.invalidPath(path)
            }

            let data = try bleManager.readChunk(path: path)
            debugLog("readChunk: \(data.count) bytes")

            return TrezorTransportReadResult(success: true, data: data, error: "")
        } catch {
            debugLog("readChunk FAILED: \(error.localizedDescription)")
            return TrezorTransportReadResult(success: false, data: Data(), error: error.localizedDescription)
        }
    }

    /// Write a chunk of data to the device
    func writeChunk(path: String, data: Data) -> TrezorTransportWriteResult {
        debugLog("writeChunk: \(data.count) bytes")

        do {
            guard path.hasPrefix("ble:") else {
                throw TrezorTransportError.invalidPath(path)
            }

            // Synchronously run async write
            let semaphore = DispatchSemaphore(value: 0)
            var writeError: Error?

            Task {
                do {
                    try await bleManager.writeChunk(path: path, data: data)
                } catch {
                    writeError = error
                }
                semaphore.signal()
            }

            semaphore.wait()

            if let error = writeError {
                throw error
            }

            return TrezorTransportWriteResult(success: true, error: "")
        } catch {
            debugLog("writeChunk FAILED: \(error.localizedDescription)")
            return TrezorTransportWriteResult(success: false, error: error.localizedDescription)
        }
    }

    /// Get the chunk size for a device
    func getChunkSize(path: String) -> UInt32 {
        return TrezorBLEManager.chunkSize // 244 bytes for BLE
    }

    /// Called by rust-trezor to delegate full message call to native transport
    /// This is an optional optimization - return nil to have Rust handle it
    func callMessage(path: String, messageType: UInt16, data: Data) -> TrezorCallMessageResult? {
        // Let Rust handle the message protocol
        // We only provide the raw transport layer
        return nil
    }

    /// Get the pairing code from the user (blocks until user enters code)
    /// This is called when the Trezor displays a 6-digit code for BLE pairing
    func getPairingCode() -> String {
        debugLog("getPairingCode: waiting for user input...")

        pairingCodeLock.lock()
        submittedPairingCode = ""
        pairingCodeLock.unlock()

        // Notify UI to show pairing code dialog
        DispatchQueue.main.async {
            self.needsPairingCodePublisher.send()
        }

        // Block and wait for user to enter code
        let code = blockForPairingCode()

        debugLog("getPairingCode: \(code.isEmpty ? "cancelled/empty" : "received")")

        return code
    }

    /// Semaphore signalled when pairing code is submitted or cancelled
    private let pairingCodeSemaphore = DispatchSemaphore(value: 0)

    /// Blocking wait for pairing code with timeout
    private func blockForPairingCode() -> String {
        let timeout = DispatchTime.now() + Self.pairingCodeTimeoutSeconds
        let result = pairingCodeSemaphore.wait(timeout: timeout)

        if result == .timedOut {
            return ""
        }

        pairingCodeLock.lock()
        let code = submittedPairingCode
        pairingCodeLock.unlock()

        return code
    }

    /// Called by UI when user submits pairing code
    func submitPairingCode(_ code: String) {
        debugLog("submitPairingCode")

        pairingCodeLock.lock()
        submittedPairingCode = code
        pairingCodeLock.unlock()

        pairingCodeSemaphore.signal()
    }

    /// Cancel pairing code entry
    func cancelPairingCode() {
        debugLog("cancelPairingCode")

        pairingCodeLock.lock()
        submittedPairingCode = ""
        pairingCodeLock.unlock()

        pairingCodeSemaphore.signal()
    }

    /// Save THP credential to secure storage
    /// An empty credential string indicates a clear request
    func saveThpCredential(deviceId: String, credentialJson: String) -> Bool {
        // Empty credential means "clear" - delete the stored credential
        if credentialJson.isEmpty {
            debugLog("saveThpCredential: CLEAR device=\(deviceId)")
            TrezorCredentialStorage.delete(deviceId: deviceId)
            return true
        }

        debugLog("saveThpCredential: device=\(deviceId) len=\(credentialJson.count)")
        let result = TrezorCredentialStorage.save(deviceId: deviceId, json: credentialJson)
        debugLog("saveThpCredential: \(result ? "OK" : "FAILED")")
        return result
    }

    /// Forward Rust-level debug messages to Logger and TrezorDebugLog
    func logDebug(tag: String, message: String) {
        Logger.debug("[\(tag)] \(message)", context: "TrezorTransport")
        TrezorDebugLog.shared.log("[\(tag)] \(message)")
    }

    /// Load THP credential from secure storage
    func loadThpCredential(deviceId: String) -> String? {
        debugLog("loadThpCredential: device=\(deviceId)")

        // List all stored credentials for debugging
        let allDevices = TrezorCredentialStorage.listAllDeviceIds()
        debugLog("loadThpCredential: stored IDs=\(allDevices)")

        let credential = TrezorCredentialStorage.load(deviceId: deviceId)
        debugLog("loadThpCredential: \(credential != nil ? "FOUND len=\(credential!.count)" : "NOT FOUND")")
        return credential
    }


    // MARK: - Device Scanning Helpers

    /// Start scanning for BLE devices
    func startBLEScanning() {
        bleManager.startScanning()
    }

    /// Stop scanning for BLE devices
    func stopBLEScanning() {
        bleManager.stopScanning()
    }

    /// Get Bluetooth state
    var bluetoothState: CBManagerState {
        bleManager.bluetoothState
    }

}

// MARK: - Transport Errors

enum TrezorTransportError: LocalizedError {
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid device path: \(path)"
        }
    }
}
