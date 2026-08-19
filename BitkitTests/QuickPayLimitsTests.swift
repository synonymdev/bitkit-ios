@testable import Bitkit
import XCTest

final class QuickPayLimitsTests: XCTestCase {
    func testSanitizedMultiplierFallsBackToDefault() {
        XCTAssertEqual(QuickPayLimits.sanitizedMultiplier(5), 5)
        XCTAssertEqual(QuickPayLimits.sanitizedMultiplier(7), QuickPayLimits.defaultDailyMultiplier)
    }

    func testDailyCapUsdDisplayMultipliesThreshold() {
        XCTAssertEqual(QuickPayLimits.dailyCapUsdDisplay(thresholdUsd: 5, multiplier: 5), 25)
    }

    func testCapCentsUsesIntegerUsdAndMultiplier() {
        XCTAssertEqual(QuickPayLimits.capCents(thresholdUsd: 5, multiplier: 5), 2500)
        XCTAssertEqual(QuickPayLimits.reserveCents(convertedCents: 700, thresholdUsd: 5), 500)
        XCTAssertEqual(QuickPayLimits.reserveCents(convertedCents: 200, thresholdUsd: 5), 200)
    }

    func testAmountWithFeeSatsAddsFeeWithoutOverflow() {
        XCTAssertEqual(QuickPayLimits.amountWithFeeSats(amountSats: 1000, feePaidSats: 12), 1012)
        XCTAssertEqual(QuickPayLimits.amountWithFeeSats(amountSats: UInt64.max, feePaidSats: 1), UInt64.max)
    }
}
