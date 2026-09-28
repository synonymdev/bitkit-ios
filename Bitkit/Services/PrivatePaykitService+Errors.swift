import Foundation
import LDKNode
import Paykit

enum PrivatePaykitError: LocalizedError {
    case invalidPublicKey
    case privateUnavailable
    case paymentListAlreadyConsumed
    case routeHintsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            "The contact public key is invalid."
        case .privateUnavailable:
            "Private Paykit is not available."
        case .paymentListAlreadyConsumed:
            "Private payment details are no longer available."
        case .routeHintsUnavailable:
            "A reachable private Lightning endpoint is not available yet."
        }
    }
}

enum PaykitResolutionFailureDiagnostics {
    static func reason(for error: Error) -> String {
        if let error = error as? PaykitError {
            return paykitReason(error)
        }
        if let error = error as? PrivatePaykitError {
            return privateReason(error)
        }
        if let error = error as? PublicPaykitError {
            return publicReason(error)
        }
        return "unknown/\(String(reflecting: type(of: error)))"
    }

    private static func paykitReason(_ error: PaykitError) -> String {
        switch error {
        case let .Storage(code, _):
            "storage/\(safeCode(code))"
        case let .Identity(code, _):
            "identity/\(safeCode(code))"
        case let .Transport(code, _):
            "transport/\(safeCode(code))"
        case let .NotFound(code, _):
            "not_found/\(safeCode(code))"
        case let .Protocol(code, _):
            "protocol/\(safeCode(code))"
        case let .Policy(code, _):
            "policy/\(safeCode(code))"
        case let .PaymentAdapter(code, _):
            "payment_adapter/\(safeCode(code))"
        case let .RecoveryRequired(code, _):
            "recovery_required/\(safeCode(code))"
        }
    }

    private static func privateReason(_ error: PrivatePaykitError) -> String {
        switch error {
        case .invalidPublicKey:
            "private/invalid_public_key"
        case .privateUnavailable:
            "private/unavailable"
        case .paymentListAlreadyConsumed:
            "private/payment_list_already_consumed"
        case .routeHintsUnavailable:
            "private/route_hints_unavailable"
        }
    }

    private static func publicReason(_ error: PublicPaykitError) -> String {
        switch error {
        case .noSupportedEndpoint:
            "public/no_supported_endpoint"
        case .walletNotReady:
            "public/wallet_not_ready"
        case .invalidPayload:
            "public/invalid_payload"
        case .routeHintsUnavailable:
            "public/route_hints_unavailable"
        case .publicationFailed:
            "public/publication_failed"
        }
    }

    private static func safeCode(_ code: String) -> String {
        guard !code.isEmpty,
              code.utf8.count <= 64,
              code.utf8.allSatisfy({ byte in
                  byte == 45 || byte == 95 || (48 ... 57).contains(byte) || (97 ... 122).contains(byte)
              })
        else { return "unknown_code" }
        return code
    }
}

// MARK: - Error Helpers

extension PrivatePaykitService {
    static func isDuplicatePaymentError(_ error: Error) -> Bool {
        if let nodeError = error as? NodeError, case .DuplicatePayment = nodeError {
            return true
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
}
