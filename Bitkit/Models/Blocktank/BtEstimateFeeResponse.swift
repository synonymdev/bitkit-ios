import Foundation

struct BtEstimateFeeResponse: Codable {
    var feeSat: Int
    var min0ConfTxFee: Bt0ConfMinTxFeeWindow
}