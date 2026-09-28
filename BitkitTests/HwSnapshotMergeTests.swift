@testable import Bitkit
import BitkitCore
import XCTest

/// Covers the reconciliation rules `ActivityService.replaceHwSnapshot` applies when a hardware
/// watcher snapshot replaces what bitkit-core already stores for that wallet.
final class HwSnapshotMergeTests: XCTestCase {
    private let walletId = "trezor:abc"

    private func onchain(
        id: String,
        txId: String? = nil,
        isTransfer: Bool = false,
        channelId: String? = nil,
        transferTxId: String? = nil,
        contact: String? = nil,
        confirmed: Bool = true,
        txType: PaymentType = .received,
        createdAt: UInt64? = nil
    ) -> OnchainActivity {
        OnchainActivity(
            walletId: walletId,
            id: id,
            txType: txType,
            txId: txId ?? id,
            value: 1000,
            fee: 100,
            feeRate: 1,
            address: "bcrt1qexample",
            confirmed: confirmed,
            timestamp: 1,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: isTransfer,
            doesExist: true,
            confirmTimestamp: nil,
            channelId: channelId,
            transferTxId: transferTxId,
            contact: contact,
            createdAt: createdAt,
            updatedAt: nil,
            seenAt: nil
        )
    }

    /// Pruning is the normal case, so it is the default here; the cases that exercise a partial
    /// snapshot pass `pruneMissing: false` explicitly. The production signature deliberately has no
    /// default — see `HwSnapshotMerge.plan`.
    private func makePlan(
        existing: [OnchainActivity],
        incoming: [Activity],
        pruneMissing: Bool = true,
        currentTimestamp: UInt64 = 100_000,
        transferChannelIdsByFundingTxId: [String: String] = [:]
    ) -> HwSnapshotMerge.Plan {
        HwSnapshotMerge.plan(
            existing: existing,
            incoming: incoming,
            pruneMissing: pruneMissing,
            currentTimestamp: currentTimestamp,
            transferChannelIdsByFundingTxId: transferChannelIdsByFundingTxId
        )
    }

    private func upserted(_ plan: HwSnapshotMerge.Plan, id: String) -> OnchainActivity? {
        plan.toUpsert.compactMap { activity -> OnchainActivity? in
            guard case let .onchain(onchain) = activity else { return nil }
            return onchain
        }.first { $0.id == id }
    }

    func testDropsStoredActivityMissingFromSnapshot() {
        let plan = makePlan(
            existing: [onchain(id: "kept"), onchain(id: "reorged")],
            incoming: [.onchain(onchain(id: "kept"))]
        )

        XCTAssertEqual(plan.toDelete.map(\.id), ["reorged"])
        XCTAssertEqual(plan.toUpsert.map(\.activityId), ["kept"])
    }

    func testKeepsTransferMissingFromSnapshot() {
        // A pending Transfer To Spending exists before any watcher poll reports its funding tx.
        let plan = makePlan(
            existing: [onchain(id: "pendingTransfer", isTransfer: true)],
            incoming: []
        )

        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertTrue(plan.toUpsert.isEmpty)
    }

    func testKeepsLocallyCreatedPendingSendUntilWatcherReportsIt() {
        let plan = makePlan(
            existing: [onchain(id: "pendingSend", confirmed: false, txType: .sent, createdAt: 100_000)],
            incoming: []
        )

        XCTAssertTrue(plan.toDelete.isEmpty)
    }

    func testDeletesExpiredPendingSendMissingFromCompleteSnapshot() {
        let plan = makePlan(
            existing: [onchain(id: "pendingSend", confirmed: false, txType: .sent, createdAt: 1)],
            incoming: []
        )

        XCTAssertEqual(plan.toDelete.map(\.id), ["pendingSend"])
    }

