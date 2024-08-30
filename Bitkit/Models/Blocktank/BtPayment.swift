import Foundation

struct BtPayment: Codable {
    var state: BtPaymentState
    var state2: BtPaymentState2
    var paidSat: Int
    var bolt11Invoice: BtBolt11Invoice
    var onchain: BtOnchainTransactions
    var isManuallyPaid: Bool?
}