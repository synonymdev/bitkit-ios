import Foundation

struct CreateOrderOptions: Codable {
    var clientBalanceSat: Int
    var lspNodeId: String?
    var couponCode: String
    var source: String?
    var discountCode: String?
    var turboChannel: Bool
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

    static func initWithDefaults() -> CreateOrderOptions {
        return .init(clientBalanceSat: 0, lspNodeId: nil, couponCode: "", source: "bitkit-ios", turboChannel: false, zeroConfPayment: nil, zeroReserve: false, wakeToOpen: nil)
    }
}
