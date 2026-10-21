@testable import Bitkit
import BitkitCore
import XCTest

final class UsdtPreparedQuoteTests: XCTestCase {
    private let sender = "0x2222222222222222222222222222222222222222"
    private let recipient = "0x1111111111111111111111111111111111111111"

    private var prepared: UsdtPreparedQuote {
        UsdtPreparedQuote(
            quote: UsdtQuote(bridgeProvider: nil, id: "quote", recipient: recipient, destination: .arbitrum,
                             amount: 1_000_000, receivedAmount: 1_000_000, maximumFee: 20, expiresAt: 120),
            amount: "1", sender: sender
        )
    }

    func testQuotedCostIncludesDeductedBridgeFeesWithoutUnsignedOverflow() {
        var quote = prepared.quote
        XCTAssertEqual(quote.totalCost, 20)
        quote.receivedAmount = 400_000
        XCTAssertEqual(quote.totalCost, 600_020)
        quote.maximumFee = UInt64.max
        XCTAssertEqual(quote.totalCost, UInt64.max)
        quote.receivedAmount = 2_000_000
        quote.maximumFee = 20
        XCTAssertEqual(quote.totalCost, 20)
    }

    func testUnchangedPaymentKeepsTheApprovedFeeUntilTheExpiryBuffer() {
        XCTAssertTrue(prepared.matches(recipient: recipient, amount: "1", destination: .arbitrum, sender: sender,
                                       now: Date(timeIntervalSince1970: 114)))
        for timestamp in [115.0, 119.0, 120.0, 121.0] {
            XCTAssertFalse(prepared.matches(recipient: recipient, amount: "1", destination: .arbitrum, sender: sender,
                                            now: Date(timeIntervalSince1970: timestamp)), "timestamp \(timestamp)")
        }
    }

    func testDifferentPaymentOrWalletRequiresANewQuote() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(prepared.matches(recipient: sender, amount: "1", destination: .arbitrum, sender: sender, now: now))
        XCTAssertFalse(prepared.matches(recipient: recipient, amount: "2", destination: .arbitrum, sender: sender, now: now))
        XCTAssertFalse(prepared.matches(recipient: recipient, amount: "1", destination: .polygon, sender: sender, now: now))
        XCTAssertFalse(prepared.matches(recipient: recipient, amount: "1", destination: .arbitrum, sender: recipient, now: now))
        XCTAssertFalse(prepared.matches(recipient: recipient, amount: "1", destination: .arbitrum, sender: "", now: now))
    }
}
