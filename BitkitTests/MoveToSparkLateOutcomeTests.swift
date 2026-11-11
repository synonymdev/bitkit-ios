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

    @MainActor
    func testEndedStreamStopsTheLateWatch() async throws {
        let (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        var lateOutcomes = 0
        let ended = expectation(description: "the watch ends with its stream")
        let settled = try await WalletViewModel.settle(
            paymentId: "move-hash",
            events: events,
            timeout: .milliseconds(10),
            onTimeout: {},
            onLateFailure: { lateOutcomes += 1 },
            onLateSuccess: { _ in lateOutcomes += 1 },
            onEnd: { ended.fulfill() }
        )
        XCTAssertNil(settled)
        // A wipe ends the stream of a move still waiting for its late outcome.
        sink.finish()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(lateOutcomes, 0)
    }

    @MainActor
    func testWipeForgetsAnUnsettledMove() {
        let manager = MoveToSparkManager()
        let moveGeneration = manager.beginMove()
        manager.showInFlight(amountSats: 40000, moveGeneration: moveGeneration)
        manager.reset()
        XCTAssertEqual(manager.state, .inFlight(amountSats: 40000), "leaving the screen keeps the unsettled move")

        manager.resetForWipe()
        XCTAssertEqual(manager.state, .quoting)
        manager.showInFlight(amountSats: 40000, moveGeneration: moveGeneration)
        XCTAssertEqual(manager.state, .quoting, "the wiped move's late result leaves the next wallet's screen alone")
        manager.reset()
        XCTAssertFalse(MoveToSparkManager.showsInFlightMove(manager.state, generation: manager.generation, moveGeneration: moveGeneration))
    }
}
