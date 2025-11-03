import BitkitCore
import Foundation
import LDKNode
import SwiftUI

/// Manages balance calculations including pending transfers
/// Adapted from Android's DeriveBalanceStateUseCase
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

        let toSavingsAmount = try await getTransferToSavingsSats(
            transfers: activeTransfers,
            channels: channels,
            balanceDetails: balanceDetails
        )
        let toSpendingAmount = paidOrdersSats + pendingChannelsSats

        let totalOnchainSats = balanceDetails.totalOnchainBalanceSats
        let totalLightningSats = balanceDetails.totalLightningBalanceSats
            .minusOrZero(pendingChannelsSats)
            .minusOrZero(toSavingsAmount)

        let maxSendLightningSats = calculateMaxSendLightning(channels: channels)
        let maxSendOnchainSats = try await getMaxSendAmount(balanceDetails: balanceDetails)

        let balanceState = BalanceState(
            totalOnchainSats: totalOnchainSats,
            totalLightningSats: totalLightningSats,
            maxSendLightningSats: maxSendLightningSats,
            maxSendOnchainSats: maxSendOnchainSats,
            balanceInTransferToSavings: toSavingsAmount,
            balanceInTransferToSpending: toSpendingAmount
        )

        Logger.verbose(
            "Active transfers: \(activeTransfers.count)",
            context: "BalanceManager"
        )
        Logger.verbose(
            "Balances in ldk-node: onchain=\(balanceDetails.totalOnchainBalanceSats) lightning=\(balanceDetails.totalLightningBalanceSats)",
            context: "BalanceManager"
        )
        Logger.verbose(
            "Balances in state: onchain=\(totalOnchainSats) lightning=\(totalLightningSats) toSavings=\(toSavingsAmount) toSpending=\(toSpendingAmount)",
            context: "BalanceManager"
        )

        return balanceState
    }

    // MARK: - Private Helper Methods

    /// Calculates the total amount paid for LSP orders that are still pending
    private func getOrderPaymentsSats(activeTransfers: [Transfer]) -> UInt64 {
        return activeTransfers
            .filter { $0.type.isToSpending() && $0.lspOrderId != nil }
            .reduce(0) { $0 + $1.amountSats }
    }

    /// Calculates the total balance in pending (not yet ready) channels
    private func getPendingChannelsSats(
        transfers: [Transfer],
        channels: [ChannelDetails],
        balances: BalanceDetails
    ) -> UInt64 {
        var amount: UInt64 = 0
        let pendingTransfers = transfers.filter { $0.type.isToSpending() && $0.channelId != nil }

        for transfer in pendingTransfers {
            guard let channelId = transfer.channelId,
                  let channel = channels.first(where: { $0.channelId.description == channelId })
            else {
                continue
            }

            // Only count if channel is not ready yet
            if !channel.isChannelReady {
                let channelBalance = balances.lightningBalances.first { balance in
                    balance.channelId == channelId
                }
                amount += channelBalance?.claimableAmountSats ?? 0
            }
        }

        return amount
    }

    /// Calculates the total amount being transferred to savings (closing channels)
    private func getTransferToSavingsSats(
        transfers: [Transfer],
        channels: [ChannelDetails],
        balanceDetails: BalanceDetails
    ) async throws -> UInt64 {
        var toSavingsAmount: UInt64 = 0
        let toSavings = transfers.filter { $0.type.isToSavings() }

        for transfer in toSavings {
            // Resolve channel ID through TransferService
            let channelId = try await transferService.resolveChannelId(for: transfer, channels: channels)

            if let channelId {
                let channelBalance = balanceDetails.lightningBalances.first { balance in
                    balance.channelId == channelId
                }
                toSavingsAmount += channelBalance?.claimableAmountSats ?? 0
            }
        }

        return toSavingsAmount
    }

    /// Calculates maximum sendable Lightning amount (outbound capacity)
    private func calculateMaxSendLightning(channels: [ChannelDetails]) -> UInt64 {
        let totalNextOutboundHtlcLimitSats = channels
            .filter(\.isUsable)
            .map(\.nextOutboundHtlcLimitMsat)
            .reduce(0, +) / 1000 // Convert from msat to sat

        return totalNextOutboundHtlcLimitSats
    }

    /// Calculates maximum sendable on-chain amount (spendable minus estimated fees)
    /// Uses the on-chain address from @AppStorage for fee estimation
    /// - Parameter balanceDetails: Current balance details from Lightning service
    /// - Returns: Maximum sendable amount in satoshis
    private func getMaxSendAmount(balanceDetails: BalanceDetails) async throws -> UInt64 {
        let spendableOnchainSats = balanceDetails.spendableOnchainBalanceSats

        if spendableOnchainSats == 0 {
            return 0
        }

        let fallback = UInt64(Double(spendableOnchainSats) * Self.fallbackFeePercent)

        // Check if we have a valid address for fee calculation
        guard !onchainAddress.isEmpty else {
            Logger.debug("No on-chain address available, using fallback estimation: \(fallback)", context: "BalanceManager")
            return spendableOnchainSats.minusOrZero(fallback)
        }

        // Get current fee rate
        guard let fees = try? await coreService.blocktank.fees(refresh: false) else {
            Logger.debug("Could not fetch fees for max send calculation, using fallback: \(fallback)", context: "BalanceManager")
            return spendableOnchainSats.minusOrZero(fallback)
        }

        // Use normal speed for max send calculation
        let feeRate = TransactionSpeed.normal.getFeeRate(from: fees)

        // Get available UTXOs
        let availableUtxos = try? await lightningService.listSpendableOutputs()

        // Calculate actual fee using the stored on-chain address
        let fee: UInt64
        do {
            fee = try await lightningService.calculateTotalFee(
                address: onchainAddress,
                amountSats: spendableOnchainSats,
                satsPerVByte: feeRate,
                utxosToSpend: availableUtxos
            )
        } catch {
            Logger.debug("Could not calculate max send amount, using fallback: \(fallback)", context: "BalanceManager")
            return spendableOnchainSats.minusOrZero(fallback)
        }

        return spendableOnchainSats.minusOrZero(fee)
    }
}

