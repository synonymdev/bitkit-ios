import Foundation

struct Transfer: Codable, Identifiable {
    let id: String
    let type: TransferType
    let amountSats: UInt64
    let channelId: String?
    let fundingTxId: String?
    let lspOrderId: String?
    let isSettled: Bool
    let createdAt: UInt64
    let settledAt: UInt64?
    let claimableAtHeight: UInt32?
    /// Total sats deducted from on-chain (amount + fee). Used to subtract from displayed on-chain until LDK updates.
    let txTotalSats: UInt64?
    /// On-chain balance before the tx was sent. If current >= this, LDK has not yet reflected the tx.
    let preTransferOnchainSats: UInt64?

    init(
        id: String,
        type: TransferType,
        amountSats: UInt64,
        channelId: String? = nil,
        fundingTxId: String? = nil,
        lspOrderId: String? = nil,
        isSettled: Bool = false,
        createdAt: UInt64,
        settledAt: UInt64? = nil,
        claimableAtHeight: UInt32? = nil,
        txTotalSats: UInt64? = nil,
        preTransferOnchainSats: UInt64? = nil
    ) {
        self.id = id
        self.type = type
        self.amountSats = amountSats
        self.channelId = channelId
        self.fundingTxId = fundingTxId
        self.lspOrderId = lspOrderId
        self.isSettled = isSettled
        self.createdAt = createdAt
        self.settledAt = settledAt
        self.claimableAtHeight = claimableAtHeight
        self.txTotalSats = txTotalSats
        self.preTransferOnchainSats = preTransferOnchainSats
    }
}
