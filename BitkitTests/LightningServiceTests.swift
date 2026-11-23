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

    func testWaitForEndReturnsOnceTheTaskEnds() async {
        let task = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(50)) }
        let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .seconds(10))
        XCTAssertTrue(ended)
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
