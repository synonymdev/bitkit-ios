@testable import Bitkit
import XCTest

@MainActor
final class AppResetTests: XCTestCase {
    func testRemoteCleanupThatIgnoresCancellationDoesNotHoldTheWipe() async {
        let started = ContinuousClock.now

        await AppReset.runRemoteCleanup(timeout: .milliseconds(50)) {
            await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
        }

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testRemoteCleanupThatFinishesInTimeRuns() async {
        var didRun = false

        await AppReset.runRemoteCleanup(timeout: .seconds(5)) {
            didRun = true
        }

        XCTAssertTrue(didRun)
    }

    func testPrivateEndpointRemovalTheWipeStoppedWaitingForRecordsNoPendingCleanup() async {
        snapshotAppDefaults(PublicPaykitService.cleanupPendingKey, PrivatePaykitService.cleanupPendingKey)
        PublicPaykitService.setCleanupPending(false)
        PrivatePaykitService.setContactSharingCleanupPending(false)

        let removal = Task { await PubkyProfileManager.removePrivatePaykitEndpointsForWipe(context: "AppResetTests") }
        removal.cancel()
        await removal.value

        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey))
    }
}
