@testable import Bitkit
import XCTest

final class BackupFailureNotificationGateTests: XCTestCase {
    func testRunningBackupIsNotReportedAsFailed() {
        let status = BackupItemStatus(synced: 0, required: 100, running: true)

        XCTAssertFalse(
            BackupFailureNotificationGate.hasFailedBackup(
                status,
                at: 200,
                failureAge: 50
            )
        )
    }

    func testRecoveredBackupIsNotReportedAsFailed() {
        let status = BackupItemStatus(synced: 100, required: 100, running: false)

        XCTAssertFalse(
            BackupFailureNotificationGate.hasFailedBackup(
                status,
                at: 200,
                failureAge: 50
            )
        )
    }

    func testOutstandingBackupPastThresholdIsReportedAsFailed() {
        let status = BackupItemStatus(synced: 0, required: 100, running: false)

        XCTAssertTrue(
            BackupFailureNotificationGate.hasFailedBackup(
                status,
                at: 151,
                failureAge: 50
            )
        )
    }

    func testInactiveCheckDoesNotConsumeNotificationCooldown() {
        var gate = BackupFailureNotificationGate()

        XCTAssertFalse(
            gate.shouldNotify(
                at: 1000,
                notificationInterval: 600
            )
        )

        gate.setActive(true)

        XCTAssertTrue(
            gate.shouldNotify(
                at: 1000,
                notificationInterval: 600
            )
        )
    }

    func testReturningToForegroundDoesNotResetNotificationEligibility() {
        var gate = BackupFailureNotificationGate()
        gate.setActive(true)

        XCTAssertTrue(
            gate.shouldNotify(
                at: 1000,
                notificationInterval: 600
            )
        )

        gate.setActive(false)
        gate.setActive(true)

        XCTAssertFalse(
            gate.shouldNotify(
                at: 1599,
                notificationInterval: 600
            )
        )
        XCTAssertTrue(
            gate.shouldNotify(
                at: 1600,
                notificationInterval: 600
            )
        )
    }

    func testNotificationCooldownPreventsRepeatedToasts() {
        var gate = BackupFailureNotificationGate()
        gate.setActive(true)

        XCTAssertTrue(
            gate.shouldNotify(
                at: 1000,
                notificationInterval: 600
            )
        )
        XCTAssertFalse(
            gate.shouldNotify(
                at: 1599,
                notificationInterval: 600
            )
        )
        XCTAssertTrue(
            gate.shouldNotify(
                at: 1600,
                notificationInterval: 600
            )
        )
    }
}
