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
        confirmed: Bool = true
    ) -> OnchainActivity {
        OnchainActivity(
            walletId: walletId,
            id: id,
            txType: .received,
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
            contact: nil,
            createdAt: nil,
            updatedAt: nil,
            seenAt: nil
        )
    }

    private func upserted(_ plan: HwSnapshotMerge.Plan, id: String) -> OnchainActivity? {
        plan.toUpsert.compactMap { activity -> OnchainActivity? in
            guard case let .onchain(onchain) = activity else { return nil }
            return onchain
        }.first { $0.id == id }
    }

    func testDropsStoredActivityMissingFromSnapshot() {
        let plan = HwSnapshotMerge.plan(
            existing: [onchain(id: "kept"), onchain(id: "reorged")],
            incoming: [.onchain(onchain(id: "kept"))]
        )

        XCTAssertEqual(plan.toDelete.map(\.id), ["reorged"])
        XCTAssertEqual(plan.toUpsert.map(\.activityId), ["kept"])
    }

    func testKeepsTransferMissingFromSnapshot() {
        // A pending Transfer To Spending exists before any watcher poll reports its funding tx.
        let plan = HwSnapshotMerge.plan(
            existing: [onchain(id: "pendingTransfer", isTransfer: true)],
            incoming: []
        )

        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertTrue(plan.toUpsert.isEmpty)
    }

    func testCarriesTransferMetadataForwardOntoIncomingActivity() {
        let stored = onchain(id: "tx1", isTransfer: true, channelId: "channel-1", transferTxId: "transfer-1")
        let plan = HwSnapshotMerge.plan(
            existing: [stored],
            incoming: [.onchain(onchain(id: "tx1"))]
        )

        let merged = upserted(plan, id: "tx1")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "channel-1")
        XCTAssertEqual(merged?.transferTxId, "transfer-1")
    }

    func testIncomingTransferMetadataWinsOverStoredNil() {
        let plan = HwSnapshotMerge.plan(
            existing: [onchain(id: "tx1")],
            incoming: [.onchain(onchain(id: "tx1", isTransfer: true, channelId: "channel-2", transferTxId: "transfer-2"))]
        )

        let merged = upserted(plan, id: "tx1")
        XCTAssertEqual(merged?.isTransfer, true)
        XCTAssertEqual(merged?.channelId, "channel-2")
        XCTAssertEqual(merged?.transferTxId, "transfer-2")
    }

    func testMatchesStoredMetadataByTxIdNotActivityId() {
        // Core can re-key an activity (e.g. a boost) while the txid stays the same.
        let stored = onchain(id: "oldId", txId: "tx1", isTransfer: true, channelId: "channel-1")
        let plan = HwSnapshotMerge.plan(
            existing: [stored],
            incoming: [.onchain(onchain(id: "newId", txId: "tx1"))]
        )

        XCTAssertTrue(plan.toDelete.isEmpty, "A transfer is never deleted, even when re-keyed")
        XCTAssertEqual(upserted(plan, id: "newId")?.channelId, "channel-1")
    }

    func testPassesThroughIncomingActivityWithNoStoredCounterpart() {
        let plan = HwSnapshotMerge.plan(existing: [], incoming: [.onchain(onchain(id: "tx1"))])

        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertEqual(upserted(plan, id: "tx1")?.isTransfer, false)
    }
}
