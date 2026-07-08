import BitkitCore
import Foundation

/// Maps Trezor-related errors to user-facing messages, shared by `TrezorManager` and `TrezorViewModel`.
enum TrezorErrorPresenter {
    static func userMessage(from error: Error) -> String {
        // Classify the typed busy error before falling back to matching the stringified message.
        if error.isTrezorDeviceBusy() {
            return t("hardware__device_busy")
        }

        if let appError = error as? AppError {
            if let debugMessage = appError.debugMessage, !debugMessage.isEmpty {
                return mapMessage(debugMessage)
            }
            return appError.message
        }

        if let trezorError = error as? TrezorError {
            return trezorError.localizedDescription
        }

        if let bleError = error as? TrezorBLEError {
            return bleError.localizedDescription
        }

        if let transportError = error as? TrezorTransportError {
            return transportError.localizedDescription
        }

        let description = error.localizedDescription
        if description == "The operation couldn't be completed." || description.isEmpty {
            return "Connection failed. Please ensure your Trezor is in pairing mode and try again."
        }
        return description
    }

    static func mapMessage(_ message: String) -> String {
        let cleanedMessage = message
            .replacingOccurrences(of: "Transport error: ", with: "")
            .replacingOccurrences(of: "Connection error: ", with: "")
            .replacingOccurrences(of: "Protocol error: ", with: "")
            .replacingOccurrences(of: "Device error: ", with: "")
            .replacingOccurrences(of: "Session error: ", with: "")
            .replacingOccurrences(of: "IO error: ", with: "")

        if message.contains("Stale Bluetooth pairing") || message.contains("Peer removed pairing") {
            return "Stale Bluetooth pairing detected. Go to iOS Settings → Bluetooth, forget your Trezor device, "
                + "then put it back in pairing mode and try again."
        }
        if message.contains("Unable to open device") || message.contains("Failed to connect") {
            return "Failed to connect to Trezor. Please ensure it's in pairing mode and try again."
        }
        if message.contains("Pairing required") {
            return "Bluetooth pairing required. Please put your Trezor in pairing mode."
        }
        if message.contains("Code verification failed") || message.contains("verification failed") {
            return t("hardware__pairing_code_invalid")
        }
        if message.contains("DeviceBusy") || message.contains("Device is busy") {
            return t("hardware__device_busy")
        }
        if message.contains("Pairing failed") || message.contains("Invalid credentials") {
            return "Pairing failed. Please try putting your Trezor back in pairing mode."
        }
        if message.contains("THP handshake failed") {
            return "Connection handshake failed. Please disconnect and try again."
        }
        if message.contains("timed out") || message.contains("Timeout") {
            return "Connection timed out. Please try again."
        }
        if message.contains("Device disconnected") {
            return "Trezor disconnected. Please reconnect and try again."
        }
        if message.contains("Action cancelled") {
            return "Action was cancelled on the device."
        }

        return cleanedMessage
    }
}
