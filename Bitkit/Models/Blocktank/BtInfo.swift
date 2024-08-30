import Foundation

struct BtInfo: Codable {
    var version: Int
    var nodes: [LspNode]
    var options: Options
    var versions: Versions
    var onchain: Onchain

    struct Options: Codable {
        var minChannelSizeSat: Int
        var maxChannelSizeSat: Int
        var minExpiryWeeks: Int
        var maxExpiryWeeks: Int
        var minPaymentConfirmations: Int
        var minHighRiskPaymentConfirmations: Int
        var max0ConfClientBalanceSat: Int
        var maxClientBalanceSat: Int
    }

    struct Versions: Codable {
        var http: String
        var btc: String
        var ln2: String
    }

    struct Onchain: Codable {
        var network: BitcoinNetworkEnum
        var feeRates: FeeRates

        struct FeeRates: Codable {
            var fast: Int
            var mid: Int
            var slow: Int
        }
    }
}