@testable import Bitkit
import XCTest

@MainActor
final class PaykitPaymentActivityTests: XCTestCase {
    func testDeferredProofRefreshCoalescesUntilEveryPaymentEnds() async {
        let activity = PaykitPaymentActivity()
        let first = activity.begin()
        let second = activity.begin()
        var refreshes: [Int] = []
        activity.runWhenIdle(.proofRefresh) { refreshes.append(1) }
        let refresh = activity.runWhenIdle(.proofRefresh) { refreshes.append(2) }
        await Task.yield()
        XCTAssertTrue(refreshes.isEmpty)

        activity.end(first)
        await Task.yield()
        XCTAssertTrue(activity.isActive)
        XCTAssertTrue(refreshes.isEmpty)

        activity.end(second)
        await refresh.value
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(refreshes, [2])
    }

    func testCancelledIdleWaitDoesNotLoseLaterWork() async throws {
        let activity = PaykitPaymentActivity()
        let payment = activity.begin()
        let wait = Task { try await activity.waitUntilIdle() }
        await Task.yield()
        wait.cancel()
        do {
            try await wait.value
            XCTFail("Cancelled work must not run")
        } catch is CancellationError {}

        var didRun = false
        let pending = activity.runWhenIdle(.proofRefresh) { didRun = true }
        activity.end(payment)
        await pending.value
        XCTAssertTrue(didRun)
    }

    func testAnotherPaymentStartingBeforeWaiterResumesKeepsWorkDeferred() async throws {
        let activity = PaykitPaymentActivity()
        let first = activity.begin()
        var didRun = false
        let work = Task {
            try await activity.waitUntilIdle()
            didRun = true
        }
        await Task.yield()
        activity.end(first)
        let second = activity.begin()
        await Task.yield()
        XCTAssertFalse(didRun)

        activity.end(second)
        try await work.value
        XCTAssertTrue(didRun)
    }
}
