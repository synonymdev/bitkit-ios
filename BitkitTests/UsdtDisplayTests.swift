@testable import Bitkit
import Foundation
import XCTest

final class UsdtDisplayTests: XCTestCase {
    func testExactAmountsPreserveTokenPrecisionAcrossRegions() {
        for identifier in ["en_US", "de_DE", "nl_NL", "fr_FR"] {
            let locale = Locale(identifier: identifier)
            for (amount, expected): (UInt64, String) in [
                (0, "0.00"), (1, "0.000001"), (4_996_000, "4.996"), (1_234_567, "1.234567"),
                (3_500_000, "3.50"), (.max, "18,446,744,073,709.551615"),
            ] {
                XCTAssertEqual(usdtExactAmount(amount, locale: locale), expected, identifier)
            }
        }
    }

    func testBitcoinEquivalentRequiresFreshRateAndFitsDisplayBounds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rate = PaykitExchangeRate(price: "100000", timestamp: now)
        XCTAssertEqual(usdtDisplaySats(amount: "3.5", rate: rate, now: now), 3500)
        XCTAssertEqual(usdtDisplaySats(amount: "0.000001", rate: rate, now: now), 0)
        XCTAssertNil(usdtDisplaySats(amount: "3.5", rate: nil, now: now))
        XCTAssertNil(usdtDisplaySats(amount: "3.5", rate: PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-601)), now: now))
        XCTAssertNil(usdtDisplaySats(amount: "—", rate: rate, now: now))
        XCTAssertNil(usdtDisplaySats(amount: "-1", rate: rate, now: now))
        XCTAssertNil(usdtDisplaySats(amount: "999999999999999999999999", rate: rate, now: now))
    }

    func testOverviewAmountsRoundToCentsWithoutHidingSmallBalances() {
        for (amount, expected): (UInt64, String) in [
            (0, "0.00"), (1, "<0.01"), (9999, "<0.01"), (10000, "0.01"), (10_000_000, "10.00"),
            (123_456_789, "123.46"), (1_025_000, "1.03"), (1_234_567_890, "1,234.57"),
        ] {
            for identifier in ["en_US", "de_DE", "nl_NL", "fr_FR"] {
                XCTAssertEqual(usdtOverviewAmount(amount, locale: Locale(identifier: identifier)), expected, identifier)
            }
        }
    }
}
