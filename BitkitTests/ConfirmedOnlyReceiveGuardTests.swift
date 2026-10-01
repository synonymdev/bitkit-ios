@testable import Bitkit
import XCTest

/// A confirmed event reaches the received sheet only for a recent block outside a migration, so the
/// confirmations a full wallet scan replays for old txs stay silent. #455, parity with
/// `NotifyPaymentReceivedHandler.canShowConfirmedOnly` on Android.
@MainActor
final class ConfirmedOnlyReceiveGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let maxAge = AppViewModel.maxConfirmedOnlyReceiveAge
    private let height: UInt32 = 900

    private func blockTime(secondsFromNow offset: TimeInterval) -> UInt64 {
        UInt64(now.timeIntervalSince1970 + offset)
    }

    func testRecentConfirmationIsPresented() {
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -30),
                blockHeight: height,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: 0
            )
        )
    }

    func testConfirmationAtTheWindowEdgeIsPresented() {
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -maxAge),
                blockHeight: height,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: 0
            )
        )
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: maxAge),
                blockHeight: height,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: 0
            )
        )
    }

    func testOldConfirmationReplayedByAScanIsSkipped() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -maxAge - 1),
                blockHeight: height,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: 0
            ),
            "a replayed historical confirmation would pop a Received sheet"
        )
    }

    func testBlockTimeFarAheadOfTheDeviceClockIsSkipped() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: maxAge + 1),
                blockHeight: height,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: 0
            )
        )
    }

    func testRecentConfirmationIsSkippedDuringMigration() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -30),
                blockHeight: height,
                now: now,
                isMigrating: true,
                restoreSyncedBlockHeight: 0
            ),
            "the post-migration scan replays confirmations for migrated txs that are not yet marked seen"
        )
    }

    /// #588, Android #1342: a rescan after the hold lifts replays a recent historical confirmation.
    func testConfirmationTheRestoreAlreadyScannedIsSkippedAfterTheHold() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -30),
                blockHeight: height,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: height
            ),
            "a historical receive confirmed within the hour would pop a Received sheet"
        )
    }

    func testConfirmationAboveTheRestoreTipIsPresented() {
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -30),
                blockHeight: height + 1,
                now: now,
                isMigrating: false,
                restoreSyncedBlockHeight: height
            )
        )
    }
}
