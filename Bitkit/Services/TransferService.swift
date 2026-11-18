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
                            } else if let pendingSweeps = balances?.pendingBalancesFromChannelClosures,
                                      let changeType = await dustJudgingChangeType(sweepTxid: sweepSpendingTxid),
                                      Self.isUnsweepable(channelId: channelId, pendingSweeps: pendingSweeps, changeType: changeType)
                            {
                                // LDK only adds the sweep's output when more than dust is left after fees. A dust-only
                                // sweep has no outputs, every broadcast fails with `bad-txns-vout-empty` and the sweep
                                // never resolves, so settle the transfer: those sats can't be claimed.
                                try await markSettled(id: transfer.id)
                                Logger.info("Force close sweep is dust, settled transfer: \(transfer.id)", context: "TransferService")
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

    /// Version, input and output counts and locktime (10 bytes), plus the 2 witness flag bytes.
    private static let sweepTxOverheadWu: UInt64 = 42
    /// One input (41 bytes) plus the lightest witness LDK sweeps from an anchor channel (112 WU, the CSV 1 spend of our
    /// output from a counterparty close). The sweep balance does not say its input type, so the lower bound keeps a
    /// sweepable output from settling early; a dust to_local input, which is heavier, can keep its transfer waiting.
    private static let sweepInputWu: UInt64 = 276
    /// LDK's fee floor; the sweeper never pays less.
    private static let feerateFloorSatPerKw: UInt64 = 253

    /// The change type to judge dust by, or nil while the evidence is incomplete: the wallet's payments are unreadable,
    /// the wallet already holds the sweep (which is then real whatever the change type is now), or an address type
    /// change is staged but not yet applied to the node. The flag and the selected type are read together after the
    /// payment lookup, so a change started during it is seen.
    private func dustJudgingChangeType(sweepTxid: String?) async -> LDKNode.AddressType? {
        if let sweepTxid {
            guard let payments = await lightningService.listPayments(),
                  !Self.walletHolds(txid: sweepTxid, payments: payments)
            else { return nil }
        }
        return await MainActor.run {
            guard !SettingsViewModel.shared.isChangingAddressType else { return nil }
            return LDKNode.AddressType.fromStorage(UserDefaults.standard.string(forKey: "selectedAddressType"))
        }
    }

    /// Whether the on-chain wallet holds the transaction, synced or still unconfirmed.
    static func walletHolds(txid: String, payments: [PaymentDetails]) -> Bool {
        payments.contains { payment in
            if case let .onchain(paymentTxid, _) = payment.kind {
                return paymentTxid.caseInsensitiveCompare(txid) == .orderedSame
            }
            return false
        }
    }

    /// Whether LDK can never give the channel's sweep an output, at any fee rate. Mirrors LDK's
    /// `maybe_add_change_output`: the sweeper batches every unconfirmed pending sweep, across channels, into one
    /// transaction paying a change output of the wallet's primary address type, and adds that output only when the
    /// change left after the fee is at least its dust limit. Each input is priced as the lightest one, at the fee
    /// floor. Keep in step with Android `TransferRepo.isUnsweepable`.
    static func isUnsweepable(channelId: String, pendingSweeps: [PendingSweepBalance], changeType: LDKNode.AddressType) -> Bool {
        let ownSweeps = pendingSweeps.filter { $0.sweepChannelId == channelId }
        guard !ownSweeps.isEmpty, !ownSweeps.contains(where: \.isConfirmedSweep) else { return false }

        let batch = pendingSweeps.filter { !$0.isConfirmedSweep }
        let totalSats = batch.reduce(UInt64(0)) { $0 + $1.sweepAmountSats }
        let weightWu = sweepTxOverheadWu + UInt64(batch.count) * sweepInputWu + changeType.outputBytes * 4
        let feeSats = weightWu * feerateFloorSatPerKw / 1000
        return totalSats < changeType.dustLimitSats + feeSats
    }
}

private extension LDKNode.AddressType {
    var outputBytes: UInt64 {
        switch self {
        case .taproot: 43
        case .nativeSegwit: 31
        case .nestedSegwit: 32
        case .legacy: 34
        }
    }

    var dustLimitSats: UInt64 {
        switch self {
        case .taproot: 330
        case .nativeSegwit: 294
        case .nestedSegwit: 540
        case .legacy: 546
        }
    }
}

extension PendingSweepBalance {
    var sweepChannelId: ChannelId? {
        switch self {
        case let .pendingBroadcast(channelId, _): channelId
        case let .broadcastAwaitingConfirmation(channelId, _, _, _): channelId
        case let .awaitingThresholdConfirmations(channelId, _, _, _, _): channelId
        }
    }

    var isConfirmedSweep: Bool {
        if case .awaitingThresholdConfirmations = self {
            return true
        }
        return false
    }

    var sweepAmountSats: UInt64 {
        switch self {
        case let .pendingBroadcast(_, amountSatoshis): amountSatoshis
        case let .broadcastAwaitingConfirmation(_, _, _, amountSatoshis): amountSatoshis
        case let .awaitingThresholdConfirmations(_, _, _, _, amountSatoshis): amountSatoshis
        }
    }
}
