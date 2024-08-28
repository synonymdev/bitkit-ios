import Foundation

struct BtOnchainTransaction: Codable {
    var amountSat: Int
    var txId: String
    var vout: Int
    var blockHeight: Int?
    var blockConfirmationCount: Int
    var feeRateSatPerVbyte: Int
    var confirmed: Bool
    var suspicious0ConfReason: String
}
