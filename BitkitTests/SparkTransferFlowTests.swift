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
            .adding
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
        XCTAssertEqual(SparkClaimDecision.onClaim(.claimed), .adding)
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
        XCTAssertEqual(flow.claimState, .adding)
    }

    @MainActor
    func testWaitingKeepsPollingUntilClaimed() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900), choice(earlyFee: 900)], claims: [.waiting, .claimed])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .adding)
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
        XCTAssertEqual(flow.claimState, .adding)
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
