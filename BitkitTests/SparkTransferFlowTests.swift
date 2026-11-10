@testable import Bitkit
import XCTest

final class SparkTransferFlowTests: XCTestCase {
    private let ceiling: UInt64 = 1000

    private func choice(earlyFee: UInt64) -> SparkClaimOffer.Kind {
        .choice(earlyFeeSats: earlyFee, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3)
    }

    func testInstantWithinCeilingClaimsEarly() {
        XCTAssertEqual(SparkClaimDecision.onOffer(choice(earlyFee: 900), speed: .instant, ceilingSats: ceiling), .claiming)
        XCTAssertEqual(SparkClaimDecision.onOffer(choice(earlyFee: ceiling), speed: .instant, ceilingSats: ceiling), .claiming)
    }

    func testInstantOverCeilingAsksBeforePaying() {
        XCTAssertEqual(
            SparkClaimDecision.onOffer(choice(earlyFee: 1500), speed: .instant, ceilingSats: ceiling),
            .repriced(feeSats: 1500)
        )
    }

    func testInstantWithoutEarlyOfferWaitsForConfirmations() {
        XCTAssertEqual(
            SparkClaimDecision.onOffer(.standard(feeSats: 198, confirmations: 3), speed: .instant, ceilingSats: ceiling),
            .unavailable
        )
    }

    func testInstantClaimedBySdkAddsIt() {
        XCTAssertEqual(
            SparkClaimDecision.onOffer(.automatic(feeSats: 300, confirmations: 0), speed: .instant, ceilingSats: ceiling),
            .added
        )
    }

    func testLaterNeverClaimsEarly() {
        XCTAssertEqual(SparkClaimDecision.onOffer(choice(earlyFee: 10), speed: .later, ceilingSats: ceiling), .later)
        XCTAssertEqual(
            SparkClaimDecision.onOffer(.standard(feeSats: 198, confirmations: 3), speed: .later, ceilingSats: ceiling),
            .later
        )
    }

    func testClaimOutcomes() {
        XCTAssertEqual(SparkClaimDecision.onClaim(.claimed), .added)
        XCTAssertEqual(SparkClaimDecision.onClaim(.submitted), .adding)
        XCTAssertEqual(SparkClaimDecision.onClaim(.repriced(requiredFeeSats: 1200)), .repriced(feeSats: 1200))
        XCTAssertEqual(SparkClaimDecision.onClaim(.declined), .unavailable)
        XCTAssertNil(SparkClaimDecision.onClaim(.waiting))
    }

    @MainActor
    func testLaterBroadcastSkipsTheClaim() {
        let flow = SparkTransferFlow(amountSats: 100_000, speed: .later, quote: quote)
        flow.onBroadcast(txid: "txid")
        XCTAssertEqual(flow.claimState, .later)
    }

    @MainActor
    func testWaitFallsBackToLater() {
        let flow = SparkTransferFlow(amountSats: 100_000, claimState: .repriced(feeSats: 1500))
        flow.waitForConfirmations()
        XCTAssertEqual(flow.claimState, .later)
    }

    @MainActor
    func testWaitAfterAClaimTimeRepriceClearsTheEarlyClaimCap() async throws {
        var released: [String] = []
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { _ in .repriced(requiredFeeSats: 1500) },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { released.append($0.txid)
                return true
            }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.waitForConfirmations()
        for _ in 0 ..< 100 where released.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(flow.claimState, .later)
        XCTAssertEqual(released, ["txid"], "Spark may still claim early at the cap Wait declined")
    }

    @MainActor
    func testWaitClearsTheEarlyClaimCapAgainWhenAnotherClaimHeldTheDeposit() async throws {
        var releaseCalls = 0
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { _ in .repriced(requiredFeeSats: 1500) },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { _ in
                releaseCalls += 1
                // The first call meets Spark's own sync claiming the deposit, which leaves the cap in place.
                return releaseCalls > 1
            }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()

        flow.waitForConfirmations()
        for _ in 0 ..< 100 where releaseCalls < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(releaseCalls, 2, "Wait gave up on the early claim cap after Spark was busy with the deposit")
    }

