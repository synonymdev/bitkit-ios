import BitkitCore
import Combine
import Foundation
import LDKNode
import os

/// Wallet scoping for bitkit-core's wallet-scoped activity storage (added in core 0.3.x).
/// The app's normal on-chain/Lightning wallet uses the core default (`"bitkit"`); paired
/// hardware wallets use their own derived id (see `HwWalletId`).
///
/// Defined here (rather than its own file) because `CoreService.swift` is shared with the
/// notification and widget extension targets, so the type must live in a file those targets
/// already compile.
enum WalletScope {
    /// The default Bitkit wallet id (`DEFAULT_WALLET_ID` in bitkit-core).
    static let `default`: String = getDefaultWalletId()
}

// MARK: - Local Types (removed from BitkitCore in Trezor module rewrite)

/// Address info with usage data
struct AddressInfo {
    let address: String
    let path: String
    let transfers: UInt32
}

/// Grouped account addresses by usage
struct AccountAddresses {
    let used: [AddressInfo]
    let unused: [AddressInfo]
    let change: [AddressInfo]
}

// MARK: - Activity Service

class ActivityService {
    private let coreService: CoreService

    private let activitiesChangedSubject = PassthroughSubject<Void, Never>()

    var activitiesChangedPublisher: AnyPublisher<Void, Never> {
        activitiesChangedSubject.eraseToAnyPublisher()
    }

    /// Notify observers that activities changed after a write made directly through BitkitCore
    /// (bypassing this service), e.g. hardware-wallet watcher persistence.
    func notifyActivitiesChanged() {
        activitiesChangedSubject.send()
    }

    private let metadataChangedSubject = PassthroughSubject<Void, Never>()

    var metadataChangedPublisher: AnyPublisher<Void, Never> {
        metadataChangedSubject.eraseToAnyPublisher()
    }

    private var privateInvoiceContactResolver: (@Sendable (String) async -> String?)?
    private var privateOnchainAddressContactResolver: (@Sendable (String) async -> String?)?

    func setPrivatePaykitContactResolvers(
        invoice: (@Sendable (String) async -> String?)?,
        onchainAddress: (@Sendable (String) async -> String?)?
    ) {
        privateInvoiceContactResolver = invoice
        privateOnchainAddressContactResolver = onchainAddress
    }

    // MARK: - Constants

    private let addressSearchCoordinator: AddressSearchCoordinator

    // MARK: - BoostTxIds Cache

    /// Cached transaction IDs that appear in boostTxIds, per wallet id (for filtering replaced
    /// transactions). Scoped because a boost chain only ever exists within one wallet.
    ///
    /// Lock-guarded rather than actor- or `MainActor`-isolated: `updateBoostTxIdsCache` is called
    /// from inside the synchronous `ServiceQueue.background(.core)` blocks below, which must stay
    /// non-async (see `replaceHwSnapshot`), while readers run on whichever executor calls
    /// `getTxIdsInBoostTxIds`. Never hold the lock across an `await`.
    private let cachedTxIdsInBoostTxIds = OSAllocatedUnfairLock(initialState: [String: Set<String>]())

    /// Get the set of transaction IDs that appear in boostTxIds (cached for performance)
    func getTxIdsInBoostTxIds(walletId: String = WalletScope.default) async -> Set<String> {
        if let cached = cachedTxIdsInBoostTxIds.withLock({ $0[walletId] }) {
            return cached
        }
        await refreshBoostTxIdsCache(walletId: walletId)
        return cachedTxIdsInBoostTxIds.withLock { $0[walletId] ?? [] }
    }

    private func updateBoostTxIdsCache(for activity: Activity) {
        guard case let .onchain(onchain) = activity, !onchain.boostTxIds.isEmpty else { return }
        cachedTxIdsInBoostTxIds.withLock {
            // Only merge into an already-warmed wallet. Seeding a cold one would make
            // `getTxIdsInBoostTxIds` treat this single activity's ids as the whole set and skip its
            // refresh, so the rest of the wallet's boost chain would be invisible.
            guard $0[onchain.walletId] != nil else { return }
            $0[onchain.walletId, default: []].formUnion(onchain.boostTxIds)
        }
    }

    private func refreshBoostTxIdsCache(walletId: String = WalletScope.default) async {
        do {
            let allOnchainActivities = try await get(filter: .onchain, walletId: walletId)
            var txIds: Set<String> = []
            for activity in allOnchainActivities {
                if case let .onchain(onchain) = activity {
                    txIds.formUnion(onchain.boostTxIds)
                }
            }
            let txIdsToCache = txIds
            cachedTxIdsInBoostTxIds.withLock { $0[walletId] = txIdsToCache }
        } catch {
            Logger.error("Failed to refresh boostTxIds cache for '\(walletId)': \(error)", context: "ActivityService")
        }
    }

    private func mapToCoreTransactionDetails(txid: String, _ details: LDKNode.TransactionDetails) -> BitkitCore.TransactionDetails {
        let inputs = details.inputs.map { input in
            BitkitCore.TxInput(
                txid: input.txid,
                vout: input.vout,
                scriptsig: input.scriptsig,
                witness: input.witness,
                sequence: input.sequence
            )
        }

        let outputs = details.outputs.map { output in
            BitkitCore.TxOutput(
                scriptpubkey: output.scriptpubkey,
                scriptpubkeyType: output.scriptpubkeyType,
                scriptpubkeyAddress: output.scriptpubkeyAddress,
                value: output.value,
                n: output.n
            )
        }

        return BitkitCore.TransactionDetails(
            walletId: WalletScope.default,
            txId: txid,
            amountSats: details.amountSats,
            inputs: inputs,
            outputs: outputs
        )
    }

    private func fetchTransactionDetails(txid: String) async -> BitkitCore.TransactionDetails? {
        do {
            return try await getTransactionDetails(txid: txid)
        } catch {
            Logger.warn("Failed to fetch stored transaction details for \(txid): \(error)", context: "ActivityService")
            return nil
        }
    }

