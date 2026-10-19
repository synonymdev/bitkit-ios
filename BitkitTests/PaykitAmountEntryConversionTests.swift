@testable import Bitkit
import Foundation
import XCTest

final class PaykitAmountEntryConversionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var rate: PaykitExchangeRate {
        PaykitExchangeRate(price: "65432.10", timestamp: now)
    }

    func testRepeatedTogglesRoundOnlyOnceFromTheEnteredAmount() throws {
        for original in try [PaykitAmount(asset: .usd, value: "10"), PaykitAmount(asset: .btc, atomic: 12345),
                             PaykitAmount(asset: .usdt, value: "10.000001")]
        {
            var conversion = PaykitAmountEntryConversion()
            var amount = original
            let other: PaykitAsset = original.asset == .btc ? .usd : .btc
            let expected = try original.converted(to: other, rate: rate, at: now)
            for _ in 0 ..< 8 {
                amount = try conversion.converted(amount, to: other, rate: rate, at: now)
                XCTAssertEqual(amount, expected)
                amount = try conversion.converted(amount, to: original.asset, rate: rate, at: now)
                XCTAssertEqual(amount, original)
            }
        }
    }

    func testEditsReplaceTheConversionSource() throws {
        var conversion = PaykitAmountEntryConversion()
        let original = try PaykitAmount(asset: .usd, value: "10")
        let bitcoin = try conversion.converted(original, to: .btc, rate: rate, at: now)
        let edited = PaykitAmount(asset: .btc, atomic: bitcoin.atomic + 100)
        let dollars = try conversion.converted(edited, to: .usd, rate: rate, at: now)
        XCTAssertEqual(try conversion.converted(dollars, to: .btc, rate: rate, at: now), edited)

        conversion.reset()
        let enteredAgain = try conversion.converted(dollars, to: .btc, rate: rate, at: now)
        XCTAssertEqual(enteredAgain, try dollars.converted(to: .btc, rate: rate, at: now))
    }

    func testClearedAndZeroInputsCannotReviveAnEarlierAmount() throws {
        for cleared: PaykitAmount? in [nil, PaykitAmount(asset: .usd, atomic: 0)] {
            var conversion = PaykitAmountEntryConversion()
            _ = try conversion.converted(PaykitAmount(asset: .btc, atomic: 50000), to: .usd, rate: rate, at: now)
            let bitcoin = try conversion.converted(cleared, to: .btc, rate: nil, at: now)
            XCTAssertEqual(bitcoin.atomic, 0)
            XCTAssertEqual(try conversion.converted(bitcoin, to: .usd, rate: nil, at: now).atomic, 0)
        }
    }

    func testFailedConversionRetainsTheEnteredAmount() throws {
        var conversion = PaykitAmountEntryConversion()
        let original = try PaykitAmount(asset: .usd, value: "10")
        XCTAssertThrowsError(try conversion.converted(original, to: .btc, rate: nil, at: now))
        let bitcoin = try conversion.converted(original, to: .btc, rate: rate, at: now)
        XCTAssertEqual(try conversion.converted(bitcoin, to: .usd, rate: rate, at: now), original)
    }

    func testInputParserAcceptsATrailingDecimalWithoutRelaxingProtocolParsing() throws {
        for asset in [PaykitAsset.usd, .usdt] {
            XCTAssertEqual(try parsePaykitAmountInput(asset: asset, value: "5.").value, "5")
            XCTAssertThrowsError(try PaykitAmount(asset: asset, value: "5."))
            for invalid in ["", ".", "5..", "0.", "-5.", "5,", "5e1."] {
                XCTAssertThrowsError(try parsePaykitAmountInput(asset: asset, value: invalid), invalid)
            }
        }
    }
}
