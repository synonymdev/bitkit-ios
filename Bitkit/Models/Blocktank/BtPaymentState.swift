import Foundation

enum BtPaymentState: String, Codable {
    case created = "created"
    case partiallyPaid = "partiallyPaid"
    case paid = "paid"
    case refunded = "refunded"
    case refundAvailable = "refundAvailable"
}