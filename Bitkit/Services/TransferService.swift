import BitkitCore
import Foundation
import LDKNode

/// Service for managing transfer operations
class TransferService {
    private let storage: TransferStorage
    private let lightningService: LightningService
    private let blocktankService: BlocktankService
    private let coreService: CoreService

    init(
        storage: TransferStorage = TransferStorage.shared,
        lightningService: LightningService,
        blocktankService: BlocktankService,
        coreService: CoreService = .shared
    ) {
        self.storage = storage
        self.lightningService = lightningService
        self.blocktankService = blocktankService
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
        lspOrderId: String? = nil,
        claimableAtHeight: UInt32? = nil,
        txTotalSats: UInt64? = nil,
        preTransferOnchainSats: UInt64? = nil
    ) async throws -> String {
        // When geoblocked, block transfers to spending that involve LSP (Blocktank)
        // toSpending with lspOrderId means it's a Blocktank LSP channel order
        let isGeoblocked = GeoService.shared.isGeoBlocked
        if isGeoblocked && type.isToSpending() && lspOrderId != nil {
            Logger.error("Cannot create LSP transfer when geoblocked", context: "TransferService")
            throw AppError(
                message: "Transfer unavailable",
                debugMessage: "Transfer to spending via Blocktank is not available in your region."
            )
        }

        let id = UUID().uuidString
        let createdAt = UInt64(Date().timeIntervalSince1970)

        let transfer = Transfer(
            id: id,
            type: type,
            amountSats: amountSats,
            channelId: channelId,
            fundingTxId: fundingTxId,
            lspOrderId: lspOrderId,
            isSettled: false,
            createdAt: createdAt,
            settledAt: nil,
            claimableAtHeight: claimableAtHeight,
            txTotalSats: txTotalSats,
            preTransferOnchainSats: preTransferOnchainSats
        )

        try storage.insert(transfer)
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
        guard let channels = lightningService.channels else {
            Logger.error("Failed to get channels for transfer sync", context: "TransferService")
            return
        }

        // Get balances from LightningService (returns BalanceDetails? directly)
        let balances = lightningService.balances

        Logger.debug("Syncing \(activeTransfers.count) active transfers", context: "TransferService")

        // Process transfers to spending
        let toSpending = activeTransfers.filter { $0.type.isToSpending() }

        for transfer in toSpending {
            if let channelId = try await resolveChannelId(for: transfer, channels: channels) {
                // Update transfer with channelId if not set yet
                if transfer.channelId == nil {
                    let updatedTransfer = Transfer(
                        id: transfer.id,
                        type: transfer.type,
                        amountSats: transfer.amountSats,
                        channelId: channelId,
                        fundingTxId: transfer.fundingTxId,
                        lspOrderId: transfer.lspOrderId,
                        isSettled: transfer.isSettled,
                        createdAt: transfer.createdAt,
                        settledAt: transfer.settledAt,
                        claimableAtHeight: transfer.claimableAtHeight,
                        txTotalSats: transfer.txTotalSats,
                        preTransferOnchainSats: transfer.preTransferOnchainSats
                    )
                    try storage.update(updatedTransfer)
                    Logger.debug("Updated transfer \(transfer.id) with channelId: \(channelId)", context: "TransferService")
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
            } else {
                // No channel ID resolved - check if we should timeout this transfer
                Logger.debug(
                    "Could not resolve channel for transfer: \(transfer.id) orderId: \(transfer.lspOrderId ?? "none")",
                    context: "TransferService"
                )
            }
        }

        // Process transfers to savings
        let toSavings = activeTransfers.filter { $0.type.isToSavings() }

        for transfer in toSavings {
            if let channelId = try await resolveChannelId(for: transfer, channels: channels) {
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
                            Logger.debug("Force close awaiting sweep detection for transfer: \(transfer.id)", context: "TransferService")
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

    /// Resolve channel ID for a transfer
    /// For LSP orders: match via order->fundingTx, for manual: use directly
    func resolveChannelId(for transfer: Transfer, channels: [ChannelDetails]) async throws -> String? {
        // If there's an LSP order ID, resolve via Blocktank
        if let orderId = transfer.lspOrderId {
            // Get orders from Blocktank (returns [IBtOrder])
            var orders: [IBtOrder]? = nil

            do {
                orders = try? await blocktankService.orders(orderIds: [orderId], filter: nil, refresh: false)
            } catch {
                Logger.error("Failed to fetch Blocktank orders for orderId \(orderId): \(error)", context: "TransferService")
                return nil
            }

            if let order = orders?.first {
                if let fundingTxId = order.channel?.fundingTx.id {
                    // Find channel matching the funding transaction
                    if let channel = channels.first(where: { channel in
                        channel.fundingTxo?.txid.description == fundingTxId
                    }) {
                        return channel.channelId.description
                    } else {
                        Logger.debug("Order \(orderId) has fundingTx \(fundingTxId) but no matching channel found", context: "TransferService")
                    }
                } else {
                    Logger.debug("Order \(orderId) exists but has no fundingTx yet (state: \(order.state))", context: "TransferService")
                }
            } else {
                Logger.debug("Order \(orderId) not found in Blocktank response", context: "TransferService")
            }
        }

        // Otherwise use the channel ID directly
        return transfer.channelId
    }
}
