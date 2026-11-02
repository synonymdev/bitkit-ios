@testable import Bitkit
import LDKNode
import XCTest

final class LightningServiceTests: XCTestCase {
    func testStopReleasesANodeWhoseStartFailed() {
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.NotRunning(message: "") })
    }

    func testStopReleasesANodeThatShutDownWithoutPersisting() {
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.PersistenceFailed(message: "") })
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
