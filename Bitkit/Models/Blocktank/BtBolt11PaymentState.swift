import Foundation

enum BtBolt11PaymentState: String, Codable {
    /**
     * Payment attempt is being done now.
     */
    case inflight = "inflight"
    /**
     * Payment confirmed
     */
    case paid = "paid"
    /**
     * Payment failed.
     */
    case failed = "failed"
}