    func getTransactionDetails(txid: String, walletId: String = WalletScope.default) async throws -> BitkitCore.TransactionDetails? {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getTransactionDetails(walletId: walletId, txId: txid)
        }
    }

    // MARK: - Seen Tracking

    func isActivitySeen(id: String, walletId: String = WalletScope.default) async -> Bool {
        do {
            if let activity = try getActivityById(walletId: walletId, activityId: id) {
                switch activity {
                case let .onchain(onchain):
                    return onchain.seenAt != nil
                case let .lightning(lightning):
                    return lightning.seenAt != nil
                }
            }
        } catch {
            Logger.error("Failed to check seen status for activity \(id): \(error)", context: "ActivityService")
        }
        return false
    }

    func isOnchainActivitySeen(txid: String, walletId: String = WalletScope.default) async -> Bool {
        let activity = try? await getOnchainActivityByTxId(txid: txid, walletId: walletId)
        return activity?.seenAt != nil
    }

    func markActivityAsSeen(id: String, walletId: String = WalletScope.default, seenAt: UInt64? = nil) async {
        let timestamp = seenAt ?? UInt64(Date().timeIntervalSince1970)

        do {
            try await ServiceQueue.background(.core) {
                try BitkitCore.markActivityAsSeen(walletId: walletId, activityId: id, seenAt: timestamp)
                self.activitiesChangedSubject.send()
            }
        } catch {
            Logger.error("Failed to mark activity \(id) as seen: \(error)", context: "ActivityService")
        }
    }

    func markOnchainActivityAsSeen(txid: String, walletId: String = WalletScope.default, seenAt: UInt64? = nil) async {
        do {
            guard let activity = try await getOnchainActivityByTxId(txid: txid, walletId: walletId) else {
                return
            }
            await markActivityAsSeen(id: activity.id, walletId: activity.walletId, seenAt: seenAt)
        } catch {
            Logger.error("Failed to mark onchain activity for \(txid) as seen: \(error)", context: "ActivityService")
        }
    }

    /// Marks every unseen activity across all wallets as seen, each under its own wallet id.
    func markAllUnseenActivitiesAsSeen() async {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        do {
            let activities = try await get(walletId: nil)
            var didMarkAny = false

            for activity in activities {
                let id: String
                let walletId: String
                let isSeen: Bool

                switch activity {
                case let .onchain(onchain):
                    id = onchain.id
                    walletId = onchain.walletId
                    isSeen = onchain.seenAt != nil
                case let .lightning(lightning):
                    id = lightning.id
                    walletId = lightning.walletId
                    isSeen = lightning.seenAt != nil
                }

                if !isSeen {
                    try await ServiceQueue.background(.core) {
                        try BitkitCore.markActivityAsSeen(walletId: walletId, activityId: id, seenAt: timestamp)
                    }
                    didMarkAny = true
                }
            }

            if didMarkAny {
                activitiesChangedSubject.send()
            }
        } catch {
            Logger.error("Failed to mark all activities as seen: \(error)", context: "ActivityService")
        }
    }

    // MARK: - Transaction Status Checks

    func wasTransactionReplaced(txid: String) async -> Bool {
        // Check if the activity exists and is marked as replaced
        if let onchain = try? await getOnchainActivityByTxId(txid: txid),
           !onchain.doesExist
        {
            return true
        }

        return false
    }

    func shouldShowReceivedSheet(txid: String, value: UInt64) async -> Bool {
        if value == 0 {
            return false
        }

        // Don't show sheet for channel closure transactions (commitment tx)
        if await findClosedChannelForTransaction(txid: txid, transactionDetails: nil) != nil {
            Logger.info("Skipping received sheet for channel close transaction \(txid)", context: "CoreService.shouldShowReceivedSheet")
            return false
        }

        let onchainActivity = try? await getOnchainActivityByTxId(txid: txid)

        // Don't show sheet for transfer transactions (channel open/close)
        if let onchainActivity, onchainActivity.isTransfer {
            Logger.info("Skipping received sheet for transfer transaction \(txid)", context: "CoreService.shouldShowReceivedSheet")
            return false
        }

        // Don't show sheet for transactions with a channel ID (part of a channel lifecycle)
        if let onchainActivity, onchainActivity.channelId != nil {
            Logger.info("Skipping received sheet for channel-related transaction \(txid)", context: "CoreService.shouldShowReceivedSheet")
            return false
        }

        if let onchainActivity, onchainActivity.seenAt != nil {
            return false
        }

        // If this is a replacement transaction with same value as original, skip the sheet
        if let boostTxIds = onchainActivity?.boostTxIds, !boostTxIds.isEmpty {
            for replacedTxid in boostTxIds {
                if let replaced = try? await getOnchainActivityByTxId(txid: replacedTxid),
                   replaced.value == value
                {
                    Logger.info(
                        "Skipping received sheet for replacement transaction \(txid) with same value as replaced transaction \(replacedTxid)",
                        context: "CoreService.shouldShowReceivedSheet"
                    )
                    return false
                }
            }
        }

        return true
    }

    func isReceivedTransaction(txid: String) async -> Bool {
        guard let payments = await LightningService.shared.listPayments(),
              let payment = payments.first(where: { payment in
                  if case let .onchain(paymentTxid, _) = payment.kind {
                      return paymentTxid == txid
                  }
                  return false
              })
        else { return false }

        return payment.direction == .inbound
    }

    /// Get doesExist status for boostTxIds to determine RBF vs CPFP. RBF transactions have doesExist = false (replaced), CPFP transactions have
    /// doesExist = true (child transactions).
    func getBoostTxDoesExist(boostTxIds: [String], walletId: String = WalletScope.default) async -> [String: Bool] {
        var doesExistMap: [String: Bool] = [:]
        for boostTxId in boostTxIds {
            if let boostActivity = try? await getOnchainActivityByTxId(txid: boostTxId, walletId: walletId) {
                doesExistMap[boostTxId] = boostActivity.doesExist
            }
        }
        return doesExistMap
    }

    func isCpfpChildTransaction(txId: String, walletId: String = WalletScope.default) async -> Bool {
        guard await getTxIdsInBoostTxIds(walletId: walletId).contains(txId),
              let activity = try? await getOnchainActivityByTxId(txid: txId, walletId: walletId)
        else {
            return false
        }
        return activity.doesExist && !activity.isBoosted
    }

    init(coreService: CoreService) {
        self.coreService = coreService
        addressSearchCoordinator = AddressSearchCoordinator()
    }

    /// Deletes every activity in every wallet, including paired hardware wallets.
    func removeAll() async throws {
        try await ServiceQueue.background(.core) {
            // Get all activities and delete them one by one
            let activities = try getActivities(
                walletId: nil,
                filter: .all,
                txType: nil,
                tags: nil,
                search: nil,
                minDate: nil,
                maxDate: nil,
                limit: nil,
                sortDirection: nil
            )
            for activity in activities {
                _ = try deleteActivityById(
                    walletId: ActivityScope.walletId(of: activity),
                    activityId: ActivityScope.id(of: activity)
                )
            }

            // Clear cache since all activities are deleted
            self.cachedTxIdsInBoostTxIds.withLock { $0.removeAll() }
            self.activitiesChangedSubject.send()
        }
    }

    func insert(_ activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try insertActivity(activity: activity)
            self.updateBoostTxIdsCache(for: activity)
            self.activitiesChangedSubject.send()
        }
    }

    func upsertList(_ activities: [Activity]) async throws {
        try await ServiceQueue.background(.core) {
            try upsertActivities(activities: activities)
            await self.refreshBoostTxIdsCache()
            self.activitiesChangedSubject.send()
        }
    }

    /// Replace the complete stored on-chain snapshot for a watch-only hardware wallet.
    ///
    /// `pruneMissing` must be false unless `activities` merges *every* watcher belonging to the
    /// wallet: anything scoped to `walletId` that a prunable snapshot no longer contains is deleted,
    /// which is how a reorged or replaced transaction stops showing. Locally written transfer
    /// metadata survives either way (see `HwSnapshotMerge`).
    func replaceHwSnapshot(
        walletId: String,
        activities: [Activity],
        transactionDetails: [BitkitCore.TransactionDetails],
        pruneMissing: Bool,
        transferChannelIdsByFundingTxId: [String: String] = [:]
    ) async throws {
        // The closure must stay non-async. `ServiceQueue.background`'s async overload is
        // `queue.async { Task { … } }`, whose Task hops straight off the core queue — the
        // read → delete → upsert below would then run unserialized, and a concurrent
        // `markOnchainActivityAsTransfer` could interleave with it. Anything needing `await` runs
        // after this returns.
        let removedActivities = try await ServiceQueue.background(.core) {
            return try Self.applyHwSnapshot(
                walletId: walletId,
                activities: activities,
                transactionDetails: transactionDetails,
                pruneMissing: pruneMissing,
                currentTimestamp: UInt64(Date().timeIntervalSince1970),
                transferChannelIdsByFundingTxId: transferChannelIdsByFundingTxId
            )
        }

        // Rows may have been pruned, so drop the cached set rather than rebuilding it here: a
        // rebuild is a full-wallet scan on every watcher poll, hardware rows never carry boostTxIds
        // (boosting is gated off for watch-only wallets), and `getTxIdsInBoostTxIds` rebuilds
        // lazily on the next read. Rebuilding inside the block above would also deadlock — it
        // re-enters the core queue.
        cachedTxIdsInBoostTxIds.withLock { $0[walletId] = nil }
        activitiesChangedSubject.send()

        // A deletion cascades into `activity_tags`, so the metadata envelope carrying this wallet's
        // tags is now stale. A plain upsert cannot drop a tag, which is why the ordinary watcher
        // poll must not re-upload it.
        if removedActivities {
            metadataChangedSubject.send()
        }
    }

    /// One core-queue transaction: read what is stored, then apply the plan. Deliberately non-async
    /// and static, so it cannot reach instance state and reintroduce an `await` in the queue block.
    /// Returns whether any activity was deleted; the caller turns that into the metadata backup
    /// signal, since it cannot reach `metadataChangedSubject` from here.
    private static func applyHwSnapshot(
        walletId: String,
        activities: [Activity],
        transactionDetails: [BitkitCore.TransactionDetails],
        pruneMissing: Bool,
        currentTimestamp: UInt64,
        transferChannelIdsByFundingTxId: [String: String]
    ) throws -> Bool {
        let plan = try HwSnapshotMerge.plan(
            existing: storedOnchainActivities(walletId: walletId),
            incoming: activities,
            pruneMissing: pruneMissing,
            currentTimestamp: currentTimestamp,
            transferChannelIdsByFundingTxId: transferChannelIdsByFundingTxId
        )

        for activity in plan.toDelete {
            _ = try deleteActivityById(walletId: walletId, activityId: activity.id)
            _ = try deleteTransactionDetails(walletId: walletId, txId: activity.txId)
        }

        if !plan.toUpsert.isEmpty {
            try upsertActivities(activities: plan.toUpsert)
        }

        if !transactionDetails.isEmpty {
            try upsertTransactionDetails(detailsList: transactionDetails)
        }

        return !plan.toDelete.isEmpty
    }

    private static func storedOnchainActivities(walletId: String) throws -> [OnchainActivity] {
        try getActivities(
            walletId: walletId,
            filter: .onchain,
            txType: nil,
            tags: nil,
            search: nil,
            minDate: nil,
            maxDate: nil,
            limit: nil,
            sortDirection: nil
        ).compactMap { activity in
            guard case let .onchain(onchain) = activity else { return nil }
            return onchain
        }
    }

    /// Delete every activity scoped to a watch-only hardware wallet, e.g. when the device is
    /// unpaired. Returns the number of rows removed.
    @discardableResult
    func deleteByWalletId(_ walletId: String) async throws -> UInt32 {
        try await ServiceQueue.background(.core) {
            let deleted = try deleteActivitiesByWalletId(walletId: walletId)
            self.activitiesChangedSubject.send()
            self.notifyHardwareTagsChanged(walletId: walletId)
            return deleted
        }
    }

    func closedChannels(sortDirection: SortDirection = .asc) async throws -> [ClosedChannelDetails] {
        try await ServiceQueue.background(.core) {
            try getAllClosedChannels(sortDirection: sortDirection)
        }
    }

    func upsertClosedChannelList(_ closedChannels: [ClosedChannelDetails]) async throws {
        try await ServiceQueue.background(.core) {
            try upsertClosedChannels(channels: closedChannels)
        }
    }

    func upsertClosedChannel(_ closedChannel: ClosedChannelDetails) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertClosedChannel(channel: closedChannel)
        }
    }

    // MARK: - Payment Processing

    private func processOnchainPayment(
        _ payment: PaymentDetails,
        transactionDetails: BitkitCore.TransactionDetails? = nil
    ) async throws {
        guard case let .onchain(txid, txStatus) = payment.kind else { return }

        let paymentTimestamp = payment.latestUpdateTimestamp

        // Look for existing activity by id first, then by txid (for migrated activities)
        var existingActivity = try getActivityById(walletId: WalletScope.default, activityId: payment.id)
        if existingActivity == nil {
            existingActivity = try BitkitCore.getActivityByTxId(walletId: WalletScope.default, txId: txid).map { .onchain($0) }
        }

        // Determine if confirmation status is changing
        let ldkConfirmed = if case .confirmed = txStatus { true } else { false }

        // Skip if existing activity has newer timestamp, unless confirmation status is changing
        if let existingActivity, case let .onchain(existing) = existingActivity {
            let existingUpdatedAt = existing.updatedAt ?? 0
            let confirmationStatusChanging = existing.confirmed != ldkConfirmed
            let needsPrivateContactAttribution = existing.contact == nil && payment.direction == .inbound

            if existingUpdatedAt > paymentTimestamp && !confirmationStatusChanging && !needsPrivateContactAttribution {
                return
            }
        }

        // Determine confirmation status from payment's txStatus
        var blockTimestamp: UInt64?
        let isConfirmed: Bool
        if case let .onchain(_, txStatus) = payment.kind,
           case let .confirmed(_, _, bts) = txStatus
        {
            isConfirmed = true
            blockTimestamp = bts
        } else {
            isConfirmed = false
        }

        // Extract existing activity data
        let existingOnchain: OnchainActivity? = {
            if let existingActivity, case let .onchain(existing) = existingActivity {
                return existing
            }
            return nil
        }()

        let isBoosted = existingOnchain?.isBoosted ?? false
        let boostTxIds = existingOnchain?.boostTxIds ?? []
        var isTransfer = existingOnchain?.isTransfer ?? false
        var channelId = existingOnchain?.channelId
        let transferTxId = existingOnchain?.transferTxId
        var contact = existingOnchain?.contact
        let feeRate = existingOnchain?.feeRate ?? 1
        let preservedAddress = existingOnchain?.address ?? "Loading..."
        let doesExist = existingOnchain?.doesExist ?? true
        let seenAt = existingOnchain?.seenAt

        // Preserve existing value if it's larger than what LDK reports
        let ldkValue = payment.amountSats ?? 0
        let value: UInt64 = if let existingValue = existingOnchain?.value, existingValue > ldkValue {
            existingValue
        } else {
            ldkValue
        }

        // Check if this transaction is a channel transfer
        if channelId == nil || !isTransfer {
            let foundChannelId = await findChannelForTransaction(
                txid: txid,
                direction: payment.direction,
                transactionDetails: transactionDetails
            )
            if let foundChannelId {
                channelId = foundChannelId
                isTransfer = true
            }
        }

        // Find receiving address for inbound transactions
        var address = preservedAddress
        if payment.direction == .inbound {
            do {
                if let foundAddress = try await findReceivingAddress(
                    for: txid,
                    value: value,
                    transactionDetails: transactionDetails
                ) {
                    address = foundAddress
                }
            } catch {
                Logger.error("Failed to find address for txid \(txid): \(error)", context: "CoreService.processOnchainPayment")
            }

            if contact == nil {
                contact = await privatePaykitContactPublicKey(forReservedAddress: address)
            }
        }

        // Build and save the activity
        let finalDoesExist = isConfirmed ? true : doesExist

        let activityTimestamp: UInt64 = {
            let baseTimestamp = existingOnchain?.timestamp ?? paymentTimestamp

            if let bts = blockTimestamp, bts < baseTimestamp {
                return bts
            }
            return baseTimestamp
        }()

        let onchain = OnchainActivity(
            walletId: WalletScope.default,
            id: payment.id,
            txType: payment.direction == .outbound ? .sent : .received,
            txId: txid,
            value: value,
            fee: (payment.feePaidMsat ?? 0) / 1000,
            feeRate: feeRate,
            address: address,
            confirmed: isConfirmed,
            timestamp: activityTimestamp,
            isBoosted: isBoosted,
            boostTxIds: boostTxIds,
            isTransfer: isTransfer,
            doesExist: finalDoesExist,
            confirmTimestamp: blockTimestamp,
            channelId: channelId,
            transferTxId: transferTxId,
            contact: contact,
            createdAt: UInt64(payment.creationTime.timeIntervalSince1970),
            updatedAt: paymentTimestamp,
            seenAt: seenAt
        )

        if let existingActivity, case let .onchain(existing) = existingActivity {
            try await update(id: existing.id, activity: .onchain(onchain))
        } else {
            try await upsert(.onchain(onchain))
        }
    }

    // MARK: - Onchain Event Handlers

    private func processOnchainTransaction(txid: String, details: BitkitCore.TransactionDetails, context: String) async throws {
        guard let payments = await LightningService.shared.listPayments() else {
            Logger.warn("No payments available for transaction \(txid)", context: context)
            return
        }

        guard let payment = payments.first(where: { payment in
            if case let .onchain(paymentTxid, _) = payment.kind {
                return paymentTxid == txid
            }
            return false
        }) else {
            Logger.warn(
                "Payment not found for transaction \(txid) - activity not created (see docs/ldk-onchain-activity-timing-issue.md)",
                context: context
            )
            return
        }

        try await processOnchainPayment(payment, transactionDetails: details)
    }

    func handleOnchainTransactionReceived(txid: String, details: LDKNode.TransactionDetails) async throws {
        let coreDetails = mapToCoreTransactionDetails(txid: txid, details)

        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertTransactionDetails(detailsList: [coreDetails])
            try await self.processOnchainTransaction(txid: txid, details: coreDetails, context: "CoreService.handleOnchainTransactionReceived")
        }
    }

    func handleOnchainTransactionConfirmed(txid: String, details: LDKNode.TransactionDetails) async throws {
        let coreDetails = mapToCoreTransactionDetails(txid: txid, details)

        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertTransactionDetails(detailsList: [coreDetails])
            try await self.processOnchainTransaction(txid: txid, details: coreDetails, context: "CoreService.handleOnchainTransactionConfirmed")
        }
    }

    func handleOnchainTransactionReplaced(txid: String, conflicts: [String]) async throws {
        try await ServiceQueue.background(.core) {
            // Find the activity for the replaced transaction
            let replacedActivity = try await self.getOnchainActivityByTxId(txid: txid)

            if var existing = replacedActivity {
                Logger.info(
                    "Transaction \(txid) replaced by \(conflicts.count) conflict(s): \(conflicts.joined(separator: ", "))",
                    context: "CoreService.handleOnchainTransactionReplaced"
                )

                // Mark the replaced transaction as not existing
                existing.doesExist = false
                existing.isBoosted = false
                existing.updatedAt = UInt64(Date().timeIntervalSince1970)
                try await self.update(id: existing.id, activity: .onchain(existing))
                Logger.info("Marked transaction \(txid) as replaced", context: "CoreService.handleOnchainTransactionReplaced")
            } else {
                Logger.info(
                    "Activity not found for replaced transaction \(txid) - will be created when transaction is processed",
                    context: "CoreService.handleOnchainTransactionReplaced"
                )
            }

            // For each replacement transaction, update its boostTxIds to include the replaced txid
            for conflictTxid in conflicts {
                // Try to get the replacement activity, or process it if it doesn't exist
                var replacementActivity = try? await self.getOnchainActivityByTxId(txid: conflictTxid)

                if replacementActivity == nil,
                   let payments = await LightningService.shared.listPayments(),
                   let replacementPayment = payments.first(where: { payment in
                       if case let .onchain(paymentTxid, _) = payment.kind {
                           return paymentTxid == conflictTxid
                       }
                       return false
                   })
                {
                    Logger.info(
                        "Processing replacement transaction \(conflictTxid) that was already in payments list",
                        context: "CoreService.handleOnchainTransactionReplaced"
                    )
                    do {
                        try await self.processOnchainPayment(replacementPayment, transactionDetails: nil)
                        replacementActivity = try? await self.getOnchainActivityByTxId(txid: conflictTxid)
                    } catch {
                        Logger.error(
                            "Failed to process replacement transaction \(conflictTxid): \(error)",
                            context: "CoreService.handleOnchainTransactionReplaced"
                        )
                        continue
                    }
                }

                // Update the replacement transaction's boostTxIds to include the replaced txid
                if var activity = replacementActivity,
                   !activity.boostTxIds.contains(txid)
                {
                    activity.boostTxIds.append(txid)
                    activity.isBoosted = true
                    activity.contact = activity.contact ?? replacedActivity?.contact
                    activity.updatedAt = UInt64(Date().timeIntervalSince1970)
                    try await self.update(id: activity.id, activity: .onchain(activity))

                    // Move tags from the replaced transaction
                    if let replacedActivity {
                        do {
                            let replacedTags = try await self.tags(forActivity: replacedActivity.id)
                            if !replacedTags.isEmpty {
                                try await self.appendTags(toActivity: activity.id, replacedTags)
                            }
                        } catch {
                            Logger.error(
                                "Failed to copy tags from replaced transaction \(txid) to replacement transaction \(conflictTxid): \(error)",
                                context: "CoreService.handleOnchainTransactionReplaced"
                            )
                        }
                    }

                    Logger.info(
                        "Updated replacement transaction \(conflictTxid) with boostTxId \(txid)",
                        context: "CoreService.handleOnchainTransactionReplaced"
                    )
                }
            }

            self.activitiesChangedSubject.send()
        }
    }

    func handleOnchainTransactionReorged(txid: String) async throws {
        try await ServiceQueue.background(.core) {
            guard var onchain = try await self.getOnchainActivityByTxId(txid: txid) else {
                Logger.warn("Activity not found for reorged transaction \(txid)", context: "CoreService.handleOnchainTransactionReorged")
                return
            }

            onchain.confirmed = false
            onchain.confirmTimestamp = nil
            onchain.updatedAt = UInt64(Date().timeIntervalSince1970)

            try await self.update(id: onchain.id, activity: .onchain(onchain))
        }
    }

    func handleOnchainTransactionEvicted(txid: String) async throws {
        try await ServiceQueue.background(.core) {
            guard var onchain = try await self.getOnchainActivityByTxId(txid: txid) else {
                Logger.warn("Activity not found for evicted transaction \(txid)", context: "CoreService.handleOnchainTransactionEvicted")
                return
            }

            onchain.doesExist = false
            onchain.updatedAt = UInt64(Date().timeIntervalSince1970)

            try await self.update(id: onchain.id, activity: .onchain(onchain))
        }
    }

    // MARK: - Lightning Event Handlers

    /// Handle a single payment event by processing the specific payment
    func handlePaymentEvent(paymentHash: String) async throws {
        guard let payments = await LightningService.shared.listPayments() else {
            Logger.warn("No payments available for hash \(paymentHash)", context: "CoreService.handlePaymentEvent")
            return
        }

        try await ServiceQueue.background(.core) {
            if let payment = payments.first(where: { $0.id == paymentHash }) {
                try await self.processLightningPayment(payment)
            } else {
                Logger.info("Payment not found for hash \(paymentHash) - syncing all payments", context: "CoreService.handlePaymentEvent")
                try await self.syncLdkNodePayments(payments)
            }
        }
    }

    private func processLightningPayment(_ payment: PaymentDetails) async throws {
        guard case let .bolt11(_, preimage, _, description, bolt11) = payment.kind else { return }

        // Skip pending inbound payments - just means they created an invoice
        guard !(payment.status == .pending && payment.direction == .inbound) else { return }

        let paymentTimestamp = UInt64(payment.latestUpdateTimestamp)
        let existingActivity = try getActivityById(walletId: WalletScope.default, activityId: payment.id)
        let existingLightning: LightningActivity? = if let existingActivity, case let .lightning(ln) = existingActivity { ln } else { nil }

        let state: BitkitCore.PaymentState = switch payment.status {
        case .failed: .failed
        case .pending: .pending
        case .succeeded: .succeeded
        }

        // Skip if existing activity has newer timestamp, unless payment status is changing
        if let existing = existingLightning, let existingUpdatedAt = existing.updatedAt {
            let statusChanging = existing.status != state
            let needsPrivateContactAttribution = existing.contact == nil && payment.direction == .inbound
            if existingUpdatedAt > paymentTimestamp && !statusChanging && !needsPrivateContactAttribution {
                return
            }
        }

        let contact = if let existingContact = existingLightning?.contact {
            existingContact
        } else {
            await privatePaykitContactPublicKey(
                forReceivedInvoicePaymentHash: payment.id,
                direction: payment.direction
            )
        }

        let ln = LightningActivity(
            walletId: WalletScope.default,
            id: payment.id,
            txType: payment.direction == .outbound ? .sent : .received,
            status: state,
            value: UInt64(payment.amountSats ?? 0),
            fee: (payment.feePaidMsat ?? 0) / 1000,
            invoice: bolt11 ?? "No invoice",
            message: description ?? "",
            timestamp: paymentTimestamp,
            preimage: preimage,
            contact: contact,
            createdAt: paymentTimestamp,
            updatedAt: paymentTimestamp,
            seenAt: existingLightning?.seenAt
        )

        if existingActivity != nil {
            try await update(id: payment.id, activity: .lightning(ln))
        } else {
            try await upsert(.lightning(ln))
        }
    }

    private func privatePaykitContactPublicKey(forReceivedInvoicePaymentHash paymentHash: String, direction: PaymentDirection) async -> String? {
        guard direction == .inbound else { return nil }
        return await privateInvoiceContactResolver?(paymentHash)
    }

    private func privatePaykitContactPublicKey(forReservedAddress address: String) async -> String? {
        await privateOnchainAddressContactResolver?(address)
    }

    /// Sync all LDK node payments to activities
    /// Use for initial wallet load, manual refresh, or after operations that create new payments.
    /// Events handle individual payment updates, so this should not be called on every event.
    func syncLdkNodePayments(_ payments: [PaymentDetails]) async throws {
        try await ServiceQueue.background(.core) {
            var addedCount = 0
            var updatedCount = 0
            var latestCaughtError: Error?

            for payment in payments {
                if case let .onchain(txid, _) = payment.kind {
                    do {
                        let hadExistingActivity = try getActivityById(walletId: WalletScope.default, activityId: payment.id) != nil
                        try await self.processOnchainPayment(payment, transactionDetails: nil)
                        if hadExistingActivity {
                            updatedCount += 1
                        } else {
                            addedCount += 1
                        }
                    } catch {
                        Logger.error("Error processing onchain payment \(txid): \(error)", context: "CoreService.syncLdkNodePayments")
                        latestCaughtError = error
                    }
                } else if case .bolt11 = payment.kind {
                    do {
                        let hadExistingActivity = try getActivityById(walletId: WalletScope.default, activityId: payment.id) != nil
                        try await self.processLightningPayment(payment)
                        if hadExistingActivity {
                            updatedCount += 1
                        } else {
                            addedCount += 1
                        }
                    } catch {
                        Logger.error("Error processing lightning payment \(payment.id): \(error)", context: "CoreService.syncLdkNodePayments")
                        latestCaughtError = error
                    }
                }
            }

            // If any of the inserts failed, we want to throw the error up
            if let error = latestCaughtError {
                throw error
            }

            Logger.info("Synced LDK payments - Added: \(addedCount) - Updated: \(updatedCount)", context: "CoreService")
            self.activitiesChangedSubject.send()
        }
    }

    /// Marks replacement transactions (with originalTxId in boostTxIds) as doesExist = false when original confirms
    /// Finds the channel ID associated with a transaction based on its direction
    private func findChannelForTransaction(
        txid: String,
        direction: PaymentDirection,
        transactionDetails: BitkitCore.TransactionDetails? = nil
    ) async -> String? {
        switch direction {
        case .inbound:
            // Check if this transaction is a channel close by checking if it spends a closed channel's funding UTXO
            return await findClosedChannelForTransaction(txid: txid, transactionDetails: transactionDetails)
        case .outbound:
            // Check if this transaction is a channel open by checking if it's the funding transaction for an open channel
            return await findOpenChannelForTransaction(txid: txid)
        }
    }

    /// Check if a transaction spends a closed channel's funding UTXO or is a force close sweep
    private func findClosedChannelForTransaction(txid: String, transactionDetails: BitkitCore.TransactionDetails? = nil) async -> String? {
        do {
            // First, check if this txid is a known sweep transaction using LDK's pending sweep balances
            let pendingSweeps = await MainActor.run { LightningService.shared.balances?.pendingBalancesFromChannelClosures }
            if let pendingSweeps {
                for sweepBalance in pendingSweeps {
                    switch sweepBalance {
                    case let .broadcastAwaitingConfirmation(channelId, _, latestSpendingTxid, _):
                        if latestSpendingTxid.description == txid, let channelId {
                            return channelId.description
                        }
                    case let .awaitingThresholdConfirmations(channelId, latestSpendingTxid, _, _, _):
                        if latestSpendingTxid.description == txid, let channelId {
                            return channelId.description
                        }
                    case .pendingBroadcast:
                        // No txid yet, skip
                        break
                    }
                }
            }

            let closedChannels = try getAllClosedChannels(sortDirection: .desc)
            guard !closedChannels.isEmpty else { return nil }

            let details = if let provided = transactionDetails { provided } else { await fetchTransactionDetails(txid: txid) }
            guard let details else {
                Logger.warn("Transaction details not available for \(txid)", context: "CoreService.findClosedChannelForTransaction")
                return nil
            }

            // Check if any input spends a closed channel's funding UTXO (commitment transaction)
            for input in details.inputs {
                let inputTxid = input.txid
                let inputVout = Int(input.vout)

                if let matchingChannel = closedChannels.first(where: { channel in
                    channel.fundingTxoTxid == inputTxid && channel.fundingTxoIndex == UInt32(inputVout)
                }) {
                    return matchingChannel.channelId
                }
            }
        } catch {
            Logger.warn(
                "Failed to check if transaction \(txid) spends closed channel funding UTXO: \(error)",
                context: "CoreService.findClosedChannelForTransaction"
            )
        }

        return nil
    }

    /// Check if a transaction is the funding transaction for an open channel
    private func findOpenChannelForTransaction(txid: String) async -> String? {
        let channels = await MainActor.run { LightningService.shared.channels }
        guard let channels, !channels.isEmpty else {
            return nil
        }

        // First, check if the transaction matches any channel's funding transaction directly
        if let channel = channels.first(where: { $0.fundingTxo?.txid.description == txid }) {
            return channel.channelId.description
        }

        // If no direct match, check Blocktank orders for payment transactions
        do {
            let orders = try await coreService.blocktank.orders(orderIds: nil, filter: nil, refresh: false)

            // Find order with matching payment transaction
            guard let order = orders.first(where: { order in
                order.payment?.onchain?.transactions.contains { $0.txId == txid } ?? false
            }) else {
                return nil
            }

            // Find channel that matches this order's channel funding transaction
            guard let orderChannel = order.channel else {
                return nil
            }

            if let channel = channels.first(where: { channel in
                channel.fundingTxo?.txid.description == orderChannel.fundingTx.id
            }) {
                return channel.channelId.description
            }
        } catch {
            Logger.warn(
                "Failed to fetch Blocktank orders: \(error)",
                context: "CoreService.findOpenChannelForTransaction"
            )
        }

        return nil
    }

    /// Check pre-activity metadata for addresses in the transaction
    private func findAddressInPreActivityMetadata(details: BitkitCore.TransactionDetails, value: UInt64) async -> String? {
        for output in details.outputs {
            guard let address = output.scriptpubkeyAddress else { continue }
            if let metadata = try? await getPreActivityMetadata(searchKey: address, searchByAddress: true),
               metadata.isReceive
            {
                return address
            }
        }

        return nil
    }

    /// Find the receiving address for an onchain transaction
    private func findReceivingAddress(
        for txid: String,
        value: UInt64,
        transactionDetails: BitkitCore.TransactionDetails? = nil
    ) async throws -> String? {
        let details = if let provided = transactionDetails { provided } else { await fetchTransactionDetails(txid: txid) }
        guard let details else {
            Logger.warn("Transaction details not available for \(txid)", context: "CoreService.findReceivingAddress")
            return nil
        }

        if let address = await findAddressInPreActivityMetadata(details: details, value: value) {
            return address
        }

        let currentWalletAddress = UserDefaults.standard.string(forKey: "onchainAddress") ?? ""
        let selectedAddressType = LDKNode.AddressType.fromStorage(UserDefaults.standard.string(forKey: "selectedAddressType"))

        if let address = try await addressSearchCoordinator.runAddressSearch(
            details: details,
            value: value,
            currentWalletAddress: currentWalletAddress,
            selectedAddressType: selectedAddressType
        ) {
            return address
        }

        return details.outputs.first?.scriptpubkeyAddress
    }

    func getActivity(id: String, walletId: String = WalletScope.default) async throws -> Activity? {
        try await ServiceQueue.background(.core) {
            try getActivityById(walletId: walletId, activityId: id)
        }
    }

    func getOnchainActivityByTxId(txid: String, walletId: String = WalletScope.default) async throws -> OnchainActivity? {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getActivityByTxId(walletId: walletId, txId: txid)
        }
    }

    /// Checks if an on-chain activity exists for a given txid (e.g., a sweep tx has been synced)
    func hasOnchainActivityForTxid(txid: String) async -> Bool {
        await (try? getOnchainActivityByTxId(txid: txid)) != nil
    }

    /// Checks if an on-chain activity exists for a given channel (e.g., close tx has been synced)
    func hasOnchainActivityForChannel(channelId: String) async -> Bool {
        guard let activities = try? await get(filter: .onchain, limit: 50, sortDirection: .desc) else {
            return false
        }
        return activities.contains { activity in
            if case let .onchain(onchain) = activity {
                return onchain.channelId == channelId
            }
            return false
        }
    }

    /// Fetch activities. `walletId` defaults to the normal Bitkit wallet; pass `nil` to query
    /// every wallet globally (Bitkit + watch-only hardware wallets) for the merged Home / All
    /// Activity lists.
    func get(
        filter: ActivityFilter? = nil,
        txType: PaymentType? = nil,
        tags: [String]? = nil,
        search: String? = nil,
        minDate: UInt64? = nil,
        maxDate: UInt64? = nil,
        limit: UInt32? = nil,
        sortDirection: SortDirection? = nil,
        walletId: String? = WalletScope.default
    ) async throws -> [Activity] {
        try await ServiceQueue.background(.core) {
            try getActivities(
                walletId: walletId,
                filter: filter,
                txType: txType,
                tags: tags,
                search: search,
                minDate: minDate,
                maxDate: maxDate,
                limit: limit,
                sortDirection: sortDirection
            )
        }
    }

    func get(contact publicKey: String, sortDirection: SortDirection = .desc) async throws -> [Activity] {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        // TODO: push contact filtering into BitkitCore once the activity store exposes it.
        // walletId nil → global. Contacts can be assigned to hardware activities, so scoping this to
        // the default wallet would let the assignment succeed and then hide the row it was made on.
        let matches = try await get(filter: .all, sortDirection: sortDirection, walletId: nil)
            .filter { activity in
                switch activity {
                case let .lightning(lightning):
                    return PubkyPublicKeyFormat.matches(lightning.contact, normalizedKey)
                case let .onchain(onchain):
                    return PubkyPublicKeyFormat.matches(onchain.contact, normalizedKey)
                }
            }

        // Boost chains never cross wallets, so each wallet is checked against its own cached set —
        // one shared set would test a hardware row against the normal wallet's boost ids. Resolved
        // after contact filtering so only the wallets that actually matched are warmed.
        var txIdsInBoostTxIdsByWallet: [String: Set<String>] = [:]
        for walletId in Set(matches.map(ActivityScope.walletId(of:))) {
            txIdsInBoostTxIdsByWallet[walletId] = await getTxIdsInBoostTxIds(walletId: walletId)
        }

        return matches.filter {
            !isReplacedSentTransaction($0, txIdsInBoostTxIds: txIdsInBoostTxIdsByWallet[ActivityScope.walletId(of: $0)] ?? [])
        }
    }

    private func isReplacedSentTransaction(_ activity: Activity, txIdsInBoostTxIds: Set<String>) -> Bool {
        guard case let .onchain(onchain) = activity else { return false }
        return !onchain.doesExist && onchain.txType == .sent && txIdsInBoostTxIds.contains(onchain.txId)
    }

    func update(id: String, activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try updateActivity(activityId: id, activity: activity)
            self.updateBoostTxIdsCache(for: activity)
            self.activitiesChangedSubject.send()
        }
    }

    func upsert(_ activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try upsertActivity(activity: activity)
            self.updateBoostTxIdsCache(for: activity)
            self.activitiesChangedSubject.send()
        }
    }

    /// Create sent onchain activity from send result so it appears immediately; LDK events update it later (e.g. confirmation).
    ///
    /// `walletId` scopes the row: a transfer funded from a watch-only hardware wallet is written
    /// under that wallet's id, so the merged activity list shows one hardware-owned transfer row
    /// rather than a main-wallet row plus a hardware duplicate.
    func createSentOnchainActivityFromSendResult(
        txid: String,
        address: String,
        amount: UInt64,
        fee: UInt64,
        feeRate: UInt32,
        isTransfer: Bool = false,
        contact: String? = nil,
        walletId: String = WalletScope.default
    ) async {
        let normalizedContact = contact.map { PubkyPublicKeyFormat.normalized($0) ?? $0 }
        do {
            try await ServiceQueue.background(.core) {
                if let existing = try? BitkitCore.getActivityByTxId(walletId: walletId, txId: txid) {
                    var updated = existing
                    if isTransfer {
                        updated.isTransfer = true
                    }
                    if let normalizedContact {
                        updated.contact = normalizedContact
                    }
                    if updated != existing {
                        try updateActivity(activityId: existing.id, activity: .onchain(updated))
                        self.activitiesChangedSubject.send()
                    }
                    Logger.debug("Activity already exists for txid \(txid), skipping immediate creation", context: "ActivityService")
                    return
                }
                let now = UInt64(Date().timeIntervalSince1970)
                let onchain = OnchainActivity(
                    walletId: walletId,
                    id: txid,
                    txType: .sent,
                    txId: txid,
                    value: amount,
                    fee: fee,
                    feeRate: UInt64(feeRate),
                    address: address,
                    confirmed: false,
                    timestamp: now,
                    isBoosted: false,
                    boostTxIds: [],
                    isTransfer: isTransfer,
                    doesExist: true,
                    confirmTimestamp: nil,
                    channelId: nil,
                    transferTxId: nil,
                    contact: normalizedContact,
                    createdAt: now,
                    updatedAt: now,
                    seenAt: now
                )
                try upsertActivity(activity: .onchain(onchain))
                self.updateBoostTxIdsCache(for: .onchain(onchain))
                self.activitiesChangedSubject.send()
                Logger.info("Created sent onchain activity for txid \(txid) from send result", context: "ActivityService")
            }
        } catch {
            Logger.error("Failed to create sent onchain activity for txid \(txid): \(error)", context: "ActivityService")
        }
    }

    /// Atomically mark the on-chain activity for `txId` as a transfer associated with `channelId`,
    /// in a single core-queue transaction so a concurrent watcher sync can't clobber it. No-op when
    /// no matching activity exists or it is already correctly tagged.
    ///
    /// The funding transaction can live under the normal wallet or, when it was signed on a
    /// hardware wallet, under that device's wallet id, so every scope is searched.
    func markOnchainActivityAsTransfer(txId: String, channelId: String) async {
        do {
            try await ServiceQueue.background(.core) {
                guard let existing = try Self.findOnchainActivityAcrossWallets(txId: txId) else { return }
                if existing.isTransfer, existing.channelId == channelId { return }
                var updated = existing
                updated.isTransfer = true
                updated.channelId = channelId
                try updateActivity(activityId: existing.id, activity: .onchain(updated))
                self.activitiesChangedSubject.send()
                Logger.debug("Marked activity \(existing.id) as transfer for channel \(channelId)", context: "ActivityService")
            }
        } catch {
            Logger.error("Failed to mark activity as transfer for \(txId): \(error)", context: "ActivityService")
        }
    }

    /// Resolve the on-chain activity for `txId`, preferring the row that most likely represents the
    /// transfer: one already flagged as a transfer, then a hardware-wallet send (the hardware
    /// funding path), then whatever else matches.
    private static func findOnchainActivityAcrossWallets(txId: String) throws -> OnchainActivity? {
        let defaultMatch = try? BitkitCore.getActivityByTxId(walletId: WalletScope.default, txId: txId)
        // The normal wallet sorts first in the preference order below, so a row it already flags as
        // a transfer is the answer. Skip the cross-wallet scan, which has to read every stored
        // activity in every wallet — core exposes no wallet-id enumeration. This is the common
        // path: the normal transfer flow writes the row through
        // `createSentOnchainActivityFromSendResult(isTransfer: true)` before this runs.
        if let defaultMatch, defaultMatch.isTransfer { return defaultMatch }

        var matches: [OnchainActivity] = []
        if let defaultMatch { matches.append(defaultMatch) }
        matches += try storedWalletIds().subtracting([WalletScope.default]).sorted()
            .compactMap { try? BitkitCore.getActivityByTxId(walletId: $0, txId: txId) }

        return matches.first { $0.isTransfer }
            ?? matches.first { $0.walletId != WalletScope.default && $0.txType == .sent }
            ?? matches.first
    }

    private static func storedWalletIds() throws -> Set<String> {
        let activities = try getActivities(
            walletId: nil,
            filter: .all,
            txType: nil,
            tags: nil,
            search: nil,
            minDate: nil,
            maxDate: nil,
            limit: nil,
            sortDirection: nil
        )
        return Set(activities.map(ActivityScope.walletId(of:)))
    }

    func setContact(_ publicKey: String?, forActivity id: String, walletId: String = WalletScope.default) async throws {
        let normalizedContact = publicKey.map { PubkyPublicKeyFormat.normalized($0) ?? $0 }

        try await ServiceQueue.background(.core) {
            guard let activity = try getActivityById(walletId: walletId, activityId: id) ?? (try? BitkitCore.getActivityByTxId(
                walletId: walletId,
                txId: id
            )).map(Activity.onchain) else {
                throw AppError(message: "Activity not found", debugMessage: "Activity with ID \(id) not found")
            }

            switch activity {
            case var .lightning(lightning):
                guard lightning.contact != normalizedContact else { return }
                lightning.contact = normalizedContact
                lightning.updatedAt = UInt64(Date().timeIntervalSince1970)
                try updateActivity(activityId: lightning.id, activity: .lightning(lightning))
                self.activitiesChangedSubject.send()

            case var .onchain(onchain):
                let contactChanged = onchain.contact != normalizedContact
                if contactChanged {
                    onchain.contact = normalizedContact
                    onchain.updatedAt = UInt64(Date().timeIntervalSince1970)
                    try updateActivity(activityId: onchain.id, activity: .onchain(onchain))
                }

                let replacementContactChanged = try self.updateReplacementContactIfNeeded(
                    for: onchain,
                    normalizedContact: normalizedContact,
                    walletId: walletId
                )
                if contactChanged || replacementContactChanged {
                    self.activitiesChangedSubject.send()
                }
            }
        }
    }

    private func updateReplacementContactIfNeeded(
        for activity: OnchainActivity,
        normalizedContact: String?,
        walletId: String = WalletScope.default
    ) throws -> Bool {
        guard !activity.doesExist, activity.txType == .sent else { return false }

        let activities = try getActivities(
            walletId: walletId,
            filter: .onchain,
            txType: nil,
            tags: nil,
            search: nil,
            minDate: nil,
            maxDate: nil,
            limit: nil,
            sortDirection: nil
        )
        var didUpdate = false
        for case var .onchain(replacement) in activities where replacement.boostTxIds.contains(activity.txId) {
            guard replacement.contact != normalizedContact else { continue }
            replacement.contact = normalizedContact
            replacement.updatedAt = UInt64(Date().timeIntervalSince1970)
            try updateActivity(activityId: replacement.id, activity: .onchain(replacement))
            didUpdate = true
        }
        return didUpdate
    }

    func delete(id: String, walletId: String = WalletScope.default) async throws -> Bool {
        try await ServiceQueue.background(.core) {
            // Rebuild cache if deleting an onchain activity with boostTxIds
            let activity = try? getActivityById(walletId: walletId, activityId: id)
            if let activity, case let .onchain(onchain) = activity, !onchain.boostTxIds.isEmpty {
                await self.refreshBoostTxIdsCache(walletId: walletId)
            }

            let result = try deleteActivityById(walletId: walletId, activityId: id)
            self.activitiesChangedSubject.send()
            self.notifyHardwareTagsChanged(walletId: walletId)
            return result
        }
    }

    // MARK: - Tag Methods

    func appendTags(toActivity id: String, _ tags: [String], walletId: String = WalletScope.default) async throws {
        try await ServiceQueue.background(.core) {
            try addTags(walletId: walletId, activityId: id, tags: tags)
            self.activitiesChangedSubject.send()
            self.notifyHardwareTagsChanged(walletId: walletId)
        }
    }

    func dropTags(fromActivity id: String, _ tags: [String], walletId: String = WalletScope.default) async throws {
        try await ServiceQueue.background(.core) {
            try removeTags(walletId: walletId, activityId: id, tags: tags)
            self.activitiesChangedSubject.send()
            self.notifyHardwareTagsChanged(walletId: walletId)
        }
    }

    /// Hardware wallet tags ride in the metadata backup rather than the activity one, so a change
    /// to them has to mark that envelope stale. Default-wallet tags are carried by the activity
    /// backup, which `activitiesChangedSubject` already covers.
    private func notifyHardwareTagsChanged(walletId: String) {
        guard walletId != WalletScope.default else { return }
        metadataChangedSubject.send()
    }

    func tags(forActivity id: String, walletId: String = WalletScope.default) async throws -> [String] {
        try await ServiceQueue.background(.core) {
            try getTags(walletId: walletId, activityId: id)
        }
    }

    func allPossibleTags() async throws -> [String] {
        try await ServiceQueue.background(.core) {
            try getAllUniqueTags()
        }
    }

    /// Tags for the normal Bitkit wallet only. Watch-only hardware wallets are re-derived from the
    /// device on pairing, so their activities are left out of the backup payload — and a tag whose
    /// activity is missing would fail core's foreign key on restore. Their tags travel in the
    /// metadata backup instead, see `getHardwareTagsAsPreActivityMetadata`.
    func getAllActivitiesTags() async throws -> [ActivityTags] {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getAllActivitiesTags().filter { $0.walletId == WalletScope.default }
        }
    }

    /// Tags on watch-only hardware activities, shaped as `PreActivityMetadata` for the metadata
    /// backup — see `HwActivityTagBackup` for why they cannot ride the activity backup.
    func getHardwareTagsAsPreActivityMetadata() async throws -> [BitkitCore.PreActivityMetadata] {
        try await ServiceQueue.background(.core) { () throws -> [BitkitCore.PreActivityMetadata] in
            // The wrapper above is filtered to the default wallet; this needs its inverse, and
            // calling the wrapper from here would re-enter the core queue.
            let hardwareTags = try BitkitCore.getAllActivitiesTags().filter { $0.walletId != WalletScope.default }
            guard !hardwareTags.isEmpty else { return [] }

            let activities = try Set(hardwareTags.map(\.walletId)).sorted().flatMap { walletId in
                try Self.storedOnchainActivities(walletId: walletId)
            }

            return HwActivityTagBackup.preActivityMetadata(activities: activities, tags: hardwareTags)
        }
    }

    /// The slice of the metadata backup's tag data that belongs to `walletId`, built the same way the
    /// envelope builds it so a caller can preserve a wallet's tags across a deletion.
    ///
    /// Both sources are needed: core drops a wallet's stored `PreActivityMetadata` along with its
    /// activities, and those rows are not covered by the rendered set, which only shapes tags that
    /// already reached an activity.
    func tagMetadata(forWallet walletId: String) async throws -> [BitkitCore.PreActivityMetadata] {
        try await ServiceQueue.background(.core) { () throws -> [BitkitCore.PreActivityMetadata] in
            let stored = try BitkitCore.getAllPreActivityMetadata().filter { $0.walletId == walletId }
            let hardwareTags = try BitkitCore.getAllActivitiesTags().filter { $0.walletId == walletId }
            let rendered = try hardwareTags.isEmpty
                ? []
                : HwActivityTagBackup.preActivityMetadata(
                    activities: Self.storedOnchainActivities(walletId: walletId),
                    tags: hardwareTags
                )

            // Rendered first, matching the envelope build and for the same reason: a stored row can
            // outlive the activity it was meant for and hold tags the user has since edited, and
            // keeping a wallet's tags means keeping what the user currently sees.
            return HwActivityTagBackup.deduplicated(rendered + stored)
        }
    }

    func upsertTags(_ activityTags: [ActivityTags]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertTags(activityTags: activityTags)
        }
    }

    // MARK: - Pre-Activity Metadata Methods

    func addPreActivityMetadata(_ preActivityMetadata: BitkitCore.PreActivityMetadata) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.addPreActivityMetadata(preActivityMetadata: preActivityMetadata)
            self.metadataChangedSubject.send()
        }
    }

    func addPreActivityMetadataTags(paymentId: String, tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.addPreActivityMetadataTags(walletId: WalletScope.default, paymentId: paymentId, tags: tags)
            self.metadataChangedSubject.send()
        }
    }

    func removePreActivityMetadataTags(paymentId: String, tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.removePreActivityMetadataTags(walletId: WalletScope.default, paymentId: paymentId, tags: tags)
            self.metadataChangedSubject.send()
        }
    }

    func getPreActivityMetadata(searchKey: String, searchByAddress: Bool = false) async throws -> BitkitCore.PreActivityMetadata? {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getPreActivityMetadata(walletId: WalletScope.default, searchKey: searchKey, searchByAddress: searchByAddress)
        }
    }

    func deletePreActivityMetadata(paymentId: String) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.deletePreActivityMetadata(walletId: WalletScope.default, paymentId: paymentId)
            self.metadataChangedSubject.send()
        }
    }

    func resetPreActivityMetadataTags(paymentId: String) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.resetPreActivityMetadataTags(walletId: WalletScope.default, paymentId: paymentId)
            self.metadataChangedSubject.send()
        }
    }

    // MARK: - Pre-Activity Metadata Methods (for backup service)

    func upsertPreActivityMetadata(_ preActivityMetadata: [BitkitCore.PreActivityMetadata]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertPreActivityMetadata(preActivityMetadata: preActivityMetadata)
            // Rows written back after a hardware wallet's delete cascade have to reach the next
            // envelope; a restore's own upsert is inert here, since `shouldSkipBackup` gates it.
            self.metadataChangedSubject.send()
        }
    }

    func getAllPreActivityMetadata() async throws -> [BitkitCore.PreActivityMetadata] {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getAllPreActivityMetadata()
        }
    }

    func boostOnchainTransaction(activityId: String, feeRate: UInt32) async throws -> String {
        return try await ServiceQueue.background(.core) {
            // Get the existing activity
            guard let existingActivity = try getActivityById(walletId: WalletScope.default, activityId: activityId) else {
                throw AppError(message: "Activity not found", debugMessage: "Activity with ID \(activityId) not found")
            }

            // Only onchain activities can be boosted
            guard case var .onchain(onchainActivity) = existingActivity else {
                throw AppError(message: "Only onchain activities can be boosted", debugMessage: "Activity \(activityId) is not an onchain activity")
            }

            let txid: String

            if onchainActivity.txType == .received {
                Logger.info("Executing CPFP boost for incoming transaction", context: "CoreService.boostOnchainTransaction")
                Logger.debug("Parent transaction ID: \(onchainActivity.txId)", context: "CoreService.boostOnchainTransaction")

                // Use CPFP for incoming transactions
                txid = try await LightningService.shared.accelerateByCpfp(
                    txid: onchainActivity.txId,
                    satsPerVbyte: feeRate
                )

                Logger.info("CPFP transaction created successfully: \(txid)", context: "CoreService.boostOnchainTransaction")

                // For CPFP, mark the original activity as boosted (parent transaction still exists)
                onchainActivity.isBoosted = true
                onchainActivity.boostTxIds.append(txid)
                try await self.update(id: activityId, activity: .onchain(onchainActivity))
                Logger.info("Successfully marked activity \(activityId) as boosted via CPFP", context: "CoreService.boostOnchainTransaction")
            } else {
                Logger.info("Executing RBF boost for outgoing transaction", context: "CoreService.boostOnchainTransaction")
                Logger.debug("Original transaction ID: \(onchainActivity.txId)", context: "CoreService.boostOnchainTransaction")

                // Use RBF for outgoing transactions
                txid = try await LightningService.shared.bumpFeeByRbf(
                    txid: onchainActivity.txId,
                    satsPerVbyte: feeRate
                )

                Logger.info("RBF transaction created successfully: \(txid)", context: "CoreService.boostOnchainTransaction")

                // For RBF, mark the original activity as boosted and update the fee rate
                // so the UI shows the correct confirmation time estimate until the replacement arrives
                onchainActivity.isBoosted = true
                onchainActivity.feeRate = UInt64(feeRate)
                try await self.update(id: activityId, activity: .onchain(onchainActivity))
                Logger.info(
                    "Successfully marked activity \(activityId) as replaced by fee",
                    context: "CoreService.boostOnchainTransaction"
                )
            }

            return txid
        }
    }

    func generateRandomTestData() async throws {
        let testDataSets = generateTestDataSets()

        try await ServiceQueue.background(.core) {
            var activityId = 0

            for (periodName, baseTimestamp, activities) in testDataSets {
                Logger.info("Generating \(periodName) test data with \(activities.count) activities", context: "CoreService")

                for template in activities {
                    let timestamp = baseTimestamp + UInt64.random(in: 0 ... 3600) // Add some randomness within the day
                    let id = "test-\(periodName.lowercased())-\(template.type.rawValue)-\(activityId)"

                    let activity: Activity = switch template.type {
                    case .lightning:
                        .lightning(
                            LightningActivity(
                                walletId: WalletScope.default,
                                id: id,
                                txType: template.txType,
                                status: template.status,
                                value: template.value,
                                fee: UInt64.random(in: 1 ... 1000),
                                invoice: "lnbc\(template.value)",
                                message: template.message,
                                timestamp: timestamp,
                                preimage: template.status == .succeeded ? "preimage\(activityId)" : nil,
                                contact: nil,
                                createdAt: timestamp,
                                updatedAt: timestamp,
                                seenAt: nil
                            )
                        )
                    case .onchain:
                        .onchain(
                            OnchainActivity(
                                walletId: WalletScope.default,
                                id: id,
                                txType: template.txType,
                                txId: String(repeating: "a", count: 64),
                                value: template.value,
                                fee: UInt64.random(in: 100 ... 200),
                                feeRate: UInt64.random(in: 1 ... 5),
                                address: "bc1...\(activityId)",
                                confirmed: template.confirmed ?? false,
                                timestamp: timestamp,
                                isBoosted: template.isBoosted ?? false,
                                boostTxIds: template.boostTxIds,
                                isTransfer: template.isTransfer ?? false,
                                doesExist: true,
                                confirmTimestamp: template.confirmed == true ? timestamp + 3600 : nil,
                                channelId: nil,
                                transferTxId: nil,
                                contact: nil,
                                createdAt: timestamp,
                                updatedAt: timestamp,
                                seenAt: nil
                            )
                        )
                    }

                    // Insert activity
                    try insertActivity(activity: activity)

                    // Add tags
                    if !template.tags.isEmpty {
                        try await self.appendTags(toActivity: id, template.tags)
                    }

                    activityId += 1
                }
            }

            Logger.info("Generated \(activityId) test activities across all time periods", context: "CoreService")
            self.activitiesChangedSubject.send()
        }
    }
}

