@testable import Bitkit
import XCTest

@MainActor
final class HomePullRefreshFeedbackTests: XCTestCase {
    func testStopsWaitingWhenRefreshCompletes() async {
        var didRefresh = false

        await HomePullRefreshFeedback.wait(
            refresh: {
                didRefresh = true
            },
            sleep: { _ in
                try await Task.sleep(for: .seconds(60))
            }
        )

        XCTAssertTrue(didRefresh)
    }

    func testTimeoutStopsWaitingWhileRefreshContinues() async {
        let refreshGate = AsyncStream<Void>.makeStream()
        let refreshFinished = expectation(description: "Refresh continued after feedback timeout")
        var didFinishRefresh = false

        await HomePullRefreshFeedback.wait(
            refresh: {
                for await _ in refreshGate.stream {}
                didFinishRefresh = true
                refreshFinished.fulfill()
            },
            sleep: { _ in }
        )

        XCTAssertFalse(didFinishRefresh)
        refreshGate.continuation.finish()
        await fulfillment(of: [refreshFinished], timeout: 1)
        XCTAssertTrue(didFinishRefresh)
    }
}
