import Foundation

/// Metadata for onchain transactions that needs to be temporarily stored
/// until it can be applied to activities during sync operations
struct TransactionMetadata: Codable, Identifiable {
    /// Transaction ID (also serves as the unique identifier)
    let txId: String

    /// Fee rate in satoshis per vbyte
    let feeRate: UInt64

    /// Destination address
    let address: String

    /// Whether this transaction is a transfer between wallets (e.g., channel funding)
    let isTransfer: Bool

    /// Associated channel ID for channel funding transactions
    let channelId: String?

    /// Timestamp when this metadata was created (for cleanup purposes)
    let createdAt: UInt64

    var id: String { txId }

    init(
        txId: String,
        feeRate: UInt64,
        address: String,
        isTransfer: Bool,
        channelId: String? = nil,
        createdAt: UInt64
    ) {
        self.txId = txId
        self.feeRate = feeRate
        self.address = address
        self.isTransfer = isTransfer
        self.channelId = channelId
        self.createdAt = createdAt
    }
}
