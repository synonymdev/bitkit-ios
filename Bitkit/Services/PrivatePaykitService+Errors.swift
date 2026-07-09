import Foundation
import LDKNode

enum PrivatePaykitError: LocalizedError {
    case privateUnavailable
    case routeHintsUnavailable

    var errorDescription: String? {
        switch self {
        case .privateUnavailable:
            "Private Paykit is not available."
        case .routeHintsUnavailable:
            "A reachable private Lightning endpoint is not available yet."
        }
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