// MARK: - Address search (actor for single-flight concurrency)

private actor AddressSearchCoordinator {
    private var isSearching = false
    private var waitQueue: [CheckedContinuation<Void, Never>] = []

    /// Runs the batch address search at most one at a time. Enqueues if a search is already in progress.
    func runAddressSearch(
        details: BitkitCore.TransactionDetails,
        value: UInt64,
        currentWalletAddress: String,
        selectedAddressType: LDKNode.AddressType
    ) async throws -> String? {
        if isSearching {
            await withCheckedContinuation { waitQueue.append($0) }
        }
        isSearching = true
        defer {
            isSearching = false
            if !waitQueue.isEmpty {
                waitQueue.removeFirst().resume()
            }
        }
        return try await searchReceivingAddress(
            details: details, value: value,
            currentWalletAddress: currentWalletAddress,
            selectedAddressType: selectedAddressType
        )
    }

    private func searchReceivingAddress(
        details: BitkitCore.TransactionDetails,
        value: UInt64,
        currentWalletAddress: String,
        selectedAddressType: LDKNode.AddressType
    ) async throws -> String? {
        let batchSize: UInt32 = 200
        let searchWindow: UInt32 = 1000

        func matchesTransaction(_ address: String) -> Bool {
            details.outputs.contains { $0.scriptpubkeyAddress == address }
        }

        func findMatch(in addresses: [String]) -> String? {
            if let exact = details.outputs.first(where: { $0.value == value }),
               let addr = exact.scriptpubkeyAddress, addresses.contains(addr)
            { return addr }
            return addresses.first { matchesTransaction($0) }
        }

        if !currentWalletAddress.isEmpty, matchesTransaction(currentWalletAddress) {
            return currentWalletAddress
        }

        let addressTypesToSearch = LDKNode.AddressType.prioritized(selected: selectedAddressType)

        let keychains: [(isChange: Bool, keychain: LDKNode.KeychainKind)] = [
            (false, .external),
            (true, .internal),
        ]

        for (isChange, keychain) in keychains {
            for addressType in addressTypesToSearch {
                let key = isChange ? "addressSearch_lastUsedChangeIndex_\(addressType.stringValue)" : "addressSearch_lastUsedReceiveIndex_\(addressType.stringValue)"
                let lastUsed: UInt32? = (UserDefaults.standard.object(forKey: key) as? Int).flatMap {
                    guard $0 >= 0, $0 <= Int(UInt32.max) else { return nil }
                    return UInt32($0)
                }
                let endIndex = lastUsed.map { $0 > UInt32.max - searchWindow ? UInt32.max : $0 + searchWindow } ?? searchWindow

                var index: UInt32 = 0
                var currentAddressBatch: UInt32?
                while index < endIndex {
                    let addresses: [String]
                    do {
                        addresses = try await LightningService.shared
                            .addressInfosForType(addressType, keychain: keychain, startIndex: index, count: batchSize)
                            .map(\.address)
                    } catch {
                        Logger.warn(
                            "Skipping \(addressType.stringValue) \(isChange ? "change" : "receive") address search batch \(index): \(error)",
                            context: "CoreService.AddressSearch"
                        )
                        break
                    }

                    if !currentWalletAddress.isEmpty, currentAddressBatch == nil, addresses.contains(currentWalletAddress) {
                        currentAddressBatch = index
                    }
                    if let match = findMatch(in: addresses) {
                        UserDefaults.standard.set(Int(index), forKey: key)
                        return match
                    }
                    if let found = currentAddressBatch {
                        let stopIndex = found > UInt32.max - batchSize ? UInt32.max : found + batchSize
                        if index >= stopIndex { break }
                    }
                    index += batchSize
                }
            }
        }
        return nil
    }
}

