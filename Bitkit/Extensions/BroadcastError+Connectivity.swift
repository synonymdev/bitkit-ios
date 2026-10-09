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
    func isDefiniteHardwarePreBroadcastFailure() -> Bool {
        if let error = self as? BroadcastError {
            switch error {
            case .InvalidHex, .InvalidTransaction:
                return true
            default:
                return false
            }
        }
        if let error = self as? AppError, let underlyingError = error.underlyingError {
            return underlyingError.isDefiniteHardwarePreBroadcastFailure()
        }
        return false
    }

    func isHardwareBroadcastRefusal() -> Bool {
        if isDefiniteHardwarePreBroadcastFailure() {
            return true
        }
        if let error = self as? BroadcastError, case let .ElectrumError(details) = error {
            let prefix = "broadcast failed: "
            let details = details.lowercased()
            guard details.hasPrefix(prefix) else { return false }
            var reason = String(details.dropFirst(prefix.count))
            for envelope in ["electrum server error: ", "sendrawtransaction rpc error: "] where reason.hasPrefix(envelope) {
                guard let data = String(reason.dropFirst(envelope.count)).data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = response["message"] as? String
                else { return false }
                reason = message
            }
            let rejectionPrefix = "the transaction was rejected by network rules.\n\n"
            if reason.hasPrefix(rejectionPrefix) {
                reason = String(reason.dropFirst(rejectionPrefix.count).split(separator: "\n", maxSplits: 1).first ?? "")
            }
            return [
                "min relay fee not met",
                "mempool min fee not met",
                "bad-txns-inputs-missingorspent",
                "txn-mempool-conflict",
                "non-final",
            ].contains { reason == $0 || reason.hasPrefix($0 + ", ") }
        }
        if let error = self as? AppError, let underlyingError = error.underlyingError {
            return underlyingError.isHardwareBroadcastRefusal()
        }
        return false
    }

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
