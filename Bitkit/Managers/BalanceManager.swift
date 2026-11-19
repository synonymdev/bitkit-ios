import BitkitCore
import Foundation
import LDKNode
import os
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
        let channels = await MainActor.run { lightningService.channels } ?? []
        let activeTransfers = try transferService.getActiveTransfers()

        // A sweep, current or saved on its transfer, is matched against the wallet's spendable outputs, read together
        // with the balances.
        var outputs: [SpendableUtxo] = []
        let hasSweepTxid = balanceDetails.pendingBalancesFromChannelClosures.contains { Self.sweepTxid(of: $0) != nil }
            || activeTransfers.contains { $0.sweepTxids?.isEmpty == false }
        if hasSweepTxid, let snapshot = await lightningService.balancesAndOutputs() {
            balanceDetails = snapshot.balances
            outputs = snapshot.outputs
        }

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
        var pendingAmount: UInt64 = 0
        var heldTransfers: [HeldTransfer] = []
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

            // The transfer stays in transfer at its amount until its activity syncs. Once the wallet holds one of the
            // channel's sweeps, Savings includes its output too: take that output out of Savings so it counts once, but
            // never more than the transfer adds to In Transfer, so sats it does not count stay in Savings.
            pendingAmount += transfer.amountSats
            let heldSweeps = Self.heldSweeps(
                channelId: channelId,
                pendingSweeps: pendingSweeps,
                earlierTxids: Set(transfer.sweepTxids ?? []),
                outputs: outputs
            )
            heldTransfers.append(HeldTransfer(channelId: channelId, amountSats: transfer.amountSats, heldSweeps: heldSweeps))
        }

        let onchainToSubtract = Self.heldSweepsDeduction(transfers: heldTransfers, pendingSweeps: pendingSweeps)
        return (lightningToSubtract, onchainToSubtract, pendingAmount)
    }

    struct HeldTransfer {
        let channelId: String
        let amountSats: UInt64
        let heldSweeps: [(txid: String, sats: UInt64)]
    }

    /// What the in-transfer closes' held sweeps take out of Savings, never more than those transfers add to In Transfer.
    /// A sweep LDK still reports takes each channel's share once, up to that transfer's amount. A sweep LDK no longer
    /// reports has no known shares: it comes out once, up to what the transfers recording it have left.
    static func heldSweepsDeduction(transfers: [HeldTransfer], pendingSweeps: [PendingSweepBalance]) -> UInt64 {
        var deduction: UInt64 = 0
        var remainingSats = transfers.map(\.amountSats)
        var countedShares = Set<String>()
        var unknownShareSweeps: [String: (sats: UInt64, holders: [Int])] = [:]

        for (index, transfer) in transfers.enumerated() {
            var sharesSats: UInt64 = 0
            for sweep in transfer.heldSweeps {
                if let share = channelShareSats(channelId: transfer.channelId, sweep: sweep, pendingSweeps: pendingSweeps) {
                    // Two transfers can track one channel, such as a local close and the peer's force close.
                    if countedShares.insert("\(transfer.channelId):\(sweep.txid)").inserted {
                        sharesSats += share
                    }
                } else {
                    unknownShareSweeps[sweep.txid, default: (sweep.sats, [])].holders.append(index)
                }
            }
            let taken = min(sharesSats, transfer.amountSats)
            deduction += taken
            remainingSats[index] -= taken
        }

        for txid in unknownShareSweeps.keys.sorted() {
            guard let sweep = unknownShareSweeps[txid] else { continue }
            var toTake = min(sweep.sats, sweep.holders.reduce(0) { $0 + remainingSats[$1] })
            deduction += toTake
            for holder in sweep.holders where toTake > 0 {
                let taken = min(toTake, remainingSats[holder])
                remainingSats[holder] -= taken
                toTake -= taken
            }
        }

        return deduction
    }

    /// The channel's sweep transactions, current or earlier, whose outputs the on-chain wallet holds, confirmed or in the
    /// mempool, with what each paid the wallet.
    static func heldSweeps(
        channelId: String,
        pendingSweeps: [PendingSweepBalance],
        earlierTxids: Set<String> = [],
        outputs: [SpendableUtxo]
    ) -> [(txid: String, sats: UInt64)] {
        let txids = sweepTxids(channelId: channelId, pendingSweeps: pendingSweeps).union(earlierTxids)

        return txids.sorted().compactMap { txid in
            let held = outputs.filter { $0.outpoint.txid.lowercased() == txid }
            guard !held.isEmpty else { return nil }
            return (txid, held.reduce(0) { $0 + $1.valueSats })
        }
    }

    /// The part of a held sweep's output that pays this channel, by what LDK reports each channel sweeps in it, so a sweep
    /// shared with a channel whose activity already synced takes only this channel's part out of Savings. Nil when LDK no
    /// longer reports the sweep.
    static func channelShareSats(
        channelId: String,
        sweep: (txid: String, sats: UInt64),
        pendingSweeps: [PendingSweepBalance]
    ) -> UInt64? {
        let inSweep = pendingSweeps.filter { sweepTxid(of: $0)?.lowercased() == sweep.txid }
        let totalSats = inSweep.reduce(0) { $0 + sweepAmountSats(of: $1) }
        guard totalSats > 0 else { return nil }
        let channelSats = inSweep.filter { sweepChannelId(of: $0) == channelId }.reduce(0) { $0 + sweepAmountSats(of: $1) }
        return UInt64((Double(sweep.sats) * Double(channelSats) / Double(totalSats)).rounded())
    }

    static func sweepTxids(channelId: String, pendingSweeps: [PendingSweepBalance]) -> Set<String> {
        Set(pendingSweeps.compactMap { sweep -> String? in
            guard sweepChannelId(of: sweep) == channelId else { return nil }
            return sweepTxid(of: sweep)?.lowercased()
        })
    }

    private static func sweepChannelId(of sweep: PendingSweepBalance) -> ChannelId? {
        switch sweep {
        case let .pendingBroadcast(channelId, _): channelId
        case let .broadcastAwaitingConfirmation(channelId, _, _, _): channelId
        case let .awaitingThresholdConfirmations(channelId, _, _, _, _): channelId
        }
    }

    private static func sweepAmountSats(of sweep: PendingSweepBalance) -> UInt64 {
        switch sweep {
        case let .pendingBroadcast(_, amountSatoshis): amountSatoshis
        case let .broadcastAwaitingConfirmation(_, _, _, amountSatoshis): amountSatoshis
        case let .awaitingThresholdConfirmations(_, _, _, _, amountSatoshis): amountSatoshis
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
