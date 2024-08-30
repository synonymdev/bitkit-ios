import Foundation 

struct BtOnchainTransactions: Codable {
    var address: String
    var confirmedSat: Int
    var requiredConfirmations: Int
    var transactions: [BtOnchainTransaction]
}