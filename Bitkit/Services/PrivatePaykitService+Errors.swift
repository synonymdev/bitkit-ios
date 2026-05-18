import Foundation
import LDKNode
import Paykit

enum PrivatePaykitError: LocalizedError {
    case privateUnavailable
    case payloadTooLarge
    case staleLinkState
    case routeHintsUnavailable

    var errorDescription: String? {
        switch self {
        case .privateUnavailable:
            "Private Paykit is not available."
        case .payloadTooLarge:
            "The private Paykit payload is too large."
        case .staleLinkState:
            "The private Paykit link state changed."
        case .routeHintsUnavailable:
            "A reachable private Lightning endpoint is not available yet."
        }
    }
}

// MARK: - Error Classification

extension PrivatePaykitService {
    static func isDuplicatePaymentError(_ error: Error) -> Bool {
        if let nodeError = error as? NodeError {
            if case .DuplicatePayment = nodeError {
                return true
            }
        }

        let reason: String = if let appError = error as? AppError {
            [appError.message, appError.debugMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        } else {
            "\(error.localizedDescription) \(String(describing: error))"
        }

        let lowercasedReason = reason.lowercased()
        return lowercasedReason.contains("duplicate payment") || lowercasedReason.contains("duplicatepayment")
    }

    func shouldCountAsStaleLinkFailure(_ error: Error) -> Bool {
        if let paykitError = error as? PaykitFfiError {
            switch paykitError {
            case let .Transport(reason):
                return isNoiseStateFailure(reason) || isEncryptedLinkStateFailure(reason)
            case let .InvalidData(reason), let .NotFound(reason), let .Validation(reason):
                return isEncryptedLinkStateFailure(reason)
            case .Session:
                return false
            }
        }

        let wrappedReason = staleLinkFailureReason(from: error)
        return isNoiseStateFailure(wrappedReason) || isEncryptedLinkStateFailure(wrappedReason)
    }

    func staleLinkFailureReason(from error: Error) -> String {
        if let appError = error as? AppError {
            return [appError.message, appError.debugMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        }

        return error.localizedDescription
    }

    func isNoiseStateFailure(_ reason: String) -> Bool {
        let lowercasedReason = reason.lowercased()
        return [
            "decrypt",
            "decryption",
            "cipher",
            "invalid tag",
            "bad mac",
        ].contains { lowercasedReason.contains($0) }
    }

    func isEncryptedLinkStateFailure(_ reason: String) -> Bool {
        let lowercasedReason = reason.lowercased()
        return [
            "unknown encrypted-link handle",
            "unknown encrypted link handle",
            "encrypted-link handle is closed",
            "encrypted link handle is closed",
            "failed to restore encrypted link",
            "encrypted link restore requires transport-phase snapshot",
            "remote_pubkey does not match snapshot recipient",
        ].contains { lowercasedReason.contains($0) }
    }

    func isEncryptedHandshakeStateFailure(_ error: Error) -> Bool {
        let lowercasedReason = staleLinkFailureReason(from: error).lowercased()
        return isNoiseStateFailure(lowercasedReason) ||
            isEncryptedLinkStateFailure(lowercasedReason) ||
            [
                "restoreplayerror",
                "handshake restore failed",
            ].contains { lowercasedReason.contains($0) }
    }

    func isEncryptedHandshakePendingError(_ error: Error) -> Bool {
        let lowercasedReason = staleLinkFailureReason(from: error).lowercased()
        return lowercasedReason.contains("transition_transport failed") &&
            lowercasedReason.contains("ishandshake")
    }
}