// MARK: - UInt64 Extension

private extension UInt64 {
    /// Subtracts value, returning 0 if result would be negative
    func minusOrZero(_ value: UInt64) -> UInt64 {
        return self >= value ? self - value : 0
    }
}

// MARK: - Lightning Balance Extension

private extension LightningBalance {
    /// Channel ID from the Lightning balance
    var channelId: String? {
        switch self {
        case let .claimableOnChannelClose(id, _, _, _, _, _, _, _):
            return id
        case let .claimableAwaitingConfirmations(id, _, _, _, _):
            return id
        case let .contentiousClaimable(id, _, _, _, _):
            return id
        case let .maybeTimeoutClaimableHtlc(id, _, _, _, _):
            return id
        case let .maybePreimageClaimableHtlc(id, _, _, _, _):
            return id
        case let .counterpartyRevokedOutputClaimable(id, _, _):
            return id
        }
    }

    /// Claimable amount in satoshis
    var claimableAmountSats: UInt64 {
        switch self {
        case let .claimableOnChannelClose(_, _, amountSatoshis, _, _, _, _, _):
            return amountSatoshis
        case let .claimableAwaitingConfirmations(_, _, amountSatoshis, _, _):
            return amountSatoshis
        case let .contentiousClaimable(_, _, amountSatoshis, _, _):
            return amountSatoshis
        case let .maybeTimeoutClaimableHtlc(_, _, amountSatoshis, _, _):
            return amountSatoshis
        case let .maybePreimageClaimableHtlc(_, _, amountSatoshis, _, _):
            return amountSatoshis
        case let .counterpartyRevokedOutputClaimable(_, amountSatoshis, _):
            return amountSatoshis
        }
    }
}
