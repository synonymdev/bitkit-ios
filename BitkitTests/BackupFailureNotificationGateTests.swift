@testable import Bitkit
import XCTest

final class BackupFailureNotificationGateTests: XCTestCase {
    func testInactiveCheckDoesNotConsumeNotificationCooldown() {
        var gate = BackupFailureNotificationGate()

        XCTAssertFalse(
            gate.shouldNotify(
                at: 1000,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )

        gate.setActive(true, at: 1000)

        XCTAssertTrue(
            gate.shouldNotify(
                at: 1060,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
    }

    func testForegroundGracePeriodAllowsBackupRetryToSettle() {
        var gate = BackupFailureNotificationGate()
        gate.setActive(true, at: 1000)

        XCTAssertFalse(
            gate.shouldNotify(
                at: 1059,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
        XCTAssertTrue(
            gate.shouldNotify(
                at: 1060,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
    }

    func testReturningToBackgroundRestartsForegroundGracePeriod() {
        var gate = BackupFailureNotificationGate()
        gate.setActive(true, at: 1000)
        gate.setActive(false, at: 1010)

        XCTAssertFalse(
            gate.shouldNotify(
                at: 2000,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )

        gate.setActive(true, at: 2000)

        XCTAssertFalse(
            gate.shouldNotify(
                at: 2059,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
    }

    func testNotificationCooldownPreventsRepeatedToasts() {
        var gate = BackupFailureNotificationGate()
        gate.setActive(true, at: 1000)

        XCTAssertTrue(
            gate.shouldNotify(
                at: 1060,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
        XCTAssertFalse(
            gate.shouldNotify(
                at: 1659,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
        XCTAssertTrue(
            gate.shouldNotify(
                at: 1660,
                minimumActiveDuration: 60,
                notificationInterval: 600
            )
        )
    }
}
