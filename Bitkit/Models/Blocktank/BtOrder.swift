import Foundation

struct BtOrder: Codable {
    var id: String
    var state: BtOrderState_OLD
    var state2: BtOrderState2_OLD
    var feeSat: UInt64
    var lspBalanceSat: Int
    var clientBalanceSat: Int
    var zeroConf: Bool
    var zeroReserve: Bool
    var wakeToOpenNodeId: String?
    var channelExpiryWeeks: Int
    var channelExpiresAt: String
    var orderExpiresAt: String
    var channel: BtChannel?
    var lspNode: LspNode
    var lnurl: String?
    var payment: BtPayment
    var couponCode: String?
    var source: String?
    var discount: Discount?
    var updatedAt: String
    var createdAt: String
}
