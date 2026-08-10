@testable import Bitkit
import BitkitCore
import XCTest

final class ActivityTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    let service = CoreService.shared.activity

    override func setUp() async throws {
        try await super.setUp()
        // Initialize the database before each test
        _ = try initDb(basePath: testDbPath)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    override func tearDown() async throws {
        try await super.tearDown()

        // Clean up the test database directory
        let fileManager = FileManager.default
        let dbPath = (testDbPath as NSString).appendingPathComponent("activity.db")

        if fileManager.fileExists(atPath: dbPath) {
            try fileManager.removeItem(atPath: dbPath)
        }
    }

    func testInsertAndRetrieveLightningActivity() async throws {
        let testValue: UInt64 = 123_456_789
        let testFee: UInt64 = 421
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create a lightning activity
        let lightningActivity = Activity.lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "test-lightning-1",
                txType: .sent,
                status: .succeeded,
                value: testValue,
                fee: testFee,
                invoice: "lnbc...",
                message: "Test payment",
                timestamp: timestamp,
                preimage: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        // Insert the activity
        try await service.insert(lightningActivity)

        // Retrieve the activity
        let retrieved = try await service.getActivity(id: "test-lightning-1")
        XCTAssertNotNil(retrieved)

        if case let .lightning(activity) = retrieved {
            XCTAssertEqual(activity.id, "test-lightning-1")
            XCTAssertEqual(activity.value, testValue, "Retrieved value should match inserted value")
            XCTAssertEqual(activity.fee, testFee, "Retrieved fee should match inserted fee")
            XCTAssertEqual(activity.status, .succeeded)
        } else {
            XCTFail("Retrieved activity is not of type lightning")
        }
    }

    func testInsertAndRetrieveOnchainActivity() async throws {
        let testValue: UInt64 = 987_654_321
        let testFee: UInt64 = 1234
        let testFeeRate: UInt64 = 8
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create an onchain activity
        let onchainActivity = Activity.onchain(
            OnchainActivity(
                walletId: WalletScope.default,
                id: "test-onchain-1",
                txType: .received,
                txId: "abc123",
                value: testValue,
                fee: testFee,
                feeRate: testFeeRate,
                address: "bc1...",
                confirmed: true,
                timestamp: timestamp,
                isBoosted: false,
                boostTxIds: [],
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        // Insert the activity
        try await service.insert(onchainActivity)

        // Retrieve the activity
        let retrieved = try await service.getActivity(id: "test-onchain-1")
        XCTAssertNotNil(retrieved)

        if case let .onchain(activity) = retrieved {
            XCTAssertEqual(activity.id, "test-onchain-1")
            XCTAssertEqual(activity.value, testValue, "Retrieved value should match inserted value")
            XCTAssertEqual(activity.fee, testFee, "Retrieved fee should match inserted fee")
            XCTAssertEqual(activity.feeRate, testFeeRate, "Retrieved fee rate should match inserted fee rate")
        } else {
            XCTFail("Retrieved activity is not of type onchain")
        }
    }

    func testActivityTags() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert an activity
        let activity = Activity.lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "test-tags-1",
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment",
                timestamp: timestamp,
                preimage: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        try await service.insert(activity)

        // Add tags
        let tags = ["test", "payment"]
        try await service.appendTags(toActivity: "test-tags-1", tags)

        // Retrieve tags
        let retrievedTags = try await service.tags(forActivity: "test-tags-1")
        XCTAssertEqual(Set(retrievedTags), Set(tags))

        // Remove a tag
        try await service.dropTags(fromActivity: "test-tags-1", ["test"])
        let updatedTags = try await service.tags(forActivity: "test-tags-1")
        XCTAssertEqual(updatedTags, ["payment"])
    }

    func testGetActivitiesByTag() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert multiple activities with tags
        let activities = [
            Activity.lightning(
                LightningActivity(
                    walletId: WalletScope.default,
                    id: "test-tag-filter-1",
                    txType: .sent,
                    status: .succeeded,
                    value: 1000,
                    fee: 1,
                    invoice: "lnbc...",
                    message: "Test payment 1",
                    timestamp: timestamp,
                    preimage: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
            Activity.lightning(
                LightningActivity(
                    walletId: WalletScope.default,
                    id: "test-tag-filter-2",
                    txType: .sent,
                    status: .succeeded,
                    value: 2000,
                    fee: 1,
                    invoice: "lnbc...",
                    message: "Test payment 2",
                    timestamp: timestamp,
                    preimage: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
        ]

        // Insert activities and add tags
        for activity in activities {
            try await service.insert(activity)
            if case let .lightning(lightning) = activity {
                try await service.appendTags(toActivity: lightning.id, ["test-tag"])
            }
        }

        // Add an additional tag to one activity
        try await service.appendTags(toActivity: "test-tag-filter-1", ["special"])

        // Test filtering by tag
        let testTagActivities = try await service.get(tags: ["test-tag"], sortDirection: .desc)
        XCTAssertEqual(testTagActivities.count, 2)

        let specialTagActivities = try await service.get(tags: ["special"])
        XCTAssertEqual(specialTagActivities.count, 1)
    }

    func testGetAllUniqueTags() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create test activities with different tags
        let activities = [
            Activity.lightning(
                LightningActivity(
                    walletId: WalletScope.default,
                    id: "test-unique-tags-1",
                    txType: .sent,
                    status: .succeeded,
                    value: 1000,
                    fee: 1,
                    invoice: "lnbc...",
                    message: "Test payment 1",
                    timestamp: timestamp,
                    preimage: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
            Activity.onchain(
                OnchainActivity(
                    walletId: WalletScope.default,
                    id: "test-unique-tags-2",
                    txType: .received,
                    txId: "abc123",
                    value: 5000,
                    fee: 500,
                    feeRate: 1,
                    address: "bc1...",
                    confirmed: true,
                    timestamp: timestamp,
                    isBoosted: false,
                    boostTxIds: [],
                    isTransfer: false,
                    doesExist: true,
                    confirmTimestamp: nil,
                    channelId: nil,
                    transferTxId: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
        ]

        // Insert activities and add different combinations of tags
        for activity in activities {
            try await service.insert(activity)
        }

        // Add tags to first activity
        try await service.appendTags(toActivity: "test-unique-tags-1", ["payment", "important", "personal"])

        // Add tags to second activity
        try await service.appendTags(toActivity: "test-unique-tags-2", ["payment", "business", "onchain"])

        // Get all unique tags
        let uniqueTags = try await service.allPossibleTags()

        // Verify the results
        XCTAssertEqual(Set(uniqueTags), Set(["payment", "important", "personal", "business", "onchain"]))
        XCTAssertEqual(uniqueTags.count, 5)

        // Add duplicate tags to verify they don't create duplicates in unique tags
        try await service.appendTags(toActivity: "test-unique-tags-1", ["payment", "business"])
        let uniqueTagsAfterDuplicates = try await service.allPossibleTags()
        XCTAssertEqual(Set(uniqueTagsAfterDuplicates), Set(["payment", "important", "personal", "business", "onchain"]))
        XCTAssertEqual(uniqueTagsAfterDuplicates.count, 5)

        // Remove some tags and verify the list updates
        try await service.dropTags(fromActivity: "test-unique-tags-1", ["important", "personal"])
        try await service.dropTags(fromActivity: "test-unique-tags-2", ["onchain"])

        let uniqueTagsAfterRemoval = try await service.allPossibleTags()
        XCTAssertEqual(Set(uniqueTagsAfterRemoval), Set(["payment", "business"]))
        XCTAssertEqual(uniqueTagsAfterRemoval.count, 2)
    }

    func testUpdateActivity() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert an activity
        let initialActivity = Activity.lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "test-update-1",
                txType: .sent,
                status: .pending,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment",
                timestamp: timestamp,
                preimage: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        try await service.insert(initialActivity)

        // Create updated version
        let updatedActivity = Activity.lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "test-update-1",
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Updated test payment",
                timestamp: timestamp,
                preimage: "preimage123",
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        // Update the activity
        try await service.update(id: "test-update-1", activity: updatedActivity)

        // Verify the update
        let retrieved = try await service.getActivity(id: "test-update-1")
        XCTAssertNotNil(retrieved)

        if case let .lightning(activity) = retrieved {
            XCTAssertEqual(activity.status, .succeeded)
            XCTAssertEqual(activity.message, "Updated test payment")
            XCTAssertEqual(activity.preimage, "preimage123")
        } else {
            XCTFail("Retrieved activity is not of type lightning")
        }
    }

    func testSetContactPropagatesToReplacementTransaction() async throws {
        let contactPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let replacedTxId = "test-replaced-txid"
        let replacementTxId = "test-replacement-txid"

        try await service.insert(
            makeOnchainActivity(
                id: replacedTxId,
                txId: replacedTxId,
                doesExist: false,
                contact: nil
            )
        )
        try await service.insert(
            makeOnchainActivity(
                id: replacementTxId,
                txId: replacementTxId,
                boostTxIds: [replacedTxId],
                contact: nil
            )
        )

        try await service.setContact(contactPublicKey, forActivity: replacedTxId)

        guard case let .some(.onchain(replacedActivity)) = try await service.getActivity(id: replacedTxId),
              case let .some(.onchain(replacementActivity)) = try await service.getActivity(id: replacementTxId)
        else {
            return XCTFail("Expected onchain activities")
        }

        XCTAssertEqual(replacedActivity.contact, contactPublicKey)
        XCTAssertEqual(replacementActivity.contact, contactPublicKey)
    }

    func testSetContactFindsOnchainActivityByTxid() async throws {
        let contactPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let activityId = "test-onchain-activity-id"
        let txId = "test-onchain-txid"

        try await service.insert(
            makeOnchainActivity(
                id: activityId,
                txId: txId,
                contact: nil
            )
        )

        try await service.setContact(contactPublicKey, forActivity: txId)

        guard case let .some(.onchain(activity)) = try await service.getActivity(id: activityId) else {
            return XCTFail("Expected onchain activity")
        }

        XCTAssertEqual(activity.contact, contactPublicKey)
    }

    func testGetContactActivitiesFiltersReplacedSentTransaction() async throws {
        let contactPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let replacedTxId = "test-contact-replaced-txid"
        let replacementTxId = "test-contact-replacement-txid"

        try await service.insert(
            makeOnchainActivity(
                id: replacedTxId,
                txId: replacedTxId,
                doesExist: false,
                contact: contactPublicKey
            )
        )
        try await service.insert(
            makeOnchainActivity(
                id: replacementTxId,
                txId: replacementTxId,
                boostTxIds: [replacedTxId],
                contact: contactPublicKey
            )
        )

        let activities = try await service.get(contact: contactPublicKey)

        XCTAssertEqual(activities.count, 1)
        guard case let .some(.onchain(activity)) = activities.first else {
            return XCTFail("Expected replacement onchain activity")
        }
        XCTAssertEqual(activity.txId, replacementTxId)
    }

    /// A contact can be assigned to a hardware activity, so the contact's screen has to show it.
    /// Scoping the query to the default wallet let the assignment succeed and then hid the row.
    func testGetContactActivitiesIncludesHardwareWallets() async throws {
        let contactPublicKey = "pubky4rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let hwWalletId = "trezor:contact-scope"

        try await service.insert(
            makeOnchainActivity(
                id: "contact-scope-default",
                txId: "contact-scope-default-tx",
                contact: contactPublicKey
            )
        )
        try await service.insert(
            makeOnchainActivity(
                id: "contact-scope-hw",
                txId: "contact-scope-hw-tx",
                contact: contactPublicKey,
                walletId: hwWalletId
            )
        )

        let activities = try await service.get(contact: contactPublicKey)

        XCTAssertEqual(
            Set(activities.map(ActivityScope.walletId(of:))),
            [WalletScope.default, hwWalletId],
            "Contact activity must merge the normal wallet with hardware wallets"
        )
    }

    /// Replacement filtering is per wallet: boost chains never cross wallets, so one wallet's boost
    /// ids must not suppress an identically-numbered tx in another.
    func testGetContactActivitiesDoesNotApplyBoostIdsAcrossWallets() async throws {
        let contactPublicKey = "pubky5rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let hwWalletId = "trezor:contact-boost-scope"
        let sharedTxId = "contact-boost-shared-tx"

        // Replaced in the normal wallet, and boosted there — so it is filtered out of that wallet.
        try await service.insert(
            makeOnchainActivity(
                id: "contact-boost-replaced",
                txId: sharedTxId,
                doesExist: false,
                contact: contactPublicKey
            )
        )
        try await service.insert(
            makeOnchainActivity(
                id: "contact-boost-replacement",
                txId: "contact-boost-replacement-tx",
                boostTxIds: [sharedTxId],
                contact: contactPublicKey
            )
        )
        // Same tx id under a hardware wallet, which has no boost chain of its own: must survive.
        try await service.insert(
            makeOnchainActivity(
                id: "contact-boost-hw",
                txId: sharedTxId,
                doesExist: false,
                contact: contactPublicKey,
                walletId: hwWalletId
            )
        )

        let activities = try await service.get(contact: contactPublicKey)
        let hwActivityIds = activities
            .filter { ActivityScope.walletId(of: $0) == hwWalletId }
            .map(ActivityScope.id(of:))

        XCTAssertEqual(hwActivityIds, ["contact-boost-hw"], "The normal wallet's boost ids must not filter a hardware row")
    }

    func testDeleteActivity() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert an activity
        let activity = Activity.lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "test-delete-1",
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment",
                timestamp: timestamp,
                preimage: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        try await service.insert(activity)

        // Verify activity exists
        let activity1 = try await service.getActivity(id: "test-delete-1")
        XCTAssertNotNil(activity1)

        // Delete the activity
        let deleted = try await service.delete(id: "test-delete-1")
        XCTAssertTrue(deleted)

        // Verify activity no longer exists
        let deletedActivity = try await service.getActivity(id: "test-delete-1")
        XCTAssertNil(deletedActivity)
    }

    // MARK: - Hardware wallet snapshots

    private let hwWalletId = "trezor:testwallet"

    private func hwOnchain(
        id: String,
        txId: String? = nil,
        txType: PaymentType = .received,
        walletId: String? = nil,
        isTransfer: Bool = false,
        contact: String? = nil
    ) -> Activity {
        .onchain(OnchainActivity(
            walletId: walletId ?? hwWalletId,
            id: id,
            txType: txType,
            txId: txId ?? id,
            value: 50000,
            fee: 100,
            feeRate: 1,
            address: "bcrt1qhw",
            confirmed: true,
            timestamp: 1_700_000_000,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: isTransfer,
            doesExist: true,
            confirmTimestamp: 1_700_000_000,
            channelId: nil,
            transferTxId: nil,
            contact: contact,
            createdAt: nil,
            updatedAt: nil,
            seenAt: nil
        ))
    }

    private func hwDetails(txId: String) -> BitkitCore.TransactionDetails {
        BitkitCore.TransactionDetails(
            walletId: hwWalletId,
            txId: txId,
            amountSats: 50000,
            inputs: [TxInput(txid: "prev-\(txId)", vout: 0, scriptsig: "", witness: [], sequence: 0)],
            outputs: [TxOutput(scriptpubkey: "", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: "bcrt1qout", value: 50000, n: 0)]
        )
    }

    private func storedHwActivityIds() async throws -> [String] {
        try await service.get(filter: .onchain, walletId: hwWalletId).map(ActivityScope.id(of:)).sorted()
    }

    func testReplaceHwSnapshotPrunesMissingRowsWhenComplete() async throws {
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "keep"), hwOnchain(id: "reorged")],
            transactionDetails: [hwDetails(txId: "keep"), hwDetails(txId: "reorged")],
            pruneMissing: true
        )
        var stored = try await storedHwActivityIds()
        XCTAssertEqual(stored, ["keep", "reorged"])

        // The watcher no longer reports "reorged", and this snapshot covers the whole wallet.
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "keep")],
            transactionDetails: [hwDetails(txId: "keep")],
            pruneMissing: true
        )

        stored = try await storedHwActivityIds()
        XCTAssertEqual(stored, ["keep"])
        let details = try await service.getTransactionDetails(txid: "reorged", walletId: hwWalletId)
        XCTAssertNil(details, "a pruned row's transaction details go with it")
    }

    func testReplaceHwSnapshotKeepsRowsAndTagsWhenNotPruning() async throws {
        // The end-to-end proof for the partial-snapshot bug: core's delete cascades into
        // activity_tags, and hardware tags are excluded from the backup payload, so a partial
        // snapshot that pruned would destroy them irrecoverably.
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "fromWatcherA"), hwOnchain(id: "fromWatcherB")],
            transactionDetails: [],
            pruneMissing: true
        )
        try await service.appendTags(toActivity: "fromWatcherB", ["holiday"], walletId: hwWalletId)

        // Watcher A reports before watcher B has, so the snapshot omits B's row.
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "fromWatcherA")],
            transactionDetails: [],
            pruneMissing: false
        )

        let stored = try await storedHwActivityIds()
        XCTAssertEqual(stored, ["fromWatcherA", "fromWatcherB"], "the silent watcher's row survives")
        let tags = try await service.tags(forActivity: "fromWatcherB", walletId: hwWalletId)
        XCTAssertEqual(tags, ["holiday"], "and so does its tag")
    }

    func testReplaceHwSnapshotPreservesSeenAtAndContactOnUpsert() async throws {
        // The design leans on core's upsert merge semantics: `contact` is COALESCEd, and `seen_at`
        // is only ever written by `mark_activity_as_seen` (never by insert or upsert), so a
        // re-reported row keeps both even though the watcher reports neither.
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "tx1", contact: "pk-contact")],
            transactionDetails: [],
            pruneMissing: true
        )
        await service.markActivityAsSeen(id: "tx1", walletId: hwWalletId, seenAt: 1_699_000_000)

        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "tx1")], // watcher rows carry no contact and no seenAt
            transactionDetails: [],
            pruneMissing: true
        )

        let stored = try await service.getActivity(id: "tx1", walletId: hwWalletId)
        guard case let .onchain(onchain) = stored else {
            return XCTFail("expected the hardware row to still be stored")
        }
        XCTAssertEqual(onchain.contact, "pk-contact")
        XCTAssertEqual(onchain.seenAt, 1_699_000_000, "seen state survives a watcher re-report")
    }

    func testMarkOnchainActivityAsTransferFindsHardwareScopedRow() async throws {
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "hwfunding", txType: .sent)],
            transactionDetails: [],
            pruneMissing: true
        )

        await service.markOnchainActivityAsTransfer(txId: "hwfunding", channelId: "channel-9")

        guard case let .onchain(onchain) = try await service.getActivity(id: "hwfunding", walletId: hwWalletId) else {
            return XCTFail("expected the hardware row to still be stored")
        }
        XCTAssertTrue(onchain.isTransfer)
        XCTAssertEqual(onchain.channelId, "channel-9")
    }

    func testMarkOnchainActivityAsTransferPrefersAlreadyFlaggedDefaultWalletRow() async throws {
        // Same txid in both scopes. The normal wallet's row is already flagged, so it wins — which
        // is also the case the cross-wallet scan short-circuits on.
        try await service.insert(hwOnchain(
            id: "shared", txType: .sent, walletId: WalletScope.default, isTransfer: true
        ))
        try await service.replaceHwSnapshot(
            walletId: hwWalletId,
            activities: [hwOnchain(id: "shared", txType: .sent)],
            transactionDetails: [],
            pruneMissing: true
        )

        await service.markOnchainActivityAsTransfer(txId: "shared", channelId: "channel-main")

        guard case let .onchain(main) = try await service.getActivity(id: "shared", walletId: WalletScope.default),
              case let .onchain(hardware) = try await service.getActivity(id: "shared", walletId: hwWalletId)
        else {
            return XCTFail("expected both scoped rows to be stored")
        }
        XCTAssertEqual(main.channelId, "channel-main")
        XCTAssertNil(hardware.channelId, "the hardware row is untouched")
    }

    func testGetAllActivitiesWithLimit() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create multiple activities
        let activities = [
            Activity.lightning(
                LightningActivity(
                    walletId: WalletScope.default,
                    id: "test-limit-1",
                    txType: .sent,
                    status: .succeeded,
                    value: 1000,
                    fee: 1,
                    invoice: "lnbc...",
                    message: "Test payment 1",
                    timestamp: timestamp,
                    preimage: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
            Activity.onchain(
                OnchainActivity(
                    walletId: WalletScope.default,
                    id: "test-limit-2",
                    txType: .received,
                    txId: "abc123",
                    value: 5000,
                    fee: 500,
                    feeRate: 1,
                    address: "bc1...",
                    confirmed: true,
                    timestamp: timestamp,
                    isBoosted: false,
                    boostTxIds: [],
                    isTransfer: false,
                    doesExist: true,
                    confirmTimestamp: nil,
                    channelId: nil,
                    transferTxId: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
            Activity.lightning(
                LightningActivity(
                    walletId: WalletScope.default,
                    id: "test-limit-3",
                    txType: .received,
                    status: .succeeded,
                    value: 2000,
                    fee: 1,
                    invoice: "lnbc...",
                    message: "Test payment 3",
                    timestamp: timestamp,
                    preimage: nil,
                    contact: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    seenAt: nil
                )
            ),
        ]

        // Insert all activities
        for activity in activities {
            try await service.insert(activity)
        }

        // Test with limit
        let limitedActivities = try await service.get(filter: .all, limit: 2)
        XCTAssertEqual(limitedActivities.count, 2)

        // Test without limit
        let allActivities = try await service.get(filter: .all)
        XCTAssertEqual(allActivities.count, 3)
    }

    /// Regression for a crash on the boostTxIds cache.
    ///
    /// `getTxIdsInBoostTxIds` reads that cache from whichever executor calls it, while
    /// `insert`/`upsert` mutate it from the core queue. While it was an unsynchronized
    /// `[String: Set<String>]`, a lookup racing a keyed write tore the dictionary and segfaulted in
    /// `Dictionary._Variant.lookup`. Reading many cold wallet ids concurrently is what forces the
    /// storage to grow and rehash, which is the window that crashed; the writers then mutate the
    /// same wallets the readers are warming.
    ///
    /// A hang here means the lock re-entered itself: fulfillment is driven by the main runloop, so
    /// a deadlock on the cooperative pool fails this test rather than wedging the whole suite.
    func testConcurrentBoostCacheAccessIsSafe() async throws {
        let boostedTxId = "concurrency-boosted-tx"
        let seededWalletIds = (0 ..< 8).map { "trezor:concurrency-seeded-\($0)" }
        let coldWalletIds = (0 ..< 64).map { "trezor:concurrency-cold-\($0)" }

        // Upsert rather than insert: a run aborted by a sanitizer report skips `tearDown`, so the
        // shared temp database can still hold these rows.
        for (index, walletId) in seededWalletIds.enumerated() {
            try await service.upsert(
                makeScopedOnchainActivity(
                    walletId: walletId,
                    id: "concurrency-parent-\(index)",
                    txId: "concurrency-parent-tx-\(index)",
                    boostTxIds: [boostedTxId]
                )
            )
        }

        let service = service
        let finished = expectation(description: "concurrent boost cache access finished")

        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for walletId in coldWalletIds + seededWalletIds {
                    for _ in 0 ..< 4 {
                        group.addTask { _ = await service.getTxIdsInBoostTxIds(walletId: walletId) }
                    }
                }

                // Writers reach `updateBoostTxIdsCache` on the core queue, which only merges into a
                // wallet the readers above have already warmed — so the two interleave by design.
                for (index, walletId) in seededWalletIds.enumerated() {
                    group.addTask {
                        try? await service.upsert(
                            makeScopedOnchainActivity(
                                walletId: walletId,
                                id: "concurrency-parent-\(index)",
                                txId: "concurrency-parent-tx-\(index)",
                                boostTxIds: [boostedTxId, "concurrency-extra-tx-\(index)"]
                            )
                        )
                    }
                }
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 60)

        for walletId in seededWalletIds {
            let txIds = await service.getTxIdsInBoostTxIds(walletId: walletId)
            XCTAssertTrue(
                txIds.contains(boostedTxId),
                "boostTxIds cache lost '\(boostedTxId)' for '\(walletId)' under concurrent access"
            )
        }

        // A wallet that only ever saw cold reads must stay empty rather than picking up another
        // wallet's ids through a torn write.
        for walletId in coldWalletIds {
            let txIds = await service.getTxIdsInBoostTxIds(walletId: walletId)
            XCTAssertTrue(txIds.isEmpty, "boostTxIds cache leaked ids into unrelated wallet '\(walletId)'")
        }
    }

    private func makeOnchainActivity(
        id: String,
        txId: String,
        boostTxIds: [String] = [],
        doesExist: Bool = true,
        contact: String?,
        walletId: String = WalletScope.default
    ) -> Activity {
        let timestamp = UInt64(Date().timeIntervalSince1970)
        return Activity.onchain(
            OnchainActivity(
                walletId: walletId,
                id: id,
                txType: .sent,
                txId: txId,
                value: 1000,
                fee: 10,
                feeRate: 1,
                address: "bcrt1...",
                confirmed: false,
                timestamp: timestamp,
                isBoosted: !boostTxIds.isEmpty,
                boostTxIds: boostTxIds,
                isTransfer: false,
                doesExist: doesExist,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                contact: contact,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )
    }
}

/// Free function rather than a method so `testConcurrentBoostCacheAccessIsSafe`'s detached writers
/// can build activities without capturing the test case.
private func makeScopedOnchainActivity(
    walletId: String,
    id: String,
    txId: String,
    boostTxIds: [String]
) -> Activity {
    .onchain(
        OnchainActivity(
            walletId: walletId,
            id: id,
            txType: .sent,
            txId: txId,
            value: 1000,
            fee: 10,
            feeRate: 1,
            address: "bcrt1...",
            confirmed: false,
            timestamp: UInt64(Date().timeIntervalSince1970),
            isBoosted: !boostTxIds.isEmpty,
            boostTxIds: boostTxIds,
            isTransfer: false,
            doesExist: true,
            confirmTimestamp: nil,
            channelId: nil,
            transferTxId: nil,
            contact: nil,
            createdAt: nil,
            updatedAt: nil,
            seenAt: nil
        )
    )
}
