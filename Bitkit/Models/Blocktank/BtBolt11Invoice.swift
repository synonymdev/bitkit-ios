import Foundation

struct BtBolt11Invoice: Codable {
    var request: String
    var state: BtBolt11PaymentState
    var expiresAt: String
    var updatedAt: String
}