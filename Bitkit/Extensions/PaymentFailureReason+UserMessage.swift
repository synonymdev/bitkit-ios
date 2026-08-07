import LDKNode

extension PaymentFailureReason {
    enum UserMessageContext {
        case generic
        case send
    }

    /// User-facing message for a failed payment, mirroring Android's
    /// `PaymentFailureReason.toUserMessage`; reasons without a dedicated string fall back to
    /// the generic payment-failed description.
    static func userMessage(for reason: PaymentFailureReason?, context: UserMessageContext = .generic) -> String {
        t(userMessageKey(for: reason, context: context))
    }

    static func userMessageKey(for reason: PaymentFailureReason?, context: UserMessageContext = .generic) -> String {
        switch reason {
        case .recipientRejected:
            return "wallet__payment_recipient_rejected"
        case .userAbandoned:
            return "wallet__payment_abandoned"
        case .retriesExhausted:
            switch context {
            case .generic:
                return "wallet__payment_retries_exhausted"
            case .send:
                return "wallet__send_payment_retries_exhausted"
            }
        case .paymentExpired:
            return "wallet__payment_expired"
        case .routeNotFound:
            switch context {
            case .generic:
                return "wallet__payment_route_not_found"
            case .send:
                return "wallet__send_payment_route_not_found"
            }
        case .unknownRequiredFeatures:
            return "wallet__payment_unknown_required_features"
        case .invoiceRequestExpired:
            return "wallet__payment_invoice_request_expired"
        case .invoiceRequestRejected:
            return "wallet__payment_invoice_request_rejected"
        default:
            switch context {
            case .generic, .send:
                return "wallet__payment_failed_description"
            }
        }
    }
}
