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
