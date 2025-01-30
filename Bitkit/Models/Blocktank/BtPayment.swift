import Foundation

struct BtPayment: Codable {
    var state: BtPaymentState_OLD
    var state2: BtPaymentState2_OLD
    var paidSat: Int
    var bolt11Invoice: BtBolt11Invoice
    var onchain: BtOnchainTransactions
    var isManuallyPaid: Bool?
}
