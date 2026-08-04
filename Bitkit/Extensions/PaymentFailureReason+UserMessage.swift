import LDKNode

extension PaymentFailureReason {
    /// User-facing message for a failed payment, mirroring Android's
    /// `PaymentFailureReason.toUserMessage`; reasons without a dedicated string fall back to
    /// the generic payment-failed description.
    static func userMessage(for reason: PaymentFailureReason?) -> String {
        switch reason {
        case .recipientRejected:
            return t("wallet__toast_payment_failed_recipient_rejected")
        case .retriesExhausted:
            return t("wallet__toast_payment_failed_retries_exhausted")
        case .routeNotFound:
            return t("wallet__toast_payment_failed_route_not_found")
        case .paymentExpired:
            return t("wallet__toast_payment_failed_timeout")
        default:
            return t("wallet__toast_payment_failed_description")
        }
    }
}
