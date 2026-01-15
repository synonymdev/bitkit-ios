import BitkitCore
import Foundation
import LDKNode
import SwiftUI

/// Manages balance calculations including pending transfers
class BalanceManager {
    private let lightningService: LightningService
    private let transferService: TransferService
    private let coreService: CoreService

    @AppStorage("onchainAddress") private var onchainAddress = ""

    private static let fallbackFeePercent: Double = 0.1

    init(
        lightningService: LightningService = .shared,
        transferService: TransferService,
        coreService: CoreService = .shared
    ) {
        self.lightningService = lightningService
        self.transferService = transferService
        self.coreService = coreService
    }

    /// Derives the complete balance state including pending transfers
    /// - Returns: BalanceState with all balance calculations
    /// - Throws: Error if balance retrieval fails
    func deriveBalanceState() async throws -> BalanceState {
        guard let balanceDetails = lightningService.balances else {
            throw AppError(message: "Balance details unavailable", debugMessage: "LightningService.balances is nil")
        }

        let channels = lightningService.channels ?? []
        let activeTransfers = try transferService.getActiveTransfers()

        let paidOrdersSats = getOrderPaymentsSats(activeTransfers: activeTransfers)
        let pendingChannelsSats = getPendingChannelsSats(
            transfers: activeTransfers,
            channels: channels,
            balances: balanceDetails
        )

        let (lightningToSubtract, pendingCloseAmount) = await getCloseTransferAmounts(
            transfers: activeTransfers,
            balanceDetails: balanceDetails
        )

        // Detect orphan closed channels: channels with lightning balance that are no longer
        // in the channels list and don't have a Transfer record yet. This handles the race
        // condition where the channel closes but Transfer hasn't been created yet.
        let orphanClosedChannelBalance = getOrphanClosedChannelBalance(
            transfers: activeTransfers,
            channels: channels,
            balances: balanceDetails
        )

        let toSavingsAmount = pendingCloseAmount
        let toSpendingAmount = paidOrdersSats + pendingChannelsSats

        let totalOnchainSats = balanceDetails.totalOnchainBalanceSats
        let totalLightningSats = balanceDetails.totalLightningBalanceSats
            .minusOrZero(pendingChannelsSats)
            .minusOrZero(lightningToSubtract)
            .minusOrZero(orphanClosedChannelBalance)

        let maxSendLightningSats = calculateMaxSendLightning(channels: channels)

        let balanceState = BalanceState(
            totalOnchainSats: totalOnchainSats,
            totalLightningSats: totalLightningSats,
            maxSendLightningSats: maxSendLightningSats,
            balanceInTransferToSavings: toSavingsAmount,
            balanceInTransferToSpending: toSpendingAmount
        )

        Logger.debug(
            "Active transfers: \(activeTransfers.count)"
        )
        Logger.debug(
            "Balances in ldk-node: onchain=\(balanceDetails.totalOnchainBalanceSats) lightning=\(balanceDetails.totalLightningBalanceSats)"
        )
        Logger.debug(
            "Balances in state: onchain=\(totalOnchainSats) lightning=\(totalLightningSats) toSavings=\(toSavingsAmount) toSpending=\(toSpendingAmount) lnSubtract=\(lightningToSubtract)"
        )

        return balanceState
    }

    // MARK: - Private Helper Methods

    /// Calculates the total amount paid for LSP orders before their channel is assigned.
    /// Once channelId is set, funds are tracked by getPendingChannelsSats instead.
    private func getOrderPaymentsSats(activeTransfers: [Transfer]) -> UInt64 {
        // Only count orders that don't have a channel assigned yet
        let paidOrders = activeTransfers.filter {
            $0.type.isToSpending() && $0.lspOrderId != nil && $0.channelId == nil
        }

        for transfer in paidOrders {
            Logger.debug(
                "Order payment transfer: id=\(transfer.id) orderId=\(transfer.lspOrderId ?? "nil") amount=\(transfer.amountSats)"
            )
        }

        return paidOrders.reduce(0) { $0 + $1.amountSats }
    }

