import Foundation

enum BtPaymentState2_OLD: String, Codable {
    /**
     * Ready to receive payments
     */
    case created
    /**
     * Order is paid
     */
    case paid
    /**
     * Order is refunded.
     */
    case refunded
    /**
     * Onchain refunds can't be done automatically. `refundAvailable` is displayed in this case.
     */
    case refundAvailable // Onchain refund available
    /**
     * Payments not possible anymore.
     */
    case canceled
}
