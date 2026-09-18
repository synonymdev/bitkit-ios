import BitkitCore
import Foundation

/// Why the Bluetooth link to a Jade failed.
///
/// Core hands these texts to the user: a failed open becomes `JadeError.ConnectionError` carrying the
/// text, and any other failure without a transport code becomes `JadeError.TransportError` carrying
/// it. Every case therefore reads as plain, user-facing English.
enum JadeBLEError: LocalizedError, Equatable {
    case invalidPath(String)
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case bluetoothNotReady
    case deviceNotFound
    case connectTimeout
    case connectFailed(String)
    case notAJade
    case subscribeFailed(String)
    case pairingNotConfirmed
    case staleBond
    case notOpen
    case disconnected
    case closed
    case writeTimeout
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid Jade Bluetooth path: \(path)"
        case .bluetoothOff:
            return "Bluetooth is turned off. Turn it on to reach your Jade."
        case .bluetoothUnauthorized:
            return "Bitkit is not allowed to use Bluetooth. Allow it in iOS Settings to reach your Jade."
        case .bluetoothUnsupported:
            return "This device does not support Bluetooth Low Energy."
        case .bluetoothNotReady:
            return "Bluetooth is not ready yet. Try again in a moment."
        case .deviceNotFound:
            return "Your Jade was not found nearby. Make sure it is on and close to your phone."
        case .connectTimeout:
            return "Could not reach your Jade over Bluetooth. Make sure it is on, nearby and not connected to another app."
        case let .connectFailed(reason):
            return "Could not connect to your Jade over Bluetooth (\(Self.detail(reason)))."
        case .notAJade:
            return "This Bluetooth device does not offer the Jade connection service."
        case let .subscribeFailed(reason):
            return "Your Jade did not accept the Bluetooth connection (\(Self.detail(reason)))."
        case .pairingNotConfirmed:
            return "Bluetooth pairing with your Jade was not confirmed. Try again and accept the pairing request."
        case .staleBond:
            return "Bluetooth pairing is no longer valid: forget the Jade in the iOS Bluetooth settings and pair it again."
        case .notOpen:
            return "Jade is not connected."
        case .disconnected, .closed:
            return "Your Jade disconnected."
        case .writeTimeout:
            return "Timed out sending data to your Jade."
        case let .writeFailed(reason):
            return "Sending data to your Jade failed (\(Self.detail(reason)))."
        }
    }

    /// The code core turns into a typed `JadeError`. Nil keeps the text instead: core then reports a
    /// `TransportError` carrying it, which is how the stale pairing advice reaches the user verbatim.
    var transportErrorCode: JadeTransportErrorCode? {
        switch self {
        case .deviceNotFound, .notOpen:
            return .notConnected
        case .connectTimeout, .writeTimeout:
            return .timeout
        case .disconnected, .closed:
            return .disconnected
        case .invalidPath, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported, .bluetoothNotReady, .connectFailed, .notAJade,
             .subscribeFailed, .pairingNotConfirmed, .staleBond, .writeFailed:
            return nil
        }
    }

    private static func detail(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFinalStop = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        return withoutFinalStop.isEmpty ? "unknown error" : withoutFinalStop
    }
}
