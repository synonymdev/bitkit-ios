import Foundation

struct CreateOrderOptions_OLD: Codable {
    var clientBalanceSat: UInt64
    var lspNodeId: String?
    var couponCode: String
    var source: String?
    var discountCode: String?
    var zeroConf: Bool // Turbo channel
    var zeroConfPayment: Bool?
    var zeroReserve: Bool
    var wakeToOpen: WakeToOpen?
    var nodeId: String?
    var refundOnchainAddress: String?

    struct WakeToOpen: Codable {
        var nodeId: String
        var timestamp: String
        var signature: String
    }

    static func initWithDefaults() -> CreateOrderOptions_OLD {
        return .init(clientBalanceSat: 0, lspNodeId: nil, couponCode: "", source: "bitkit-ios", zeroConf: false, zeroConfPayment: nil, zeroReserve: false, wakeToOpen: nil)
    }
}
