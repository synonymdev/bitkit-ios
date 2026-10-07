@testable import Bitkit
import XCTest

@MainActor
final class PaykitPaymentActivityTests: XCTestCase {
    func testProofInvalidationsCoalesceUntilForegroundAndPaymentIdle() async throws {
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
        let session = try XCTUnwrap(profile.currentSession)
        var state = PaykitPaymentProofRefreshState()
        let activity = PaykitPaymentActivity()
        let payment = activity.begin()
        for _ in 0 ..< 3 {
            state.invalidate(session: session)
            XCTAssertNil(state.request(session: session, isActive: false))
        }
        let request = try XCTUnwrap(state.request(session: session, isActive: true))
        var refreshes = 0
        let work = Task {
            try await activity.waitUntilIdle()
            refreshes += 1
            state.complete(request)
        }
        await Task.yield()
        XCTAssertEqual(refreshes, 0)
        activity.end(payment)
        try await work.value
        XCTAssertEqual(refreshes, 1)
        XCTAssertNil(state.request(session: session, isActive: true))
    }

    func testProofRefreshCompletionPreservesNewInvalidationsAndDropsOldSessions() throws {
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
        let session = try XCTUnwrap(profile.currentSession)
        var state = PaykitPaymentProofRefreshState()
        state.invalidate(session: session)
        let first = try XCTUnwrap(state.request(session: session, isActive: true))
        state.invalidate(session: session)
        state.complete(first)
        XCTAssertNotNil(state.request(session: session, isActive: true))

        profile.publicKey = "pubky\(String(repeating: "y", count: 52))"
        XCTAssertNil(state.request(session: profile.currentSession, isActive: true))
        state.discard(unlessSession: profile.currentSession)
        XCTAssertNil(state.request(session: session, isActive: true))
        state.invalidate(session: profile.currentSession)
        state.discard(unlessSession: nil)
        XCTAssertNil(state.request(session: profile.currentSession, isActive: true))
    }

    func testDeferredAcceptanceCoalescesUntilEveryPaymentEnds() async {
        let activity = PaykitPaymentActivity()
        let first = activity.begin()
        let second = activity.begin()
        var refreshes: [Int] = []
        let key = PaykitPaymentActivity.DeferredWork.acceptance(identity: "payer", counterparty: "payee")
        activity.runWhenIdle(key) { refreshes.append(1) }
        let refresh = activity.runWhenIdle(key) { refreshes.append(2) }
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
        let pending = activity.runWhenIdle(.acceptance(identity: "payer", counterparty: "payee")) { didRun = true }
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