    @MainActor
    func testWaitBeforeAnyClaimAttemptLeavesTheDepositAlone() async throws {
        var released: [String] = []
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 1500, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { _ in .claimed },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { released.append($0.txid)
                return true
            }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.waitForConfirmations()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(released, [])
    }

    @MainActor
    func testTimeoutWhenSparkNeverListsTheDeposit() async {
        let flow = pollingFlow(offers: [nil, nil, nil])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .notSeen)
    }

    @MainActor
    func testListedDepositWhoseEarlyClaimKeepsWaitingIsNotUnseen() async {
        let flow = pollingFlow(
            offers: [choice(earlyFee: 900), choice(earlyFee: 900), choice(earlyFee: 900)],
            claims: [.waiting, .waiting, .waiting],
            pollAttempts: 3
        )
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .unavailable)
    }

    @MainActor
    func testDepositListedThenGoneWasAdded() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900), nil], claims: [.waiting])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
    }

    @MainActor
    func testWaitingKeepsPollingUntilClaimed() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900), choice(earlyFee: 900)], claims: [.waiting, .claimed])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
    }

    @MainActor
    func testPayAfterRepriceClaimsAtTheNewFee() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 1500), choice(earlyFee: 1500)], claims: [.claimed])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.payRepriced()
        XCTAssertEqual(flow.claimState, .claiming)
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
    }

    @MainActor
    func testDeclinedEarlyClaimWaitsForConfirmations() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.declined])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .unavailable)
    }

    @MainActor
    func testANewTransferKeepsTheEarlierClaimAndItsResultOffScreen() async throws {
        var claimed: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { offer in
                await withCheckedContinuation { release = $0 }
                claimed.append(offer.txid)
                return .claimed
            },
            refresh: {},
            sleep: { _ in }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2)
        flow.onBroadcast(txid: "first")
        for _ in 0 ..< 100 where release == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        flow.beginIfBroadcast()
        flow.speed = .later
        flow.onBroadcast(txid: "second")
        release?.resume()
        for _ in 0 ..< 100 where claimed.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(claimed, ["first"], "The earlier deposit's early claim went on")
        XCTAssertEqual(flow.claimState, .later, "Its result stays off the new transfer's screen")
    }

    @MainActor
    func testSubmittedEarlyClaimShowsAddingUntilTheDepositSettles() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.submitted])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .adding)
        XCTAssertFalse(flow.claimState.isDone, "Setting up showed success while the claim was only submitted")

        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: false)])
        XCTAssertEqual(flow.claimState, .adding)
        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .added)
        XCTAssertTrue(flow.claimState.isDone)
    }

    @MainActor
    func testALaterTransferEndsOnceSparkClaimsItsDeposit() {
        let flow = SparkTransferFlow(amountSats: 100_000, speed: .later, quote: quote)
        flow.onBroadcast(txid: "txid")

        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: false)])
        XCTAssertEqual(flow.claimState, .later)
        flow.noteSettled([SparkDeposit(txid: "other", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .later)
        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .added, "Later stayed in progress after the deposit reached spending")
    }

    @MainActor
    func testARecoveredFundingClaimsEarlyOnlyUpToTheSwipedCeiling() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        flow.quote = quote(instantMax: 337)
        let attemptId = UUID()
        flow.approveSwipe()
        flow.bindApproval(to: attemptId)
        // The confirm screen requoted under the pending sheet while fee rates rose.
        flow.quote = quote(instantMax: 3010)

        flow.onRecoveredBroadcast(txid: "txid", attemptId: attemptId)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "Paid an early claim fee the user never approved")
    }

    @MainActor
    func testARecoveredFundingKeepsItsOwnApprovalWhenALaterSwipeIsRejected() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let first = UUID()
        flow.quote = quote(instantMax: 337)
        flow.approveSwipe()
        flow.bindApproval(to: first)
        // A second swipe at a higher ceiling is rejected while the first funding is still unresolved, so the attempt
        // the screen sees is still the first one.
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: first)

        flow.onRecoveredBroadcast(txid: "txid", attemptId: first)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "The first funding claimed early at the rejected swipe's ceiling")
    }

    @MainActor
    func testASwipeRefusedForAnOlderFundingAfterARelaunchLeavesItsEarlyClaimAsking() async {
        // After a relaunch nothing is tied to the older funding still unresolved, which refuses the new swipe.
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let older = UUID()
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: older, after: OnchainSendAttemptError.blocked(nil))

        flow.onRecoveredBroadcast(txid: "txid", attemptId: older)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "The older funding claimed early at the refused swipe's ceiling")
    }

    @MainActor
    func testASwipeWhoseFundingIsLeftUnresolvedTiesItsApprovalToIt() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let attemptId = UUID()
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: attemptId, after: OnchainSendAttemptError.unresolved)

        flow.onRecoveredBroadcast(txid: "txid", attemptId: attemptId)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .added, "The funding this swipe left unresolved lost the approval it gave")
    }

    @MainActor
    func testARecoveredFundingWithNoApprovalAsksBeforeAnEarlyClaim() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()

        flow.onRecoveredBroadcast(txid: "txid", attemptId: UUID())
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "Claimed early on an approval made for another attempt")
    }

    private func quote(instantMax: UInt64) -> SparkTransferQuote {
        SparkTransferQuote(
            address: "bcrt1qtest", satsPerVbyte: 6, networkFeeSats: 577, depositSats: 100_000,
            claimFees: SparkClaimFees(instantMaxSats: instantMax, laterSats: 198)
        )
    }

    /// A flow whose poll answers with `offers` in turn (nil once they run out) and whose claims answer with `claims`.
    @MainActor
    private func pollingFlow(offers: [SparkClaimOffer.Kind?], claims: [SparkEarlyClaim] = [], pollAttempts: Int? = nil) -> SparkTransferFlow {
        var offers = offers
        var claims = claims
        let operations = SparkClaimOperations(
            offer: { txid in
                guard !offers.isEmpty, let kind = offers.removeFirst() else { return nil }
                return SparkClaimOffer(txid: txid, vout: 0, kind: kind)
            },
            claimEarly: { _ in claims.isEmpty ? .waiting : claims.removeFirst() },
            refresh: {},
            sleep: { _ in }
        )
        return SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: pollAttempts ?? offers.count + 1)
    }

    @MainActor
    func testARefusedFixedFundingKeepsItsFeeUntilTheTransferChanges() {
        let flow = SparkTransferFlow()
        flow.start(amountSats: 50000, isMaxAmount: false)
        flow.onFundingChanged(preparedFeeSats: 700)
        XCTAssertEqual(flow.fixedFeeFloorSats, 700, "The next swipe would approve less than the refused fee")
        flow.start(amountSats: 50000, isMaxAmount: false)
        XCTAssertEqual(flow.fixedFeeFloorSats, 700)
        flow.start(amountSats: 60000, isMaxAmount: false)
        XCTAssertNil(flow.fixedFeeFloorSats)

        flow.start(amountSats: 60000, isMaxAmount: true)
        flow.onFundingChanged(preparedFeeSats: 700)
        XCTAssertNil(flow.fixedFeeFloorSats, "Max re-prices from the balance instead")
    }

    func testQuoteTiles() {
        XCTAssertEqual(quote.toSpendingSats(for: .instant), 100_000 - 1093)
        XCTAssertEqual(quote.toSpendingSats(for: .later), 100_000 - 198)
        XCTAssertEqual(quote.totalSats, 100_577)
    }

    func testMatureClaimFee() {
        XCTAssertEqual(SparkManager.matureDepositClaimFeeSats(halfHourFeeRate: 2), 198)
    }

    private var quote: SparkTransferQuote {
        SparkTransferQuote(
            address: "bcrt1qtest",
            satsPerVbyte: 6,
            networkFeeSats: 577,
            depositSats: 100_000,
            claimFees: SparkClaimFees(instantMaxSats: 1093, laterSats: 198)
        )
    }
}
