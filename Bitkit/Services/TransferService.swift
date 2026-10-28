import BitkitCore
import Foundation
import LDKNode

/// Service for managing transfer operations
class TransferService {
    /// `TransferStorage.insert` rewrites the whole list, so concurrent creations must not interleave.
    private static let creationLock = NSLock()
    private let storage: TransferStorage
    private let lightningService: LightningService
    private let coreService: CoreService

    init(
        storage: TransferStorage = TransferStorage.shared,
        lightningService: LightningService,
        coreService: CoreService = .shared
    ) {
        self.storage = storage
        self.lightningService = lightningService
        self.coreService = coreService
    }

    /// Get all active transfers as a publisher
    /// Note: Unlike Android's Flow, iOS returns array directly. Caller should poll or use Combine if reactive updates needed
    func getActiveTransfers() throws -> [Transfer] {
        return try storage.getActiveTransfers()
    }

    /// Create a new transfer
    func createTransfer(
        type: TransferType,
        amountSats: UInt64,
        channelId: String? = nil,
        fundingTxId: String? = nil,
        claimableAtHeight: UInt32? = nil,
        txTotalSats: UInt64? = nil,
        preTransferOnchainSats: UInt64? = nil
    ) async throws -> String {
        let id = UUID().uuidString
        let createdAt = UInt64(Date().timeIntervalSince1970)

        let transfer = Transfer(
            id: id,
            type: type,
            amountSats: amountSats,
            channelId: channelId,
            fundingTxId: fundingTxId,
            isSettled: false,
            createdAt: createdAt,
            settledAt: nil,
            claimableAtHeight: claimableAtHeight,
            txTotalSats: txTotalSats,
            preTransferOnchainSats: preTransferOnchainSats
        )

        try Self.creationLock.withLock { try storage.insert(transfer) }
        Logger.info("Created transfer: id=\(id) type=\(type) channelId=\(channelId ?? "nil")", context: "TransferService")

        return id
    }

    /// Mark a transfer as settled
    func markSettled(id: String) async throws {
        let settledAt = UInt64(Date().timeIntervalSince1970)
        try storage.markSettled(id: id, settledAt: settledAt)
        Logger.info("Settled transfer: \(id)", context: "TransferService")
    }

    /// Sync transfer states with current channel and balance information
    func syncTransferStates() async throws {
        let activeTransfers = try storage.getActiveTransfers()

        if activeTransfers.isEmpty {
            return
        }

        // Get channels from LightningService (returns [ChannelDetails]? directly)
        let channels = await MainActor.run { lightningService.channels }
        guard let channels else {
            Logger.error("Failed to get channels for transfer sync", context: "TransferService")
            return
        }

        // Get balances from LightningService (returns BalanceDetails? directly)
        let balances = await MainActor.run { lightningService.balances }

        Logger.debug("Syncing \(activeTransfers.count) active transfers", context: "TransferService")

        // Process transfers to spending
        let toSpending = activeTransfers.filter { $0.type.isToSpending() }

        for transfer in toSpending {
            // Blocktank no longer opens channels for paid orders, so an order's transfer is no longer tracked.
            if transfer.lspOrderId != nil {
                try await markSettled(id: transfer.id)
                continue
            }
            if let channelId = transfer.channelId {
                // Associate the funding tx's on-chain activity with the resolved channel so it reads
                // as a transfer (e.g. the hardware-wallet funding tx created before the channel opened).
                if let fundingTxId = transfer.fundingTxId {
                    await coreService.activity.markOnchainActivityAsTransfer(txId: fundingTxId, channelId: channelId)
                }

                // Check if channel is ready (usable)
                if let channel = channels.first(where: { $0.channelId.description == channelId }),
                   channel.isUsable
                {
                    try await markSettled(id: transfer.id)
                    Logger.debug("Channel \(channelId) ready, settled transfer: \(transfer.id)", context: "TransferService")
                } else {
                    Logger.debug("Channel \(channelId) exists but not yet usable for transfer: \(transfer.id)", context: "TransferService")
                }
            }
        }

        // Process transfers to savings
        let toSavings = activeTransfers.filter { $0.type.isToSavings() }

        for transfer in toSavings {
            if let channelId = transfer.channelId {
                let hasBalance = balances?.lightningBalances.contains(where: { balance in
                    balance.channelIdString == channelId
                }) ?? false

                if !hasBalance {
                    // For force closes, only settle when we've detected the on-chain sweep transaction.
                    // This prevents a balance discrepancy where the transfer is removed but the
                    // sweep balance hasn't appeared in the on-chain wallet yet.
                    if transfer.type == .forceClose {
                        let hasOnchainActivity = await coreService.activity.hasOnchainActivityForChannel(channelId: channelId)
                        if hasOnchainActivity {
                            try await markSettled(id: transfer.id)
                            Logger.debug("Force close sweep detected, settled transfer: \(transfer.id)", context: "TransferService")
                        } else {
                            // When LDK batches sweeps from multiple channels into one transaction,
                            // the onchain activity may only be linked to one channel. Fall back to
                            // checking if there are no remaining pending sweep balances for this channel.
                            var sweepSpendingTxid: String?
                            let hasPendingSweep = balances?.pendingBalancesFromChannelClosures.contains(where: { sweep in
                                switch sweep {
                                case let .pendingBroadcast(sweepChannelId, _):
                                    return sweepChannelId == channelId
                                case let .broadcastAwaitingConfirmation(sweepChannelId, _, latestSpendingTxid, _):
                                    if sweepChannelId == channelId {
                                        sweepSpendingTxid = latestSpendingTxid.description
                                        return true
                                    }
                                    return false
                                case let .awaitingThresholdConfirmations(sweepChannelId, latestSpendingTxid, _, _, _):
                                    if sweepChannelId == channelId {
                                        sweepSpendingTxid = latestSpendingTxid.description
                                        return true
                                    }
                                    return false
                                }
                            }) ?? false

                            if !hasPendingSweep {
                                try await markSettled(id: transfer.id)
                                Logger.debug(
                                    "Force close sweep completed (no pending sweeps), settled transfer: \(transfer.id)",
                                    context: "TransferService"
                                )
                            } else if let sweepTxid = sweepSpendingTxid,
                                      await coreService.activity.hasOnchainActivityForTxid(txid: sweepTxid)
                            {
                                // The sweep tx was already synced as an onchain activity (linked to another
                                // channel in the same batched sweep). Safe to settle this transfer.
                                try await markSettled(id: transfer.id)
                                Logger.debug(
                                    "Force close batched sweep detected via txid \(sweepTxid), settled transfer: \(transfer.id)",
                                    context: "TransferService"
                                )
                            } else {
                                Logger.debug("Force close awaiting sweep detection for transfer: \(transfer.id)", context: "TransferService")
                            }
                        }
                    } else {
                        // For coop closes and other types, settle immediately when balance is gone
                        try await markSettled(id: transfer.id)
                        Logger.debug("Channel \(channelId) balance swept, settled transfer: \(transfer.id)", context: "TransferService")
                    }
                }
            }
        }
    }
}
