@testable import Bitkit
import BitkitCore
import XCTest

final class PubkySwapsTrackerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PubkySwapsTrackerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testACommittedSwapIsKeptForTheNextLaunch() async {
        let tracker = makeTracker(ScriptedAdvance([.success(.awaitingPayment)]))
        await tracker.didCommit("swap")
        XCTAssertEqual(store.swapIds, ["swap"])
    }

    func testResumeAdvancesUntilTheClaimConfirmsThenForgetsTheSwap() async throws {
        let advance = ScriptedAdvance([.success(.claimBroadcast(txid: "tx")), .success(.claimBroadcast(txid: "tx")), .success(.claimed(txid: "tx"))])
        let tracker = makeTracker(advance)
        store.track(["swap"])

        await tracker.resume()

        try await waitUntilFinished(tracker, "swap")
        let calls = await advance.calls
        XCTAssertEqual(calls, 3)
    }

    func testATransientAdvanceFailureKeepsAdvancing() async throws {
        let advance = ScriptedAdvance([.failure(PubkySwapError.Transport(errorDetails: "offline")), .success(.claimed(txid: "tx"))])
        let tracker = makeTracker(advance)
        store.track(["swap"])

        await tracker.resume()

        try await waitUntilFinished(tracker, "swap")
        let calls = await advance.calls
        XCTAssertEqual(calls, 2)
    }

    func testResumeForgetsAFailedSwapOrOneBitkitCoreDoesNotKnow() async throws {
        let outcomes: [Result<PubkySwapRouteState, Error>] = [
            .success(.failed(reason: "refunded")),
            .failure(PubkySwapError.NotFound(errorDetails: "swap")),
        ]
        for outcome in outcomes {
            let advance = ScriptedAdvance([outcome, .success(.claimed(txid: "tx"))])
            let tracker = makeTracker(advance)
            store.track(["swap"])

            await tracker.resume()

            try await waitUntilFinished(tracker, "swap")
            let calls = await advance.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testResumeStopsASwapWhoseHoldPaymentFailed() async throws {
        let advance = ScriptedAdvance([.success(.awaitingLockup(confirmations: 0, required: 1))])
        let tracker = makeTracker(advance, isHoldPaymentFailed: { $0.paymentHash == "hash" })
        await tracker.didCommit("swap")
        await tracker.watchHold(PubkySwapHoldPayment(paymentHash: "hash", invoice: "lnbcrt1"), swapId: "swap")

        await tracker.resume()

        try await waitUntilFinished(tracker, "swap")
        XCTAssertNil(store.holdPayment(for: "swap"))
        let calls = await advance.calls
        XCTAssertEqual(calls, 0)
        do {
            _ = try await tracker.awaitClaim(swapId: "swap", timeout: 1)
            XCTFail("A swap whose hold failed is not awaited")
        } catch PubkySwapClaimError.holdFailed {}
    }

    func testDropStopsAdvancingAndForgetsTheSwap() async {
        let tracker = makeTracker(ScriptedAdvance([.success(.awaitingLockup(confirmations: 0, required: 1))]))
        await tracker.didCommit("swap")
        await tracker.resume()
        let isAdvancing = await tracker.isAdvancing("swap")
        XCTAssertTrue(isAdvancing)

        await tracker.drop("swap")

        let isStillAdvancing = await tracker.isAdvancing("swap")
        XCTAssertFalse(isStillAdvancing)
        XCTAssertEqual(store.swapIds, [])
        await tracker.resume()
        let isAdvancingAgain = await tracker.isAdvancing("swap")
        XCTAssertFalse(isAdvancingAgain)
    }

    func testAwaitClaimReturnsAtTheBroadcastAndKeepsAdvancingUntilConfirmed() async throws {
        let advance = ScriptedAdvance([.success(.claimBroadcast(txid: "tx")), .success(.claimBroadcast(txid: "tx")), .success(.claimed(txid: "tx"))])
        let tracker = makeTracker(advance)
        await tracker.didCommit("swap")

        let txid = try await tracker.awaitClaim(swapId: "swap", timeout: 5)

        XCTAssertEqual(txid, "tx")
        XCTAssertEqual(store.swapIds, ["swap"])
        try await waitUntilFinished(tracker, "swap")
    }

    func testAwaitClaimThatRunsOutKeepsAdvancing() async throws {
        let tracker = makeTracker(ScriptedAdvance([.success(.awaitingLockup(confirmations: 0, required: 1))]))
        await tracker.didCommit("swap")

        do {
            _ = try await tracker.awaitClaim(swapId: "swap", timeout: 0)
            XCTFail("The wait should run out")
        } catch PubkySwapClaimError.timedOut {}

        let isAdvancing = await tracker.isAdvancing("swap")
        XCTAssertTrue(isAdvancing)
        XCTAssertEqual(store.swapIds, ["swap"])
        await tracker.resetForWipe()
    }

    func testAwaitClaimForgetsAFailedSwap() async {
        let tracker = makeTracker(ScriptedAdvance([.success(.failed(reason: "refunded"))]))
        await tracker.didCommit("swap")

        do {
            _ = try await tracker.awaitClaim(swapId: "swap", timeout: 5)
            XCTFail("The swap failed")
        } catch PubkySwapClaimError.failed {} catch {
            XCTFail("Unexpected \(error)")
        }

        XCTAssertEqual(store.swapIds, [])
        let isAdvancing = await tracker.isAdvancing("swap")
        XCTAssertFalse(isAdvancing)
    }

    func testRestoreLeavesTheSwapsThisSessionCommittedOrDroppedToTheSendFlow() async {
        let tracker = makeTracker(ScriptedAdvance([.success(.awaitingPayment)]))
        await tracker.didCommit("committed")
        await tracker.didCommit("dropped")
        await tracker.drop("dropped")

        let adopted = await tracker.adoptRestored(restored: ["restored"], known: ["committed", "dropped", "known"])

        XCTAssertEqual(adopted.restored, ["restored"])
        XCTAssertEqual(adopted.known, ["known"])
        XCTAssertEqual(Set(store.swapIds), ["committed", "restored", "known"])
    }

    func testWipeStopsAndForgetsEverySwap() async {
        let tracker = makeTracker(ScriptedAdvance([.success(.awaitingLockup(confirmations: 0, required: 1))]))
        await tracker.didCommit("swap")
        await tracker.watchHold(PubkySwapHoldPayment(paymentHash: "hash", invoice: "lnbcrt1"), swapId: "swap")
        await tracker.resume()

        await tracker.resetForWipe()

        let isAdvancing = await tracker.isAdvancing("swap")
        XCTAssertFalse(isAdvancing)
        XCTAssertEqual(store.swapIds, [])
        XCTAssertNil(store.holdPayment(for: "swap"))
    }

    // MARK: - Helpers

    private var store: UnfinishedPubkySwapsStore {
        UnfinishedPubkySwapsStore(defaults: defaults)
    }

    private func makeTracker(
        _ advance: ScriptedAdvance,
        isHoldPaymentFailed: @escaping @Sendable (PubkySwapHoldPayment) async -> Bool = { _ in false }
    ) -> PubkySwapsTracker {
        PubkySwapsTracker(
            store: store,
            advance: { _ in try await advance.next() },
            isHoldPaymentFailed: isHoldPaymentFailed,
            claimPollInterval: .milliseconds(5),
            confirmationPollInterval: .milliseconds(5)
        )
    }

    private func waitUntilFinished(_ tracker: PubkySwapsTracker, _ swapId: String) async throws {
        for _ in 0 ..< 400 {
            let isAdvancing = await tracker.isAdvancing(swapId)
            if !isAdvancing, !store.swapIds.contains(swapId) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Swap \(swapId) still advancing")
    }
}

/// Answers each advance with the next scripted outcome, repeating the last one.
actor ScriptedAdvance {
    private let outcomes: [Result<PubkySwapRouteState, Error>]
    private(set) var calls = 0

    init(_ outcomes: [Result<PubkySwapRouteState, Error>]) {
        self.outcomes = outcomes
    }

    func next() throws -> PubkySwapRouteState {
        defer { calls += 1 }
        return try outcomes[min(calls, outcomes.count - 1)].get()
    }
}
