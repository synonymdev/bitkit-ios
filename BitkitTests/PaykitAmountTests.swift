@testable import Bitkit
import Foundation
import XCTest

final class PaykitAmountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var rate: PaykitExchangeRate {
        PaykitExchangeRate(price: "100000", timestamp: now)
    }

    func testEditorAmountsKeepCentsAndExactSubCentPrecisionWithoutChangingWireAmounts() throws {
        let cases: [(PaykitAsset, String, String)] = [
            (.usd, "150.50", "150.50"), (.usdt, "150.50", "150.50"), (.usdt, "1", "1.00"),
            (.usdt, "0.000001", "0.000001"), (.usdt, "18446744073709.551615", "18446744073709.551615"),
            (.btc, "0.00000001", "0.00000001"),
        ]
        for (asset, value, expected) in cases {
            let amount = try PaykitAmount(asset: asset, value: value)
            XCTAssertEqual(amount.inputValue, expected)
            XCTAssertEqual(try PaykitAmount(asset: asset, value: amount.inputValue), amount)
        }
        XCTAssertEqual(try PaykitAmount(asset: .usdt, value: "150.50").value, "150.5")
    }

    func testUsdDisplayPreservesCentsAndMatchesFiatSeparatorsAcrossRegions() {
        for (cents, expected): (UInt64, String) in [
            (0, "0.00"), (1, "0.01"), (100, "1.00"), (15050, "150.50"), (123_456, "1,234.56"),
            (.max, "184,467,440,737,095,516.15"),
        ] {
            for identifier in ["en_US", "de_DE", "nl_NL", "fr_FR"] {
                let locale = Locale(identifier: identifier)
                XCTAssertEqual(usdDisplayAmount(cents, locale: locale), expected, identifier)
                XCTAssertEqual(usdDisplayAmount(cents, locale: locale), formatFiatAmount(Decimal(cents) / 100, locale: locale))
            }
        }
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
