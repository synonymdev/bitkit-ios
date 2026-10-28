@testable import Bitkit
import BreezSdkSpark
import XCTest

final class SparkClaimOfferTests: XCTestCase {
    func testOffersOnlyTheStandardClaimWhenNoEarlyClaimIsQuoted() {
        let offer = SparkClaimOffer(txid: "txid", vout: 1, quote: quote(instant: nil))

        XCTAssertEqual(offer.kind, .standard(feeSats: 907, confirmations: 3))
    }

    func testLeavesAnEarlyClaimWithinTheCapToTheSdk() {
        let offer = SparkClaimOffer(txid: "txid", vout: 1, quote: quote(instant: early(feeSats: 900, maxFeeSats: 1000)))

        XCTAssertEqual(offer.kind, .automatic(feeSats: 900, confirmations: 0))
    }

    func testOffersAChoiceWhenTheEarlyClaimCostsMoreThanTheCap() {
        let offer = SparkClaimOffer(txid: "txid", vout: 1, quote: quote(instant: early(feeSats: 1350, maxFeeSats: 1000, confirmations: 1)))

        XCTAssertEqual(offer.kind, .choice(earlyFeeSats: 1350, earlyConfirmations: 1, standardFeeSats: 907, standardConfirmations: 3))
    }

    func testOffersAChoiceWhenAutomaticClaimingIsOff() {
        let offer = SparkClaimOffer(txid: "txid", vout: 1, quote: quote(instant: early(feeSats: 900, maxFeeSats: nil)))

        XCTAssertEqual(offer.kind, .choice(earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 907, standardConfirmations: 3))
    }

    func testMapsEachClaimOutcome() {
        XCTAssertEqual(SparkEarlyClaim(.submitted), .claimed)
        XCTAssertEqual(SparkEarlyClaim(.deferred(reason: .noEarlyClaimAvailable)), .waiting)
        XCTAssertEqual(SparkEarlyClaim(.deferred(reason: .maxFeeExceeded(requiredFeeSats: 1500, maxFeeSats: 1350))), .repriced(requiredFeeSats: 1500))
        XCTAssertEqual(SparkEarlyClaim(.deferred(reason: .providerDeclined(message: "busy"))), .declined)
    }

    private func quote(instant: ClaimDepositQuote?) -> FetchClaimDepositQuoteResponse {
        FetchClaimDepositQuoteResponse(
            amountSats: 15000,
            confirmations: 0,
            instant: instant,
            mature: ClaimDepositQuote(confirmationsRequired: 3, creditAmountSats: 14093, feeSats: 907, maxFeeSats: 1000, isEstimate: false)
        )
    }

    private func early(feeSats: UInt64, maxFeeSats: UInt64?, confirmations: UInt32 = 0) -> ClaimDepositQuote {
        ClaimDepositQuote(
            confirmationsRequired: confirmations,
            creditAmountSats: 15000 - feeSats,
            feeSats: feeSats,
            maxFeeSats: maxFeeSats,
            isEstimate: false
        )
    }
}
