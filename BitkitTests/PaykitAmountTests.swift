@testable import Bitkit
import Foundation
import XCTest

final class PaykitAmountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var rate: PaykitExchangeRate {
        PaykitExchangeRate(price: "100000", timestamp: now)
    }

    func testConversionPreservesValueAndRoundsPaymentUnitsUpward() throws {
        let cases: [(PaykitAsset, String, PaykitAsset, String)] = [
            (.usd, "5", .usdt, "5"),
            (.usdt, "5.000001", .usd, "5.01"),
            (.btc, "0.00000001", .usdt, "0.001"),
            (.usd, "5", .btc, "0.00005"),
            (.usdt, "0.000001", .btc, "0.00000001"),
        ]
        for (source, value, target, expected) in cases {
            XCTAssertEqual(try PaykitAmount(asset: source, value: value).converted(to: target, rate: rate, at: now).value, expected)
        }
    }

    func testStaleMissingAndFutureRatesBlockOnlyBitcoinConversions() throws {
        let amount = try PaykitAmount(asset: .usd, value: "5")
        let invalidRates: [PaykitExchangeRate?] = [nil,
                                                   PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-601)),
                                                   PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(1)),
                                                   PaykitExchangeRate(price: "0", timestamp: now), PaykitExchangeRate(price: "NaN", timestamp: now)]
        for invalid in invalidRates {
            XCTAssertThrowsError(try amount.converted(to: .btc, rate: invalid, at: now))
            XCTAssertEqual(try amount.converted(to: .usdt, rate: invalid, at: now).value, "5")
        }
        XCTAssertEqual(
            try amount.converted(to: .btc, rate: PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-600)), at: now).value,
            "0.00005"
        )
    }

    func testParsingEnforcesPositiveExactDecimalsAndAtomicBounds() throws {
        for value in ["", "0", "-1", "+1", "1e2", "1,2", ".5", "5.", "0.0000001", "18446744073710"] {
            XCTAssertThrowsError(try PaykitAmount(asset: .usdt, value: value))
        }
        XCTAssertEqual(try PaykitAmount(asset: .usdt, value: "01.23000000").value, "1.23")
        XCTAssertEqual(try PaykitAmount(asset: .usdt, value: "18446744073709.551615").atomic, UInt64.max)
    }
}
