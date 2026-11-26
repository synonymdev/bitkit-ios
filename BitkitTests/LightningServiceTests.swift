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

    func testAStartFailingBecauseTheNodeRunsIsRecognizedThroughTheQueueWrapper() {
        let alreadyRunning = NodeError.AlreadyRunning(message: "")
        XCTAssertTrue(Bitkit.LightningService.isAlreadyRunning(alreadyRunning))
        XCTAssertTrue(Bitkit.LightningService.isAlreadyRunning(Bitkit.AppError(error: alreadyRunning)))
        XCTAssertFalse(Bitkit.LightningService.isAlreadyRunning(Bitkit.AppError(error: NodeError.ConnectionFailed(message: ""))))
    }

    func testWaitForEndReturnsOnceTheTaskEnds() async {
        let task = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(50)) }
        let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .seconds(10))
        XCTAssertTrue(ended)
    }

    func testStopWithoutANodeLeavesTheLightningLockToItsHolder() async throws {
        try XCTSkipIf(Bitkit.LightningService.shared.onchainDispatchNode != nil, "a node is configured in the test host")
        try await StateLocker.lock(.lightning, wait: 1)
        defer { try? StateLocker.unlock(.lightning) }
        try await Bitkit.LightningService.shared.stop()
        XCTAssertTrue(StateLocker.isLocked(.lightning))
    }

    func testWaitForEndNeverReportsAnEndedTaskAsTimedOut() async {
        for _ in 0 ..< 200 {
            let task = Task {}
            let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .seconds(10))
            XCTAssertTrue(ended)
        }
    }

    func testWaitForEndGivesUpOnATaskThatDoesNotEnd() async {
        let release = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in release.stream {}
        }
        let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .milliseconds(50))
        XCTAssertFalse(ended)
        release.continuation.finish()
        await task.value
    }
}
