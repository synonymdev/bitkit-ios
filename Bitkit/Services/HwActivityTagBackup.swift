import BitkitCore

/// Shapes tags on watch-only hardware activities as `PreActivityMetadata` so they reach the
/// METADATA backup.
///
/// Hardware activities themselves stay out of the ACTIVITY backup — the device watcher rebuilds
/// them on every reconnect — so restoring their tags as `ActivityTags` would break core's
/// `FOREIGN KEY (wallet_id, activity_id) REFERENCES activities(wallet_id, id)`. Because the
/// activity restore upserts activities, tags and closed channels together, one orphan tag takes
/// the whole category down with it.
///
/// `pre_activity_metadata` has no such foreign key, is already backed up across every wallet
/// scope, and core re-attaches a record as soon as the matching activity is written — including
/// through the upsert path `replaceHwSnapshot` uses, which is what makes this work without any
/// deferred replay in the app. Received rows are matched on `address`, sent rows on `paymentId`.
///
/// Pure and free of the core FFI so the rules can be unit tested; `ActivityService` supplies the
/// stored rows. Adapts bitkit-android's `OnchainActivity.toPreActivityMetadata`.
enum HwActivityTagBackup {
    /// Activity timestamps are epoch seconds, pre-activity metadata stores epoch millis.
    private static let secondsToMillis: UInt64 = 1000

    static func preActivityMetadata(activities: [OnchainActivity], tags: [ActivityTags]) -> [PreActivityMetadata] {
        let hardwareTags = tags.filter { $0.walletId != WalletScope.default && !$0.tags.isEmpty }
        guard !hardwareTags.isEmpty else { return [] }

        // Activity ids are unique only within a wallet scope, so two paired devices that saw the
        // same transaction would cross-attach each other's tags if this keyed on the id alone.
        let tagsByActivity = Dictionary(
            hardwareTags.map { (ActivityKey(walletId: $0.walletId, activityId: $0.activityId), $0.tags) },
            uniquingKeysWith: { first, _ in first }
        )

        return activities.compactMap { activity in
            let key = ActivityKey(walletId: activity.walletId, activityId: activity.id)
            guard let tags = tagsByActivity[key] else { return nil }
            return preActivityMetadata(for: activity, tags: tags)
        }
    }

    static func preActivityMetadata(for activity: OnchainActivity, tags: [String]) -> PreActivityMetadata {
        let isReceive = activity.txType == .received
        return PreActivityMetadata(
            walletId: activity.walletId,
            paymentId: isReceive ? activity.id : activity.txId,
            tags: tags,
            paymentHash: nil,
            txId: activity.txId,
            address: isReceive ? activity.address : nil,
            isReceive: isReceive,
            // Core copies `feeRate`, `isTransfer` and `channelId` onto the activity it attaches to,
            // but only when they are set, so a tag-only record must leave them neutral or
            // re-attaching would overwrite what the watcher reported.
            feeRate: 0,
            isTransfer: false,
            channelId: nil,
            createdAt: activity.timestamp * secondsToMillis
        )
    }

    /// Core's `pre_activity_metadata` is `PRIMARY KEY (wallet_id, payment_id)`, so the envelope must
    /// not carry two records for one key — the second would silently replace the first on restore.
    /// First wins, so callers order the list by which source should take precedence.
    static func deduplicated(_ records: [PreActivityMetadata]) -> [PreActivityMetadata] {
        var seen = Set<MetadataKey>()
        return records.filter { seen.insert(MetadataKey(walletId: $0.walletId, paymentId: $0.paymentId)).inserted }
    }

    private struct ActivityKey: Hashable {
        let walletId: String
        let activityId: String
    }

    private struct MetadataKey: Hashable {
        let walletId: String
        let paymentId: String
    }
}
