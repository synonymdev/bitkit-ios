import Foundation

enum BtPaymentState_OLD: String, Codable {
    case created = "created"
    case partiallyPaid = "partiallyPaid"
    case paid = "paid"
    case refunded = "refunded"
    case refundAvailable = "refundAvailable"
}
