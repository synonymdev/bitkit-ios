import LDKNode

extension PaymentFailureReason {
    /// User-facing message for a failed payment, mirroring Android's
    /// `PaymentFailureReason.toUserMessage`; reasons without a dedicated string fall back to
    /// the generic payment-failed description.
    static func userMessage(for reason: PaymentFailureReason?) -> String {
        t(userMessageKey(for: reason))
    }

    static func userMessageKey(for reason: PaymentFailureReason?) -> String {
        switch reason {
        case .recipientRejected:
            return "wallet__payment_recipient_rejected"
        case .userAbandoned:
            return "wallet__payment_abandoned"
        case .retriesExhausted:
            return "wallet__payment_retries_exhausted"
        case .paymentExpired:
            return "wallet__payment_expired"
        case .routeNotFound:
            return "wallet__payment_route_not_found"
        case .unknownRequiredFeatures:
            return "wallet__payment_unknown_required_features"
        case .invoiceRequestExpired:
            return "wallet__payment_invoice_request_expired"
        case .invoiceRequestRejected:
            return "wallet__payment_invoice_request_rejected"
        default:
            return "wallet__payment_failed_description"
        }
    }

    var shouldResetRoutingCachesOnRetry: Bool {
        switch self {
        case .routeNotFound, .retriesExhausted:
            return true
        default:
            return false
        }
    }
}
