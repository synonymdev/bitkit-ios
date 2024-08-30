import Foundation

enum BtOrderState2: String, Codable {
    case created = "created"
    case expired = "expired"
    case executed = "executed"
    case paid = "paid"
}