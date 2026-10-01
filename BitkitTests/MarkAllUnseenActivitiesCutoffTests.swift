@testable import Bitkit
import BitkitCore
import XCTest

/// Regression cover for #588: the post-restore sweep marks the replayed historical activity as seen,
/// and must leave alone a payment that genuinely arrives while the restore is still running.
///
/// Without the cutoff, such a payment was suppressed by `pendingRestoreActivitySeen` on arrival and
/// then marked seen by the sweep, so it never notified the user at all.
final class MarkAllUnseenActivitiesCutoffTests: XCTestCase {
    private let testDbPath = NSTemporaryDirectory()
    private let service = CoreService.shared.activity

    private let restoreStartedAt: UInt64 = 1_700_000_000

    override func setUp() async throws {
        try await super.setUp()
        _ = try initDb(basePath: testDbPath)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    override func tearDown() async throws {
        try await super.tearDown()

        let fileManager = FileManager.default
        let dbPath = (testDbPath as NSString).appendingPathComponent("activity.db")
        if fileManager.fileExists(atPath: dbPath) {
            try fileManager.removeItem(atPath: dbPath)
        }
    }

    func testSweepMarksReplayedHistoryButSparesNewerActivity() async throws {
        let replayed = "restore-replayed-history"
        let arrivedDuringRestore = "arrived-mid-restore"

        try await service.insert(onchainActivity(id: replayed, txId: "old", timestamp: restoreStartedAt - 3600))
        try await service.insert(
            onchainActivity(id: arrivedDuringRestore, txId: "new", timestamp: restoreStartedAt + 30)
        )

        let completed = await service.markAllUnseenActivitiesAsSeen(startedBefore: restoreStartedAt)

        let replayedSeenAt = try await seenAt(of: replayed)
        let newerSeenAt = try await seenAt(of: arrivedDuringRestore)

        XCTAssertTrue(completed)
        XCTAssertNotNil(replayedSeenAt, "replayed history should be marked seen by the sweep")
        XCTAssertNil(
            newerSeenAt,
            "a payment that arrived during the restore must stay unseen, or it never notifies"
        )
    }

    func testSweepWithoutACutoffStillMarksEverything() async throws {
        let id = "no-cutoff"
        try await service.insert(onchainActivity(id: id, txId: "any", timestamp: restoreStartedAt + 30))

        let completed = await service.markAllUnseenActivitiesAsSeen()

        let markedSeenAt = try await seenAt(of: id)

        XCTAssertTrue(completed)
        XCTAssertNotNil(markedSeenAt, "the post-migration caller passes no cutoff and expects a full sweep")
    }

    // MARK: - Helpers

    private func seenAt(of id: String) async throws -> UInt64? {
        guard case let .onchain(activity) = try await service.getActivity(id: id) else {
            XCTFail("activity \(id) was not stored as on-chain")
            return nil
        }
        return activity.seenAt
    }

    private func onchainActivity(id: String, txId: String, timestamp: UInt64) -> Activity {
        .onchain(
            OnchainActivity(
                walletId: WalletScope.default,
                id: id,
                txType: .received,
                txId: txId,
                value: 10000,
                fee: 100,
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
        )
    }
}