    func testCarriesTransferMetadataForwardOntoIncomingActivity() {
        let stored = onchain(id: "tx1", isTransfer: true, channelId: "channel-1", transferTxId: "transfer-1")
        let plan = makePlan(
            existing: [stored],
            incoming: [.onchain(onchain(id: "tx1"))]
        )

        let merged = upserted(plan, id: "tx1")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "channel-1")
        XCTAssertEqual(merged?.transferTxId, "transfer-1")
    }

    func testIncomingTransferMetadataWinsOverStoredNil() {
        let plan = makePlan(
            existing: [onchain(id: "tx1")],
            incoming: [.onchain(onchain(id: "tx1", isTransfer: true, channelId: "channel-2", transferTxId: "transfer-2"))]
        )

        let merged = upserted(plan, id: "tx1")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "channel-2")
        XCTAssertEqual(merged?.transferTxId, "transfer-2")
    }

    func testCarriesStoredContactForwardOntoWatcherActivity() {
        let plan = makePlan(
            existing: [onchain(id: "tx1", contact: "pubky-contact")],
            incoming: [.onchain(onchain(id: "tx1"))]
        )

        XCTAssertEqual(upserted(plan, id: "tx1")?.contact, "pubky-contact")
    }

    func testMatchesStoredMetadataByTxIdNotActivityId() {
        // Core can re-key an activity (e.g. a boost) while the txid stays the same.
        let stored = onchain(id: "oldId", txId: "tx1", isTransfer: true, channelId: "channel-1")
        let plan = makePlan(
            existing: [stored],
            incoming: [.onchain(onchain(id: "newId", txId: "tx1"))]
        )

        XCTAssertTrue(plan.toDelete.isEmpty, "A transfer is never deleted, even when re-keyed")
        XCTAssertEqual(upserted(plan, id: "newId")?.channelId, "channel-1")
    }

    func testPassesThroughIncomingActivityWithNoStoredCounterpart() {
        let plan = makePlan(existing: [], incoming: [.onchain(onchain(id: "tx1"))])

        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertEqual(upserted(plan, id: "tx1")?.isTransfer, false)
    }

    // MARK: - Partial snapshots

    func testKeepsStoredActivityMissingFromPartialSnapshot() {
        // Only one of the wallet's address-type watchers has reported, so the snapshot cannot
        // mention the rows the silent one owns. Deleting them would take their tags with them.
        let plan = makePlan(
            existing: [onchain(id: "kept"), onchain(id: "ownedByOtherWatcher")],
            incoming: [.onchain(onchain(id: "kept"))],
            pruneMissing: false
        )

        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertEqual(plan.toUpsert.map(\.activityId), ["kept"])
    }

    func testStillMergesTransferMetadataWhenNotPruning() {
        // The flag gates deletion only — upserting is always safe, so a partial snapshot must still
        // carry locally written transfer metadata forward.
        let stored = onchain(id: "tx1", isTransfer: true, channelId: "channel-1", transferTxId: "transfer-1")
        let plan = makePlan(
            existing: [stored],
            incoming: [.onchain(onchain(id: "tx1"))],
            pruneMissing: false
        )

        let merged = upserted(plan, id: "tx1")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "channel-1")
        XCTAssertEqual(merged?.transferTxId, "transfer-1")
    }

    func testEmptyIncomingPrunesEverythingWhenComplete() {
        // bitkit-core's watcher only emits `transactionsChanged` after a successful sync (a failure
        // emits `.error`), so a complete-but-empty snapshot genuinely means "no transactions" and
        // must prune. Pinned so nobody adds an empty-snapshot guard later.
        let plan = makePlan(existing: [onchain(id: "tx1"), onchain(id: "tx2")], incoming: [])

        XCTAssertEqual(plan.toDelete.map(\.id).sorted(), ["tx1", "tx2"])
        XCTAssertTrue(plan.toUpsert.isEmpty)
    }

    // MARK: - Transfer recovery after remove + re-add

    /// The re-pair case: removal deleted the wallet's activities, so the watcher's rediscovered
    /// funding tx arrives with no stored row to carry `isTransfer` forward from. Without recovery it
    /// would display as a plain send.
    func testTransferRecoveredFromKnownFundingTxWhenNoStoredRowRemains() {
        let plan = makePlan(
            existing: [],
            incoming: [.onchain(onchain(id: "fundingTx"))],
            transferChannelIdsByFundingTxId: ["fundingTx": "channel-1"]
        )

        let recovered = upserted(plan, id: "fundingTx")
        XCTAssertEqual(recovered?.isTransfer, true)
        XCTAssertEqual(recovered?.channelId, "channel-1")
    }

    func testUnrelatedTransactionIsNotMarkedAsTransfer() {
        let plan = makePlan(
            existing: [],
            incoming: [.onchain(onchain(id: "someOtherTx"))],
            transferChannelIdsByFundingTxId: ["fundingTx": "channel-1"]
        )

        let untouched = upserted(plan, id: "someOtherTx")
        XCTAssertEqual(untouched?.isTransfer, false)
        XCTAssertNil(untouched?.channelId)
    }

    /// Recovery must not overwrite metadata the app already wrote — the stored row wins, so a
    /// transfer whose channel was since re-negotiated keeps the channel id it was tagged with.
    func testStoredChannelIdSurvivesRecovery() {
        let plan = makePlan(
            existing: [onchain(id: "fundingTx", isTransfer: true, channelId: "stored-channel")],
            incoming: [.onchain(onchain(id: "fundingTx"))],
            transferChannelIdsByFundingTxId: ["fundingTx": "channel-1"]
        )

        let merged = upserted(plan, id: "fundingTx")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "stored-channel")
    }

    /// A stored row that lost its channel id still gets one back from the transfer record.
    func testRecoveryFillsMissingChannelIdOnStoredTransfer() {
        let plan = makePlan(
            existing: [onchain(id: "fundingTx", isTransfer: false, channelId: nil)],
            incoming: [.onchain(onchain(id: "fundingTx"))],
            transferChannelIdsByFundingTxId: ["fundingTx": "channel-1"]
        )

        let merged = upserted(plan, id: "fundingTx")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "channel-1")
    }

    /// Recovery is keyed on the transaction id, not the activity id, so a re-paired wallet that
    /// rebuilt its rows under different activity ids still resolves.
    func testRecoveryMatchesOnTransactionIdNotActivityId() {
        let plan = makePlan(
            existing: [],
            incoming: [.onchain(onchain(id: "rebuilt-activity-id", txId: "fundingTx"))],
            transferChannelIdsByFundingTxId: ["fundingTx": "channel-1"]
        )

        let recovered = upserted(plan, id: "rebuilt-activity-id")
        XCTAssertEqual(recovered?.isTransfer, true)
        XCTAssertEqual(recovered?.channelId, "channel-1")
    }

    /// Passing no transfer records must leave the existing merge rules exactly as they were.
    func testNoKnownTransfersLeavesActivitiesUnchanged() {
        let plan = makePlan(existing: [], incoming: [.onchain(onchain(id: "fundingTx"))])

        let untouched = upserted(plan, id: "fundingTx")
        XCTAssertEqual(untouched?.isTransfer, false)
        XCTAssertNil(untouched?.channelId)
    }
}
