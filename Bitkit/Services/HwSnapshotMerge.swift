import BitkitCore

/// Activity accessors shared by the files that cannot use the `Activity` extensions in
/// `Extensions/Activity+Contact.swift`: this file and `CoreService` are compiled into the
/// notification and test targets, which do not build `Extensions/`.
enum ActivityScope {
    static func id(of activity: Activity) -> String {
        switch activity {
        case let .lightning(lightning): return lightning.id
        case let .onchain(onchain): return onchain.id
        }
    }

    static func walletId(of activity: Activity) -> String {
        switch activity {
        case let .lightning(lightning): return lightning.walletId
        case let .onchain(onchain): return onchain.walletId
        }
    }
}

/// Plans how a hardware-wallet watcher snapshot should replace what bitkit-core already stores for
/// that wallet. Kept pure and free of the core FFI so the reconciliation rules can be unit tested;
/// `ActivityService.replaceHwSnapshot` applies the plan.
enum HwSnapshotMerge {
    private static let pendingSendGracePeriod: UInt64 = 24 * 60 * 60

    struct Plan {
        let toDelete: [OnchainActivity]
        let toUpsert: [Activity]
    }

    /// - Parameter pruneMissing: whether stored rows absent from `incoming` may be deleted. False
    ///   when the caller could only merge some of the wallet's watchers — a partial snapshot cannot
    ///   mention the rows owned by a watcher that has not reported yet, and core's
    ///   `delete_activity_by_id` cascades into `activity_tags`, so pruning one destroys user tags
    ///   that are no longer carried in the backup payload. Upserting is always safe.
    /// - Parameter transferChannelIdsByFundingTxId: funding tx id → channel id for transfers the app
    ///   recorded itself, used to recover transfer metadata that has no stored row to come from.
    static func plan(
        existing: [OnchainActivity],
        incoming: [Activity],
        pruneMissing: Bool,
        currentTimestamp: UInt64,
        transferChannelIdsByFundingTxId: [String: String] = [:]
    ) -> Plan {
        let incomingIds = Set(incoming.map(ActivityScope.id(of:)))

        // A broadcast is persisted before the watcher may report it. Keep recent pending sends
        // through that eventual-consistency window; `createdAt` survives process restarts.
        let toDelete = pruneMissing
            ? existing.filter {
                !$0.isTransfer &&
                    !isRecentPendingSend($0, currentTimestamp: currentTimestamp) &&
                    !incomingIds.contains($0.id)
            }
            : []

        let storedByTxId = Dictionary(existing.map { ($0.txId, $0) }, uniquingKeysWith: { first, _ in first })
        let toUpsert = incoming.map { activity -> Activity in
            guard case var .onchain(onchain) = activity else { return activity }

            if let stored = storedByTxId[onchain.txId] {
                // The watcher only knows what is on chain, so app-owned metadata would otherwise be
                // erased on every snapshot.
                onchain.isTransfer = onchain.isTransfer || stored.isTransfer
                onchain.channelId = onchain.channelId ?? stored.channelId
                onchain.transferTxId = onchain.transferTxId ?? stored.transferTxId
                onchain.contact = onchain.contact ?? stored.contact
            }

            // Re-pairing a wallet that was removed leaves nothing to carry forward — removal deleted
            // its activities — and `TransferService` only re-marks transfers that are still
            // unsettled, so a completed transfer would return from the watcher as a plain send. The
            // funding tx id is still recorded against the Bitkit-side transfer, which removal does
            // not touch, so recover the flag from there.
            if !onchain.isTransfer, let channelId = transferChannelIdsByFundingTxId[onchain.txId] {
                onchain.isTransfer = true
                onchain.channelId = onchain.channelId ?? channelId
            }

            return .onchain(onchain)
        }

        return Plan(toDelete: toDelete, toUpsert: toUpsert)
    }

    private static func isRecentPendingSend(
        _ activity: OnchainActivity,
        currentTimestamp: UInt64
    ) -> Bool {
        guard activity.txType == .sent,
              !activity.confirmed,
              activity.doesExist,
              let createdAt = activity.createdAt
        else { return false }

        let age = currentTimestamp >= createdAt ? currentTimestamp - createdAt : 0
        return age <= pendingSendGracePeriod
    }
}
