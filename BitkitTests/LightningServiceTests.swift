@testable import Bitkit
import LDKNode
import XCTest

final class LightningServiceTests: XCTestCase {
    func testStopReleasesANodeWhoseStartFailed() {
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.NotRunning(message: "") })
    }

    func testStopKeepsANodeThatFailedToPersistUntilARetryFindsItStopped() {
        XCTAssertThrowsError(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.PersistenceFailed(message: "") })
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.NotRunning(message: "") })
    }

    func testStopReleasesANodeThatStopped() {
        var didStop = false
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { didStop = true })
        XCTAssertTrue(didStop)
    }

    func testStopKeepsANodeWhoseStopFailedOtherwise() {
        XCTAssertThrowsError(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.ConnectionFailed(message: "") })
    }
}

final class NodeRuntimeMonitorTests: XCTestCase {
    func testFlagsEachDetachingMessageLdkNodeLogsAfterATimedOutStop() {
        for message in [
            "Detaching background tasks after cancellation timed out.",
            "Detaching cancellable background tasks after cancellation timed out.",
            "Detaching event processor after cancellation timed out: deadline has elapsed",
        ] {
            let monitor = NodeRuntimeMonitor()
            monitor.onLog(record(message))
            XCTAssertTrue(monitor.hasDetachedWork, message)
        }
    }

    func testIgnoresAStopThatTimedOutButDidNotDetach() {
        let monitor = NodeRuntimeMonitor()
        monitor.onLog(record("Stopping background tasks timed out."))
        monitor.onLog(record("Stopping event handling timed out: deadline has elapsed"))
        XCTAssertFalse(monitor.hasDetachedWork)
    }

    func testIgnoresDetachingMessagesFromOtherModulesOrLevels() {
        let monitor = NodeRuntimeMonitor()
        monitor.onLog(record("Detaching background tasks after cancellation timed out.", module: "ldk_node::chain"))
        monitor.onLog(record("Detaching background tasks after cancellation timed out.", level: .warn))
        XCTAssertFalse(monitor.hasDetachedWork)
    }

    func testLogWriterForwardsRecordsToTheMonitor() {
        let monitor = NodeRuntimeMonitor()
        let writer = LdkLogWriter(maxLogLevel: .error, onRecord: monitor.onLog)

        writer.log(record: record("Detaching background tasks after cancellation timed out."))

        XCTAssertTrue(monitor.hasDetachedWork)
    }

    private func record(_ args: String, module: String = "ldk_node::runtime", level: LogLevel = .error) -> LogRecord {
        LogRecord(level: level, args: args, modulePath: module, line: 1)
    }
}

final class DetachedRuntimeExitGuardTests: XCTestCase {
    private var exitCount = 0
    private lazy var sut = DetachedRuntimeExitGuard { self.exitCount += 1 }

    /// Regression synonymdev/bitkit-android#1536: dropping the node shuts down its runtime under the detached tasks
    func testExitsBeforeReleaseWhenAStopDetachesWorkInBackground() {
        sut.appEnteredBackground()

        sut.nodeStopped(hasDetachedWork: true)

        XCTAssertEqual(exitCount, 1)
    }

    func testDefersExitToTheNextBackgroundWhenAStopDetachesWorkInForeground() {
        sut.nodeStopped(hasDetachedWork: true)
        XCTAssertEqual(exitCount, 0)

        sut.appEnteredBackground()

        XCTAssertEqual(exitCount, 1)
    }

    func testDefersExitAfterTheAppReturnsToForeground() {
        sut.appEnteredBackground()
        sut.appBecameActive()

        sut.nodeStopped(hasDetachedWork: true)

        XCTAssertEqual(exitCount, 0)
    }

    func testNeverExitsForAStopWithoutDetachedWork() {
        sut.appEnteredBackground()
        sut.nodeStopped(hasDetachedWork: false)
        sut.appBecameActive()
        sut.appEnteredBackground()

        XCTAssertEqual(exitCount, 0)
    }
}
