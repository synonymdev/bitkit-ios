import Foundation

enum BtBolt11PaymentState: String, Codable {
    /**
     * Payment attempt is being done now.
     */
    case pending // TODO: called inflight in API??
    /**
     * Payment confirmed
     */
    case paid
    /**
     * Payment failed.
     */
    case failed
}