// MARK: - Test Data Generation (Development Only)

private struct ActivityTemplate {
    enum ActivityType: String {
        case lightning
        case onchain
    }

    let type: ActivityType
    let txType: PaymentType
    let status: BitkitCore.PaymentState
    let value: UInt64
    let message: String
    let tags: [String]
    let confirmed: Bool?
    let isBoosted: Bool?
    let boostTxIds: [String]
    let isTransfer: Bool?

    init(
        type: ActivityType,
        txType: PaymentType,
        status: BitkitCore.PaymentState,
        value: UInt64,
        message: String,
        tags: [String] = [],
        confirmed: Bool? = nil,
        isBoosted: Bool? = nil,
        isTransfer: Bool? = nil,
        boostTxIds: [String] = []
    ) {
        self.type = type
        self.txType = txType
        self.status = status
        self.value = value
        self.message = message
        self.tags = tags
        self.confirmed = confirmed
        self.isBoosted = isBoosted
        self.isTransfer = isTransfer
        self.boostTxIds = boostTxIds
    }
}

private func generateTestDataSets() -> [(String, UInt64, [ActivityTemplate])] {
    let now = UInt64(Date().timeIntervalSince1970)
    let today = now
    let yesterday = now - 86400 // 24 hours ago
    let thisWeek = now - 3 * 86400 // 3 days ago
    let thisMonth = now - 15 * 86400 // 15 days ago
    let thisYear = now - 90 * 86400 // 90 days ago
    let earlier = now - 300 * 86400 // 300 days ago

    // swiftformat:disable all
    return [
        ("Today", today, [
            // Lightning activities for today
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 50000, message: "Coffee at Starbucks", tags: ["coffee"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 25000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .pending, value: 15000, message: "", tags: ["transport"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 10000, message: "", tags: []),
            
            // Onchain activities for today
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 800000, message: "Monthly rent", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 20000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 30000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 100000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 200000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 75000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 20000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 30000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 100000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 200000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: true),
        ]),
        
        ("Yesterday", yesterday, [
            // Lightning activities for yesterday
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 35000, message: "Lunch with friends", tags: ["food", "friends"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 8000, message: "", tags: ["entertainment"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .failed, value: 12000, message: "", tags: ["food", "shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .pending, value: 5000, message: "", tags: []),
            
            // Onchain activities for yesterday
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 200000, message: "Large purchase", tags: ["shopping"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 50000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 15000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 25000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("This Week", thisWeek, [
            // Lightning activities for this week
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 45000, message: "Gas station", tags: ["transport"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 18000, message: "Freelance work", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 22000, message: "Online shopping", tags: ["shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 12000, message: "", tags: []),
            
            // Onchain activities for this week
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 150000, message: "Car payment", tags: ["transport"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 80000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 25000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 30000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("This Month", thisMonth, [
            // Lightning activities for this month
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 60000, message: "Restaurant dinner", tags: ["food"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 35000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 28000, message: "", tags: ["entertainment"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 15000, message: "", tags: ["shopping"]),
            
            // Onchain activities for this month
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 300000, message: "Investment", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 120000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 50000, message: "", tags: [], confirmed: true, isBoosted: true, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 40000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("This Year", thisYear, [
            // Lightning activities for this year
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 80000, message: "Vacation booking", tags: ["travel"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 120000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 45000, message: "", tags: ["shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 25000, message: "", tags: ["family"]),
            
            // Onchain activities for this year
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 500000, message: "Home improvement", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 200000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 75000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 60000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("Earlier", earlier, [
            // Lightning activities for earlier
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 100000, message: "Major purchase", tags: ["shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 150000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 60000, message: "", tags: ["travel"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 40000, message: "", tags: ["work"]),
            
            // Onchain activities for earlier
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 1000000, message: "Real estate", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 500000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 100000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 80000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
    ]
    // swiftformat:enable all
}

// MARK: - Blocktank Service

class BlocktankService {
    private let coreService: CoreService

    private let stateChangedSubject = PassthroughSubject<Void, Never>()

    var stateChangedPublisher: AnyPublisher<Void, Never> {
        stateChangedSubject.eraseToAnyPublisher()
    }

    init(coreService: CoreService) {
        self.coreService = coreService
    }

    func info(refresh: Bool = true) async throws -> IBtInfo? {
        try await ServiceQueue.background(.core) {
            try await getInfo(refresh: refresh)
        }
    }

    func fees(refresh: Bool = true) async throws -> FeeRates? {
        try await info(refresh: refresh)?.onchain.feeRates
    }

    func createCjit(
        channelSizeSat: UInt64,
        invoiceSat: UInt64,
        invoiceDescription: String,
        nodeId: String,
        channelExpiryWeeks: UInt32,
        options: CreateCjitOptions
    ) async throws -> IcJitEntry {
        Logger.info("Creating CJIT invoice with channel size: \(channelSizeSat) and invoice amount: \(invoiceSat)", context: "BlocktankService")

        return try await ServiceQueue.background(.core) {
            let entry = try await createCjitEntry(
                channelSizeSat: channelSizeSat,
                invoiceSat: invoiceSat,
                invoiceDescription: invoiceDescription,
                nodeId: nodeId,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
            self.stateChangedSubject.send()
            return entry
        }
    }

    func cjitOrders(entryIds: [String]? = nil, filter: CJitStateEnum? = nil, refresh: Bool = true) async throws -> [IcJitEntry] {
        try await ServiceQueue.background(.core) {
            try await getCjitEntries(entryIds: entryIds, filter: filter, refresh: refresh)
        }
    }

    func getCjit(channel: ChannelDetails) async -> IcJitEntry? {
        do {
            let orders = try await cjitOrders()
            return orders.first { order in
                order.channelSizeSat == channel.channelValueSats && order.lspNode.pubkey == channel.counterpartyNodeId
            }
        } catch {
            return nil
        }
    }

    func newOrder(
        lspBalanceSat: UInt64,
        channelExpiryWeeks: UInt32,
        options: CreateOrderOptions
    ) async throws -> IBtOrder {
        try await ServiceQueue.background(.core) {
            let order = try await createOrder(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
            self.stateChangedSubject.send()
            return order
        }
    }

    func estimateFee(
        lspBalanceSat: UInt64,
        channelExpiryWeeks: UInt32,
        options: CreateOrderOptions? = nil
    ) async throws -> IBtEstimateFeeResponse2 {
        try await ServiceQueue.background(.core) {
            try await estimateOrderFeeFull(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    func orders(orderIds: [String]? = nil, filter: BtOrderState2? = nil, refresh: Bool = true) async throws -> [IBtOrder] {
        try await ServiceQueue.background(.core) {
            try await getOrders(orderIds: orderIds, filter: filter, refresh: refresh)
        }
    }

    func upsertOrdersList(_ orders: [IBtOrder]) async throws {
        try await ServiceQueue.background(.core) {
            try await upsertOrders(orders: orders)
        }
    }

    func upsertCjitEntriesList(_ cjitEntries: [IcJitEntry]) async throws {
        try await ServiceQueue.background(.core) {
            try await upsertCjitEntries(entries: cjitEntries)
        }
    }

    func setInfo(_ info: IBtInfo) async throws {
        try await ServiceQueue.background(.core) {
            try await upsertInfo(info: info)
        }
    }

    /// Notifies that blocktank state has changed (e.g., after refreshing data)
    func notifyStateChanged() {
        stateChangedSubject.send()
    }

    @discardableResult
    func open(orderId: String) async throws -> IBtOrder {
        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        let latestOrder = try await ServiceQueue.background(.core) {
            try await getOrders(orderIds: [orderId], filter: nil, refresh: true).first
        }

        guard latestOrder?.state2 == .paid else {
            throw AppError(message: "Order not paid", debugMessage: "Order state: \(String(describing: latestOrder?.state2))")
        }

        return try await ServiceQueue.background(.core) {
            try await openChannel(orderId: orderId, connectionString: nodeId)
        }
    }

    // MARK: Notifications

    func registerDeviceForNotifications(
        deviceToken: String, publicKey: String, features: [String], nodeId: String, isoTimestamp: String, signature: String
    ) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await registerDevice(
                deviceToken: deviceToken,
                publicKey: publicKey,
                features: features,
                nodeId: nodeId,
                isoTimestamp: isoTimestamp,
                signature: signature,
                isProduction: !Env.isDebug,
                customUrl: Env.blocktankPushNotificationServer
            )
        }
    }

    func pushNotificationTest(deviceToken: String, secretMessage: String, notificationType: String?) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await testNotification(
                deviceToken: deviceToken,
                secretMessage: secretMessage,
                notificationType: notificationType,
                customUrl: Env.blocktankPushNotificationServer
            )
        }
    }

    // MARK: Regtest only methods

    private func executeWithRetry<T>(maxRetries: Int = 6, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0 ..< maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                Logger.warn("Regtest operation failed on attempt \(attempt + 1)/\(maxRetries): \(error)", context: "BlocktankService")

                if attempt < maxRetries - 1 {
                    let sleepDuration = UInt64(1 << attempt) // Exponential backoff: 1, 2, 4, 8, 16 seconds
                    Logger.info("Retrying in \(sleepDuration) seconds...", context: "BlocktankService")
                    try await Task.sleep(nanoseconds: sleepDuration * 2_000_000_000)
                }
            }
        }

        throw lastError ?? AppError(message: "Unknown error during retry", debugMessage: nil)
    }

    func regtestMineBlocks(_ count: UInt32 = 1) async throws {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestMine(count: count)
            }
        }
    }

    func regtestDepositFunds(address: String, amountSat: UInt64) async throws -> String {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        return try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestDeposit(address: address, amountSat: amountSat)
            }
        }
    }

    func regtestPayInvoice(_ invoice: String, amountSat: UInt64?) async throws -> String {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        return try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestPay(invoice: invoice, amountSat: amountSat)
            }
        }
    }

    func regtestRemoteCloseChannel(channel: ChannelDetails, forceCloseAfterSeconds: UInt64?) async throws -> String {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        guard let fundingTxo = channel.fundingTxo else {
            throw AppError(message: "Missing channel.fundingTxo", debugMessage: nil)
        }

        return try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestCloseChannel(fundingTxId: fundingTxo.txid, vout: fundingTxo.vout, forceCloseAfterS: forceCloseAfterSeconds)
            }
        }
    }
}

// MARK: - Utility Service

class UtilityService {
    private let coreService: CoreService

    init(coreService: CoreService) {
        self.coreService = coreService
    }

    private func recoveryWalletCredentials(walletIndex: Int) throws -> (mnemonic: String, passphrase: String?) {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw AppError(message: "Mnemonic not found", debugMessage: "Unable to load mnemonic for wallet index \(walletIndex)")
        }

        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        return (mnemonic, passphrase)
    }

    func scanLegacyRnNativeSegwitRecoveryFunds(
        walletIndex: Int = 0,
        indexLimit: UInt32,
        electrumUrl: String = Env.electrumServerUrl
    ) async throws -> LegacyRnCloseRecoveryScanResult {
        try await ServiceQueue.background(.core) {
            let credentials = try self.recoveryWalletCredentials(walletIndex: walletIndex)

            return try await BitkitCore.scanLegacyRnNativeSegwitRecoveryFunds(
                mnemonicPhrase: credentials.mnemonic,
                network: Env.bitkitCoreNetwork,
                electrumUrl: electrumUrl,
                indexLimit: indexLimit,
                bip39Passphrase: credentials.passphrase
            )
        }
    }

    func prepareLegacyRnNativeSegwitRecoverySweep(
        destinationAddress: String,
        feeRateSatsPerVbyte: UInt32?,
        walletIndex: Int = 0,
        indexLimit: UInt32,
        electrumUrl: String = Env.electrumServerUrl
    ) async throws -> LegacyRnCloseRecoverySweepPreview {
        try await ServiceQueue.background(.core) {
            let credentials = try self.recoveryWalletCredentials(walletIndex: walletIndex)

            return try await BitkitCore.prepareLegacyRnNativeSegwitRecoverySweep(
                mnemonicPhrase: credentials.mnemonic,
                network: Env.bitkitCoreNetwork,
                electrumUrl: electrumUrl,
                destinationAddress: destinationAddress,
                feeRateSatsPerVbyte: feeRateSatsPerVbyte,
                indexLimit: indexLimit,
                bip39Passphrase: credentials.passphrase
            )
        }
    }

    func broadcastRawTx(txHex: String, electrumUrl: String = Env.electrumServerUrl) async throws -> String {
        try await ServiceQueue.background(.core) {
            return try await onchainBroadcastRawTx(serializedTx: txHex, electrumUrl: electrumUrl)
        }
    }

    func getAccountAddresses(
        walletIndex: Int = 0,
        isChange: Bool? = nil,
        startIndex: UInt32? = nil,
        count: UInt32? = nil,
        addressTypeString: String? = nil
    ) async throws -> AccountAddresses {
        return try await ServiceQueue.background(.core) {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
                throw AppError(message: "Mnemonic not found", debugMessage: "Unable to load mnemonic for wallet index \(walletIndex)")
            }

            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))

            // Create the correct derivation path based on address type and network
            let coinType = Env.network == .bitcoin ? "0" : "1"
            let addressType = LDKNode.AddressType.fromStorage(addressTypeString)
            let derivationPath = addressType.derivationPath(coinType: coinType)

            let response = try deriveBitcoinAddresses(
                mnemonicPhrase: mnemonic,
                derivationPathStr: derivationPath,
                network: Env.bitkitCoreNetwork,
                bip39Passphrase: passphrase,
                isChange: isChange,
                startIndex: startIndex,
                count: count
            )

            // Convert GetAddressesResponse to AccountAddresses
            let usedAddresses = response.addresses.compactMap { addr -> AddressInfo? in
                // You would determine if an address is used based on your logic
                // For now, we'll create a basic conversion
                return AddressInfo(
                    address: addr.address,
                    path: addr.path,
                    transfers: 0 // This would need to be determined from blockchain data
                )
            }

            let unusedAddresses = response.addresses.compactMap { addr -> AddressInfo? in
                return AddressInfo(
                    address: addr.address,
                    path: addr.path,
                    transfers: 0
                )
            }

            let changeAddresses: [AddressInfo] = []

            return AccountAddresses(
                used: usedAddresses,
                unused: unusedAddresses,
                change: changeAddresses
            )
        }
    }

    /// Check if an address has been used (has any transactions)
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: true if the address has been used, false otherwise
    func isAddressUsed(address: String) async throws -> Bool {
        return try await ServiceQueue.background(.core) {
            try BitkitCore.isAddressUsed(address: address)
        }
    }

    /// Get balance for a specific address in satoshis
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: The current balance in satoshis
    func getAddressBalance(address: String) async throws -> UInt64 {
        return try await LightningService.shared.getAddressBalance(address: address)
    }

    /// Get balances for multiple addresses
    /// - Parameter addresses: Array of Bitcoin addresses to check
    /// - Returns: Dictionary mapping addresses to their balances in satoshis
    func getMultipleAddressBalances(addresses: [String]) async throws -> [String: UInt64] {
        var balances: [String: UInt64] = [:]

        // Fetch balances concurrently for better performance
        await withTaskGroup(of: (String, UInt64?).self) { group in
            for address in addresses {
                group.addTask {
                    do {
                        let balance = try await self.getAddressBalance(address: address)
                        return (address, balance)
                    } catch {
                        Logger.error("Failed to get balance for address \(address): \(error)", context: "UtilityService")
                        return (address, nil)
                    }
                }
            }

            for await (address, balance) in group {
                if let balance {
                    balances[address] = balance
                }
            }
        }

        return balances
    }
}

// MARK: - Core Service requires shared init for both activity and blocktank services

class CoreService {
    static let shared = CoreService()
    private let walletIndex: Int

    lazy var activity: ActivityService = .init(coreService: self)
    lazy var blocktank: BlocktankService = .init(coreService: self)
    lazy var utility: UtilityService = .init(coreService: self)

    private init(walletIndex: Int = 0) {
        self.walletIndex = walletIndex

        _ = try! initDb(basePath: Env.bitkitCoreStorage(walletIndex: walletIndex).path)

        // First thing ever added to the core queue so guarenteed to run first before any of above functions on the same queue
        ServiceQueue.background(.core) {
            try initDb(basePath: Env.bitkitCoreStorage(walletIndex: walletIndex).path)
        } completion: { result in
            switch result {
            case let .success(value):
                Logger.info("bitkit-core database init: \(value)", context: "CoreService")
            case let .failure(error):
                Logger.error("bitkit-core database init failed: \(error)", context: "CoreService")
            }
        }

        ServiceQueue.background(.core) {
            try await updateBlocktankUrl(newUrl: Env.blocktankClientServer)
        } completion: { result in
            switch result {
            case .success():
                Logger.info("Blocktank URL updated to \(Env.blocktankClientServer)", context: "CoreService")
            case let .failure(error):
                Logger.error("Failed to update Blocktank URL: \(error)", context: "CoreService")
            }
        }
    }

    func checkGeoStatus() async throws -> Bool? {
        if !Env.isGeoblockingEnabled {
            return false
        }

        return try await ServiceQueue.background(.core) {
            Logger.info("Checking geo status...", context: "GeoCheck")
            guard let url = URL(string: Env.geoCheckUrl) else {
                Logger.error("Invalid geocheck URL: \(Env.geoCheckUrl)", context: "GeoCheck")
                return nil as Bool?
            }

            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                Logger.debug("Received geo status response: \(httpResponse.statusCode)", context: "GeoCheck")
                switch httpResponse.statusCode {
                case 200:
                    Logger.info("Region allowed", context: "GeoCheck")
                    return false
                case 403:
                    Logger.warn("Region blocked", context: "GeoCheck")
                    return true
                default:
                    Logger.warn("Unexpected status code: \(httpResponse.statusCode)", context: "GeoCheck")
                    return nil as Bool?
                }
            }
            return nil as Bool?
        }
    }
}
