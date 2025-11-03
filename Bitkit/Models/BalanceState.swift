import Foundation

/// Represents the calculated balance state including pending transfers
struct BalanceState {
    /// Total on-chain balance in satoshis
    let totalOnchainSats: UInt64

    /// Total Lightning balance in satoshis (excluding pending transfers)
    let totalLightningSats: UInt64

    /// Maximum amount that can be sent via Lightning (outbound capacity)
    let maxSendLightningSats: UInt64

    /// Amount currently being transferred to savings (on-chain)
    let balanceInTransferToSavings: UInt64

    /// Amount currently being transferred to spending (Lightning)
    let balanceInTransferToSpending: UInt64

    /// Total balance combining on-chain and Lightning
    var totalBalanceSats: UInt64 {
        return totalOnchainSats + totalLightningSats
    }

    init(
        totalOnchainSats: UInt64 = 0,
        totalLightningSats: UInt64 = 0,
        maxSendLightningSats: UInt64 = 0,
        balanceInTransferToSavings: UInt64 = 0,
        balanceInTransferToSpending: UInt64 = 0
    ) {
        self.totalOnchainSats = totalOnchainSats
        self.totalLightningSats = totalLightningSats
        self.maxSendLightningSats = maxSendLightningSats
        self.balanceInTransferToSavings = balanceInTransferToSavings
        self.balanceInTransferToSpending = balanceInTransferToSpending
    }
}
