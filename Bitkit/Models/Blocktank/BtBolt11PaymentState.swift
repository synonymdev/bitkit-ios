import Foundation

enum BtBolt11PaymentState: String, Codable {
    /**
     * Payment attempt is being done now.
     */
    case pending
    
    /**
     * Payment received but not confirmed/rejected yet. Only possible with HODL invoices.
     */
    case holding
    
    /**
     * Payment confirmed
     */
    case paid
    /**
     * Payment failed.
     */
    case canceled
}
