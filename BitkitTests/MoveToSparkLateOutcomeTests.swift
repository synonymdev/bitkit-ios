@testable import Bitkit
import LDKNode
import XCTest

final class MoveToSparkLateOutcomeTests: XCTestCase {
    func testLateSuccessOfTheInFlightMoveShowsItMovedWithItsFee() {
        let state = MoveToSparkState.inFlight(amountSats: 40000)
        XCTAssertTrue(MoveToSparkManager.showsInFlightMove(state, generation: 3, moveGeneration: 3))

        let emptied = ChannelDetails.mock(outboundCapacityMsat: 500_000)
        let done = MoveToSparkManager.doneState(amountSats: 40000, feeSats: 12, channels: [emptied])
        XCTAssertEqual(done, .done(amountSats: 40000, feeSats: 12, closeChannel: emptied, hasRest: false))
    }

    func testLateSuccessOfAPartialMoveOffersTheRest() {
        let channel = ChannelDetails.mock(outboundCapacityMsat: 50_000_000)
        let done = MoveToSparkManager.doneState(amountSats: 25000, feeSats: 7, channels: [channel])
        XCTAssertEqual(done, .done(amountSats: 25000, feeSats: 7, closeChannel: channel, hasRest: true))
    }

    func testLateOutcomeOfAnOlderMoveLeavesTheScreen() {
        XCTAssertFalse(MoveToSparkManager.showsInFlightMove(.inFlight(amountSats: 40000), generation: 4, moveGeneration: 3))
        XCTAssertFalse(MoveToSparkManager.showsInFlightMove(.quoting, generation: 3, moveGeneration: 3))
    }

    @MainActor
    func testFailureRightAfterTheTimeoutFindsTheMoveInFlight() async throws {
        let hash = "move-hash"
        let (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        var steps: [String] = []
        let failed = expectation(description: "the late failure is reported")
        let settled = try await WalletViewModel.settle(
            paymentId: hash,
            events: events,
            timeout: .milliseconds(10),
            onTimeout: {
                steps.append("inFlight")
                // The failure arrives in the gap before the caller resumes.
                sink.yield(.paymentFailed(paymentId: hash, paymentHash: hash, reason: nil))
            },
            onLateFailure: {
                steps.append("failed")
                failed.fulfill()
            },
            onLateSuccess: { _ in steps.append("moved") }
        )
        XCTAssertNil(settled)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(steps, ["inFlight", "failed"])
    }

    @MainActor
    func testSuccessBeforeTheTimeoutSettlesTheMove() async throws {
        let hash = "move-hash"
        let (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        sink.yield(.paymentSuccessful(paymentId: hash, paymentHash: hash, paymentPreimage: "pp", feePaidMsat: 12000))
        var timedOut = false
        let settled = try await WalletViewModel.settle(
            paymentId: hash,
            events: events,
            timeout: .seconds(5),
            onTimeout: { timedOut = true },
            onLateFailure: {},
            onLateSuccess: { _ in }
        )
        XCTAssertEqual(settled?.feePaidSats, 12)
        XCTAssertFalse(timedOut)
    }
}
