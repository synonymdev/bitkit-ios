@testable import Bitkit
import XCTest

/// A confirmed event reaches the received sheet only for a recent block outside a migration, so the
/// confirmations a full wallet scan replays for old txs stay silent. #455, parity with
/// `NotifyPaymentReceivedHandler.canShowConfirmedOnly` on Android.
@MainActor
final class ConfirmedOnlyReceiveGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let maxAge = AppViewModel.maxConfirmedOnlyReceiveAge

    private func blockTime(secondsFromNow offset: TimeInterval) -> UInt64 {
        UInt64(now.timeIntervalSince1970 + offset)
    }

    func testRecentConfirmationIsPresented() {
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(confirmationTime: blockTime(secondsFromNow: -30), now: now, isMigrating: false)
        )
    }

    func testConfirmationAtTheWindowEdgeIsPresented() {
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(confirmationTime: blockTime(secondsFromNow: -maxAge), now: now, isMigrating: false)
        )
        XCTAssertTrue(
            AppViewModel.shouldPresentConfirmedOnlyReceive(confirmationTime: blockTime(secondsFromNow: maxAge), now: now, isMigrating: false)
        )
    }

    func testOldConfirmationReplayedByAScanIsSkipped() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(
                confirmationTime: blockTime(secondsFromNow: -maxAge - 1),
                now: now,
                isMigrating: false
            ),
            "a replayed historical confirmation would pop a Received sheet"
        )
    }

    func testBlockTimeFarAheadOfTheDeviceClockIsSkipped() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(confirmationTime: blockTime(secondsFromNow: maxAge + 1), now: now, isMigrating: false)
        )
    }

    func testRecentConfirmationIsSkippedDuringMigration() {
        XCTAssertFalse(
            AppViewModel.shouldPresentConfirmedOnlyReceive(confirmationTime: blockTime(secondsFromNow: -30), now: now, isMigrating: true),
            "the post-migration scan replays confirmations for migrated txs that are not yet marked seen"
        )
    }
}
