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
        guard let message = hardwareBroadcastRefusalMessage() else { return false }
        // This exact Bitcoin Core replacement refusal only releases navigation, never the receipt.
        let replacementRefusal = "\\Ainsufficient fee, rejecting replacement [0-9a-f]{64}; new feerate [0-9]+\\.[0-9]{8} btc/kvb <= old feerate [0-9]+\\.[0-9]{8} btc/kvb\\z"
        if message.range(of: replacementRefusal, options: .regularExpression) != nil {
            return true
        }
        let reason = hardwareRefusalReason(of: message)
        return [
            "min relay fee not met",
            "mempool min fee not met",
            "bad-txns-inputs-missingorspent",
            "txn-mempool-conflict",
            "non-final",
        ].contains { reason == $0 || reason.hasPrefix($0 + ", ") }
    }

    /// Whether a refused rebroadcast of a hardware send proves the transaction can never confirm anywhere: core cannot decode
    /// it, it breaks consensus, or one of its outputs can never relay. A refusal for fees, mempool limits or anything unread
    /// leaves a valid transaction another node may still confirm.
    func isHardwareBroadcastNeverConfirmable() -> Bool {
        if isDefiniteHardwarePreBroadcastFailure() {
            return true
        }
        guard let message = hardwareBroadcastRefusalMessage() else { return false }
        return hardwareRefusalReason(of: message).matchesRefusalCode(in: [
            "mandatory-script-verify-flag-failed",
            "bad-txns-in-belowout",
            "bad-txns-inputs-duplicate",
            "bad-txns-vout-negative",
            "bad-txns-vout-toolarge",
            "bad-txns-txouttotal-toolarge",
            "bad-txns-oversize",
            "dust",
            "scriptpubkey",
        ])
    }

    /// Whether the node refused a hardware broadcast because one of its coins is missing or already spent, which is also how a
    /// transaction that already confirmed is refused.
    func isHardwareBroadcastInputsMissing() -> Bool {
        guard let message = hardwareBroadcastRefusalMessage() else { return false }
        return hardwareRefusalReason(of: message).matchesRefusalCode(in: ["bad-txns-inputs-missingorspent"])
    }

    /// Whether a hardware broadcast proves it sent nothing: core could not decode the transaction or connect to the server,
    /// or the node refused it for one of the reasons `isHardwareBroadcastRefusal` reads. Any other failure may follow the
    /// write, so the payment may still confirm.
    func isHardwareBroadcastNotSent() -> Bool {
        if isHardwareBroadcastRefusal() {
            return true
        }
        if let error = self as? BroadcastError, case let .ElectrumError(details) = error {
            return details.lowercased().hasPrefix("failed to connect to electrum:")
        }
        if let error = self as? AppError, let underlyingError = error.underlyingError {
            return underlyingError.isHardwareBroadcastNotSent()
        }
        return false
    }

    /// The node's refusal of a hardware broadcast, lowercased and unwrapped from core's and the server's envelopes, or nil
    /// when the failure is not a refusal that can be read.
    private func hardwareBroadcastRefusalMessage() -> String? {
        if let error = self as? BroadcastError, case let .ElectrumError(details) = error {
            let prefix = "broadcast failed: "
            let details = details.lowercased()
            guard details.hasPrefix(prefix) else { return nil }
            var reason = String(details.dropFirst(prefix.count))
            for envelope in ["electrum server error: ", "sendrawtransaction rpc error: "] where reason.hasPrefix(envelope) {
                guard let data = String(reason.dropFirst(envelope.count)).data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
                else { return nil }
                if let message = response as? String {
                    reason = message
                } else if let response = response as? [String: Any], let message = response["message"] as? String {
                    reason = message
                } else {
                    return nil
                }
            }
            for prefix in ["sendrawtransaction rpc error -25: ", "sendrawtransaction rpc error -26: "] where reason.hasPrefix(prefix) {
                reason = String(reason.dropFirst(prefix.count))
            }
            return reason
        }
        if let error = self as? AppError, let underlyingError = error.underlyingError {
            return underlyingError.hardwareBroadcastRefusalMessage()
        }
        return nil
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

private func hardwareRefusalReason(of message: String) -> String {
    let rejectionPrefix = "the transaction was rejected by network rules.\n\n"
    guard message.hasPrefix(rejectionPrefix) else { return message }
    return String(message.dropFirst(rejectionPrefix.count).split(separator: "\n", maxSplits: 1).first ?? "")
}

private extension String {
    func matchesRefusalCode(in codes: [String]) -> Bool {
        codes.contains { self == $0 || hasPrefix($0 + ", ") || hasPrefix($0 + " (") }
    }
}
