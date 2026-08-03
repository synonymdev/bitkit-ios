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
/// `ActivityService.replaceHwSnapshot` applies the plan. Adapts bitkit-android's `mergeHwSnapshot`.
enum HwSnapshotMerge {
    struct Plan {
        let toDelete: [OnchainActivity]
        let toUpsert: [Activity]
    }

    /// - Parameter pruneMissing: whether stored rows absent from `incoming` may be deleted. False
    ///   when the caller could only merge some of the wallet's watchers — a partial snapshot cannot
    ///   mention the rows owned by a watcher that has not reported yet, and core's
    ///   `delete_activity_by_id` cascades into `activity_tags`, so pruning one destroys user tags
    ///   that are no longer carried in the backup payload. Upserting is always safe.
    static func plan(existing: [OnchainActivity], incoming: [Activity], pruneMissing: Bool) -> Plan {
        let incomingIds = Set(incoming.map(ActivityScope.id(of:)))

        // Transfers are never dropped: the pending Transfer To Spending row is written when the
        // funding tx is broadcast, before any watcher poll can report it, so a snapshot that does
        // not mention it yet must not delete it.
        let toDelete = pruneMissing
            ? existing.filter { !$0.isTransfer && !incomingIds.contains($0.id) }
            : []

        let storedByTxId = Dictionary(existing.map { ($0.txId, $0) }, uniquingKeysWith: { first, _ in first })
        let toUpsert = incoming.map { activity -> Activity in
            guard case var .onchain(onchain) = activity, let stored = storedByTxId[onchain.txId] else {
                return activity
            }

            // The watcher only knows what is on chain, so transfer metadata the app wrote locally
            // would otherwise be erased on every snapshot.
            onchain.isTransfer = onchain.isTransfer || stored.isTransfer
            onchain.channelId = onchain.channelId ?? stored.channelId
            onchain.transferTxId = onchain.transferTxId ?? stored.transferTxId
            return .onchain(onchain)
        }

        return Plan(toDelete: toDelete, toUpsert: toUpsert)
    }
}
