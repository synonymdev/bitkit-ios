import Foundation

/// Confirm total for the spending transfer screen: the amount of bitcoin that leaves the wallet.
enum SpendingConfirmTotal {
    /// When send-all funds the order, the sweep spends `maxSendable + networkFee` (the spendable balance).
    /// Otherwise the total is the order fee plus the miner fee.
    static func leavingAmount(
        orderFeeSat: UInt64,
        networkFeeSat: UInt64,
        shouldUseSendAll: Bool,
        maxSendable: UInt64?
    ) -> UInt64 {
        if shouldUseSendAll, let maxSendable {
            return maxSendable.saturatingAdd(networkFeeSat)
        }
        return orderFeeSat.saturatingAdd(networkFeeSat)
    }
}
