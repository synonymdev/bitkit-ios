import Foundation

enum BtPaymentState2: String, Codable {
    /**
     * Ready to receive payments
     */
    case created = "created"
    /**
     * Order is paid
     */
    case paid = "paid"
    /**
     * Order is refunded.
     */
    case refunded = "refunded"
    /**
     * Onchain refunds can't be done automatically. `refundAvailable` is displayed in this case.
     */
    case refundAvailable = "refundAvailable" // Onchain refund available
    /**
     * Payments not possible anymore.
     */
    case canceled = "canceled"
}