    /// Calculates the total balance in pending (not yet usable) channels.
    private func getPendingChannelsSats(
        transfers: [Transfer],
        channels: [ChannelDetails],
        balances: BalanceDetails
    ) -> UInt64 {
        var amount: UInt64 = 0
        let pendingTransfers = transfers.filter { $0.type.isToSpending() && $0.channelId != nil }

        Logger.debug("Checking \(pendingTransfers.count) pending transfers to spending")
        Logger.debug("Available channels: \(channels.count), Lightning balances: \(balances.lightningBalances.count)")

        for transfer in pendingTransfers {
            guard let channelId = transfer.channelId else {
                Logger.debug("Transfer \(transfer.id) has no channelId")
                continue
            }

            Logger.debug("Looking for channel: \(channelId)")

            guard let channel = channels.first(where: { $0.channelId.description == channelId }) else {
                Logger.debug("Channel \(channelId) not found in channels list for transfer: \(transfer.id)")
                continue
            }

            // Count balance if channel exists but is not yet usable
            // isUsable checks both that the channel is ready AND that it can actually be used
            if !channel.isUsable {
                let channelBalance = balances.lightningBalances.first { balance in
                    balance.channelIdString == channelId
                }
                let balanceAmount = channelBalance?.amountSats ?? 0
                Logger.debug(
                    "Pending channel transfer: id=\(transfer.id) channelId=\(channelId) isUsable=\(channel.isUsable) isReady=\(channel.isChannelReady) balance=\(balanceAmount)"
                )
                amount += balanceAmount
            } else {
                Logger
                    .debug("Channel \(channelId) is usable, not counting as pending (isUsable=\(channel.isUsable) isReady=\(channel.isChannelReady))")
            }
        }

        return amount
    }

    /// Calculates amounts for channel close transfers.
    /// - Returns: lightningToSubtract (always subtract from display), pendingAmount (add to total only if on-chain hasn't arrived)
    private func getCloseTransferAmounts(
        transfers: [Transfer],
        balanceDetails: BalanceDetails
    ) async -> (lightningToSubtract: UInt64, pendingAmount: UInt64) {
        var lightningToSubtract: UInt64 = 0
        var pendingAmount: UInt64 = 0

        for transfer in transfers.filter({ $0.type.isToSavings() }) {
            guard let channelId = transfer.channelId else { continue }

            let balanceFromLdk = balanceDetails.lightningBalances
                .first { $0.channelIdString == channelId }?.amountSats
            let balanceAmount = balanceFromLdk ?? transfer.amountSats

            if balanceFromLdk == nil {
                Logger.debug(
                    "Close transfer \(transfer.id): channel \(channelId) not in lightningBalances, using transfer amount \(transfer.amountSats)"
                )
            }

            lightningToSubtract += balanceAmount

            if await !coreService.activity.hasOnchainActivityForChannel(channelId: channelId) {
                pendingAmount += balanceAmount
            }
        }

        return (lightningToSubtract, pendingAmount)
    }

    /// Detects "orphan" closed channels - channels that have lightning balance in LDK
    /// but are no longer in the channels list and don't have a Transfer record yet.
    private func getOrphanClosedChannelBalance(
        transfers: [Transfer],
        channels: [ChannelDetails],
        balances: BalanceDetails
    ) -> UInt64 {
        // Get all channelIds from current channels and active transfers
        let activeChannelIds = Set(channels.map(\.channelId.description))
        let transferChannelIds = Set(transfers.compactMap(\.channelId))

        var orphanBalance: UInt64 = 0

        for lightningBalance in balances.lightningBalances {
            let channelId = lightningBalance.channelIdString

            // If this channel is not in active channels AND not tracked by a Transfer,
            // it's a closed channel that hasn't had its Transfer record created yet
            let isInActiveChannels = activeChannelIds.contains(channelId)
            let hasTransferRecord = transferChannelIds.contains(channelId)

            if !isInActiveChannels && !hasTransferRecord {
                Logger.debug(
                    "Found orphan closed channel balance: channelId=\(channelId) amount=\(lightningBalance.amountSats)",
                    context: "BalanceManager"
                )
                orphanBalance += lightningBalance.amountSats
            }
        }

        return orphanBalance
    }

    /// Calculates maximum sendable Lightning amount (outbound capacity)
    private func calculateMaxSendLightning(channels: [ChannelDetails]) -> UInt64 {
        let totalNextOutboundHtlcLimitSats = channels
            .filter(\.isUsable)
            .map(\.nextOutboundHtlcLimitMsat)
            .reduce(0, +) / 1000 // Convert from msat to sat

        return totalNextOutboundHtlcLimitSats
    }
}

// MARK: - UInt64 Extension

private extension UInt64 {
    /// Subtracts value, returning 0 if result would be negative
    func minusOrZero(_ value: UInt64) -> UInt64 {
        return self >= value ? self - value : 0
    }
}
