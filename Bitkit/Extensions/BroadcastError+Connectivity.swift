import BitkitCore
import Foundation

extension BroadcastError {
    /// Whether this broadcast failure is likely transient connectivity (retry without re-signing).
    /// Core 0.4.1 maps both Electrum connect failures and node rejections to `ElectrumError`; rejections
    /// must not be treated as connectivity until core splits the variant (see bitkit-core).
    var isConnectivityFailure: Bool {
        switch self {
        case .InvalidHex, .InvalidTransaction:
            return false
        case .TaskError:
            return true
        case let .ElectrumError(errorDetails):
            return Self.isElectrumConnectivityDetails(errorDetails)
        }
    }

    private static func isElectrumConnectivityDetails(_ details: String) -> Bool {
        let lower = details.lowercased()
        if lower.hasPrefix("broadcast failed:") {
            return false
        }
        if lower.hasPrefix("failed to connect to electrum:") {
            return true
        }
        if lower.contains("offline")
            || lower.contains("timeout")
            || lower.contains("connection refused")
            || lower.contains("dns")
            || lower.contains("network")
        {
            return true
        }
        return false
    }
}

extension Error {
    func isBroadcastConnectivityFailure() -> Bool {
        if let broadcastError = self as? BroadcastError {
            return broadcastError.isConnectivityFailure
        }

        if let appError = self as? AppError, let underlyingError = appError.underlyingError {
            return underlyingError.isBroadcastConnectivityFailure()
        }

        return false
    }
}
