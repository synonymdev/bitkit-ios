@testable import Bitkit
import LDKNode
import XCTest

final class MoveToSparkLateOutcomeTests: XCTestCase {
    private let suiteName = "MoveToSparkLateOutcomeTests-\(UUID().uuidString)"
    private var appDefaults: UserDefaults?

    /// A wipe clears the moves' stored hashes, so the suite keeps them out of the app's own defaults.
    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        appDefaults = MoveToSparkPayments.defaults
        MoveToSparkPayments.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    @MainActor
    override func tearDown() async throws {
        if let appDefaults {
            MoveToSparkPayments.defaults = appDefaults
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    @MainActor
    func testAMoveKeptForItsResultKeepsItsScreenReachableUntilTheWalletIsWiped() {
        let manager = MoveToSparkManager()
        XCTAssertFalse(manager.keepsMoveForItsResult)

        _ = manager.beginMove()
        XCTAssertTrue(manager.keepsMoveForItsResult, "A move in flight hid its screen once the channels had nothing left to move")
        manager.reset()
        XCTAssertTrue(manager.keepsMoveForItsResult, "Leaving the screen of a move in flight forgot it")

        manager.resetForWipe()
        XCTAssertFalse(manager.keepsMoveForItsResult)
    }

    @MainActor
    func testOnlyAWipeStopsClosingTheChannelsAMoveEmptied() {
        let manager = MoveToSparkManager()
        let wipe = manager.wipes
        _ = manager.beginMove()
        manager.resetForWipe()
        XCTAssertEqual(manager.wipes, wipe + 1)
        manager.reset()
        _ = manager.beginMove()
        XCTAssertEqual(manager.wipes, wipe + 1, "Closing the modal or a new move stopped the closes of an earlier move")
    }

    @MainActor
    func testAStoppedMoveIsKeptForTheNextQuoteUntilANewMoveOrItsOutcome() async {
        let manager = MoveToSparkManager()
        let quote = MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 13000, feeSats: 80)

        await manager.quote(afterMove: nil, stoppedAfter: 0) { quote }
        XCTAssertEqual(manager.state, .confirm(quote, isMoving: false))
        XCTAssertEqual(manager.lastMovedSats, 0, "The quote after a move that moved nothing did not say so")
        manager.reset()
        await manager.quote(afterMove: nil) { quote }
        XCTAssertEqual(manager.lastMovedSats, 0, "Closing and reopening the modal asked again without the last attempt")

        _ = manager.beginMove(leftSats: 13080)
        XCTAssertNil(manager.lastMovedSats, "A new move kept the attempt before it")
        XCTAssertEqual(manager.retriedAttempt?.movedSats, 0, "Try Again dropped the attempt it retries while it paid")
        XCTAssertEqual(manager.retriedAttempt?.leftSats, 13080, "Try Again did not keep what the prompt said was left")

        await manager.quote(afterMove: (6512, 20), stoppedAfter: 6512) { throw MoveToSparkError.noRoute }
        XCTAssertNil(manager.lastMovedSats, "A move shown as done kept its stop")
        _ = manager.beginMove()
        XCTAssertNil(manager.retriedAttempt, "A first move said it tried an earlier attempt again")

        await manager.quote(afterMove: nil, stoppedAfter: 0) { quote }
        _ = manager.beginMove()
        manager.resetForWipe()
        XCTAssertNil(manager.retriedAttempt, "A wipe kept the attempt of the wiped wallet")
    }

    func testARestThatNoLongerRoutesOrIsGoneShowsTheBalanceUpdated() {
        let done = MoveToSparkState.done(amountSats: 60000, feeSats: 60)
        XCTAssertEqual(MoveToSparkManager.state(forQuoteError: MoveToSparkError.noRoute, afterMove: (60000, 60)), done)
        XCTAssertEqual(MoveToSparkManager.state(forQuoteError: MoveToSparkError.nothingToMove, afterMove: (60000, 60)), done)
    }

    func testARestQuoteThatFailsOtherwiseOffersTryAgain() {
        struct NetworkDown: Error {}
        XCTAssertEqual(
            MoveToSparkManager.state(forQuoteError: NetworkDown(), afterMove: (60000, 60)),
            .failed(.unknown),
            "A move with balance left reported the balance updated"
        )
        XCTAssertEqual(MoveToSparkManager.state(forQuoteError: MoveToSparkError.sparkUnavailable, afterMove: (60000, 60)), .failed(.sparkUnavailable))
        XCTAssertEqual(MoveToSparkManager.state(forQuoteError: MoveToSparkError.noRoute, afterMove: nil), .failed(.unknown))
    }

    @MainActor
    func testTryAgainAfterAPartialMoveShowsItMovedOnceTheRestNoLongerRoutes() async {
        struct NetworkDown: Error {}
        let manager = MoveToSparkManager()
        await manager.quote(afterMove: (60000, 60)) { throw NetworkDown() }
        XCTAssertEqual(manager.state, .failed(.unknown))

        await manager.quote(afterMove: nil) { throw MoveToSparkError.noRoute }

        XCTAssertEqual(manager.state, .done(amountSats: 60000, feeSats: 60), "Try Again forgot what the move moved")
    }

    @MainActor
    func testClosingTheModalForgetsThePartialMoveForTryAgain() async {
        struct NetworkDown: Error {}
        let manager = MoveToSparkManager()
        await manager.quote(afterMove: (60000, 60)) { throw NetworkDown() }
        manager.reset()

        await manager.quote(afterMove: nil) { throw MoveToSparkError.noRoute }

        XCTAssertEqual(manager.state, .failed(.unknown))
    }

    @MainActor
    func testANewOpeningQuotesAfreshAfterAFailedRestQuote() async {
        struct NetworkDown: Error {}
        let manager = MoveToSparkManager()
        await manager.quote(afterMove: (60000, 60)) { throw NetworkDown() }

        // A node that is not set up leaves nothing to move.
        await manager.start(wallet: WalletViewModel())

        XCTAssertEqual(manager.state, .failed(.nothingToMove), "A new opening ended on an earlier move's outcome")
    }

    func testTheInFlightMoveIsTheOneOnScreen() {
        XCTAssertTrue(MoveToSparkManager.showsInFlightMove(.inFlight(amountSats: 40000), generation: 3, moveGeneration: 3))
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
