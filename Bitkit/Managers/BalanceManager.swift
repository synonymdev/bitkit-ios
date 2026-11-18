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
    /// - Parameter exitInTransfer: the running Spark exit's transfer and what it still brings to savings, counted in
    ///   place of that transfer's fixed amount.
    func deriveBalanceState(exitInTransfer: (transferId: String, sats: UInt64)? = nil) async throws -> BalanceState {
        guard var balanceDetails = await MainActor.run(body: { lightningService.balances }) else {
            throw AppError(message: "Balance details unavailable", debugMessage: "LightningService.balances is nil")
        }
        // A broadcast sweep is matched against the wallet's spendable outputs, read together with the balances.
        var outputs: [SpendableUtxo] = []
        if balanceDetails.pendingBalancesFromChannelClosures.contains(where: { Self.sweepTxid(of: $0) != nil }),
           let snapshot = await lightningService.balancesAndOutputs()
        {
            balanceDetails = snapshot.balances
            outputs = snapshot.outputs
        }

        let channels = await MainActor.run { lightningService.channels } ?? []
        let activeTransfers = try transferService.getActiveTransfers()

        let pendingChannelsSats = await getPendingChannelsSats(
            transfers: activeTransfers,
            channels: channels,
            balances: balanceDetails
        )

        let (lightningToSubtract, onchainToSubtract, pendingCloseAmount) = await getCloseTransferAmounts(
            transfers: activeTransfers,
            balanceDetails: balanceDetails,
            outputs: outputs,
            exitInTransfer: exitInTransfer
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
        let toSpendingAmount = pendingChannelsSats

        let totalOnchainSats = balanceDetails.totalOnchainBalanceSats.minusOrZero(onchainToSubtract)
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

    /// Calculates the total balance in pending (not yet usable) channels opened through Manual Setup.
    private func getPendingChannelsSats(
        transfers: [Transfer],
        channels: [ChannelDetails],
        balances: BalanceDetails
    ) async -> UInt64 {
        var amount: UInt64 = 0
        let pendingTransfers = transfers.filter { $0.type.isToSpending() && $0.lspOrderId == nil }

        Logger.debug("Checking \(pendingTransfers.count) pending transfers to spending")
        Logger.debug("Available channels: \(channels.count), Lightning balances: \(balances.lightningBalances.count)")

        for transfer in pendingTransfers {
            guard let channelId = transfer.channelId else {
                Logger.debug("Transfer \(transfer.id) has no resolvable channelId")
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
        balanceDetails: BalanceDetails,
        outputs: [SpendableUtxo],
        exitInTransfer: (transferId: String, sats: UInt64)? = nil
    ) async -> (lightningToSubtract: UInt64, onchainToSubtract: UInt64, pendingAmount: UInt64) {
        var lightningToSubtract: UInt64 = 0
        var onchainToSubtract: UInt64 = 0
        var pendingAmount: UInt64 = 0
        var countedSweepTxids = Set<String>()
        let pendingSweeps = balanceDetails.pendingBalancesFromChannelClosures

        for transfer in transfers.filter({ $0.type.isToSavings() }) {
            // A Spark exit has no channel: it is in transfer until its sweep confirms and the exit settles it.
            if transfer.type == .sparkExit {
                pendingAmount += Self.sparkExitInTransferSats(transfer, exitInTransfer: exitInTransfer)
                continue
            }
            guard let channelId = transfer.channelId else { continue }

            let balanceFromLdk = balanceDetails.lightningBalances
                .first { $0.channelIdString == channelId }?.amountSats

            if let amount = balanceFromLdk {
                lightningToSubtract += amount
            } else {
                Logger.debug(
                    "Close transfer \(transfer.id): channel \(channelId) not in lightningBalances, not subtracting from lightning"
                )
            }

            if await coreService.activity.hasOnchainActivityForChannel(channelId: channelId) {
                continue
            }

            // Once the wallet holds the channel's sweep, Savings includes its output: show that output as in transfer
            // until its activity syncs, and take it out of the on-chain total so it counts once.
            let heldSweeps = Self.heldSweeps(channelId: channelId, pendingSweeps: pendingSweeps, outputs: outputs)
            if heldSweeps.isEmpty {
                pendingAmount += transfer.amountSats
            } else {
                for sweep in heldSweeps where countedSweepTxids.insert(sweep.txid.lowercased()).inserted {
                    onchainToSubtract += sweep.sats
                    pendingAmount += sweep.sats
                }
            }
        }

        return (lightningToSubtract, onchainToSubtract, pendingAmount)
    }

    /// The channel's sweep transactions whose outputs the on-chain wallet holds, confirmed or in the mempool, with what
    /// each paid the wallet.
    static func heldSweeps(
        channelId: String,
        pendingSweeps: [PendingSweepBalance],
        outputs: [SpendableUtxo]
    ) -> [(txid: String, sats: UInt64)] {
        let sweepTxids = pendingSweeps.compactMap { sweep -> String? in
            guard sweepChannelId(of: sweep) == channelId else { return nil }
            return sweepTxid(of: sweep)?.lowercased()
        }

        return Set(sweepTxids).sorted().compactMap { txid in
            let held = outputs.filter { $0.outpoint.txid.lowercased() == txid }
            guard !held.isEmpty else { return nil }
            return (txid, held.reduce(0) { $0 + $1.valueSats })
        }
    }

    private static func sweepChannelId(of sweep: PendingSweepBalance) -> ChannelId? {
        switch sweep {
        case let .pendingBroadcast(channelId, _): channelId
        case let .broadcastAwaitingConfirmation(channelId, _, _, _): channelId
        case let .awaitingThresholdConfirmations(channelId, _, _, _, _): channelId
        }
    }

    private static func sweepTxid(of sweep: PendingSweepBalance) -> String? {
        switch sweep {
        case .pendingBroadcast: nil
        case let .broadcastAwaitingConfirmation(_, _, latestSpendingTxid, _): latestSpendingTxid
        case let .awaitingThresholdConfirmations(_, latestSpendingTxid, _, _, _): latestSpendingTxid
        }
    }

    /// The running exit's own transfer counts what it still brings to savings; any other exit transfer its amount.
    static func sparkExitInTransferSats(_ transfer: Transfer, exitInTransfer: (transferId: String, sats: UInt64)?) -> UInt64 {
        guard let exitInTransfer, exitInTransfer.transferId == transfer.id else { return transfer.amountSats }
        return exitInTransfer.sats
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
        return channels
            .filter(\.isUsable)
            .map(\.nextOutboundHtlcLimitMsat)
            .reduce(0, +) / 1000 // Convert from msat to sat
    }
}

// MARK: - UInt64 Extension

private extension UInt64 {
    /// Subtracts value, returning 0 if result would be negative
    func minusOrZero(_ value: UInt64) -> UInt64 {
        return self >= value ? self - value : 0
    }
}
