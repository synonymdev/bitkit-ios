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
        var timestamp: Date
        var signature: String
    }

    func initWithDefaults() -> CreateOrderOptions {
        return .init(clientBalanceSat: 0, lspNodeId: nil, couponCode: "", turboChannel: false, zeroConfPayment: nil, zeroReserve: false, wakeToOpen: nil)
    }
}
