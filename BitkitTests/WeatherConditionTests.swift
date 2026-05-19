@testable import Bitkit
import XCTest

// MARK: - FeeCondition.evaluate

final class FeeConditionEvaluateTests: XCTestCase {
    /// Native-segwit transaction size used for the USD threshold check.
    private static let vBytesSize = 140
    /// $1 USD threshold below which the widget is always "Favorable".
    private static let usdGoodThreshold = 1.0
    /// Plausible mainnet BTC/USD rate. The tests only care that values are above/below the
    /// $1 threshold; the exact number doesn't matter.
    private static let usdPerBtc = 100_000.0

    private static let percentile = FeePercentile(lowThreshold: 5, highThreshold: 50)

    func testEvaluate_UsdThresholdReturnsGood() {
        // 1 sat/vB × 140 vB at $100k/BTC ≈ $0.14 → ≤ $1 → .good regardless of percentile
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 100,
            totalSats: 1 * Self.vBytesSize,
            usdPerBtc: Self.usdPerBtc,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .good)
    }

    func testEvaluate_UsdAboveOneFallsThroughToPercentile_Good() {
        // 4 sat/vB × 140 vB at $100k/BTC ≈ $0.56 — under threshold so USD branch returns .good.
        // Pick numbers that are clearly above $1: 100 sat/vB total → ~$14.
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 4, // below low threshold (5)
            totalSats: 100 * Self.vBytesSize,
            usdPerBtc: Self.usdPerBtc,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .good)
    }

    func testEvaluate_NoUsdRateFallsThroughToPercentile_Average() {
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 20, // between low (5) and high (50)
            totalSats: 20 * Self.vBytesSize,
            usdPerBtc: nil,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .average)
    }

    func testEvaluate_MidRateAboveHighThresholdReturnsPoor() {
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 60, // above high threshold (50)
            totalSats: 60 * Self.vBytesSize,
            usdPerBtc: Self.usdPerBtc,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .poor)
    }

    func testEvaluate_MidRateBelowLowThresholdReturnsGood() {
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 3, // below low threshold (5)
            totalSats: 50 * Self.vBytesSize, // ~$7 — above $1, so falls to percentile
            usdPerBtc: Self.usdPerBtc,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .good)
    }

    func testEvaluate_MidRateBetweenThresholdsReturnsAverage() {
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 20, // between low (5) and high (50)
            totalSats: 20 * Self.vBytesSize,
            usdPerBtc: Self.usdPerBtc,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .average)
    }

    func testEvaluate_MissingPercentileReturnsAverage() {
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 100,
            totalSats: 100 * Self.vBytesSize,
            usdPerBtc: Self.usdPerBtc,
            percentile: nil
        )
        XCTAssertEqual(condition, .average)
    }

    func testEvaluate_ZeroUsdPerBtcIgnoresUsdCheck() {
        // Zero rate means the USD branch must be skipped, falling through to the percentile.
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 20, // between low (5) and high (50)
            totalSats: 20 * Self.vBytesSize,
            usdPerBtc: 0,
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .average)
    }

    func testEvaluate_BoundaryAtLowThresholdReturnsGood() {
        // Equal to low threshold → Good (`<=`).
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 5,
            totalSats: 5 * Self.vBytesSize,
            usdPerBtc: nil, // bypass USD branch
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .good)
    }

    func testEvaluate_BoundaryAtHighThresholdReturnsPoor() {
        // Equal to high threshold → Poor (`>=`).
        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: 50,
            totalSats: 50 * Self.vBytesSize,
            usdPerBtc: nil, // bypass USD branch
            percentile: Self.percentile
        )
        XCTAssertEqual(condition, .poor)
    }
}

// MARK: - FeePercentile.init(history:)

final class FeePercentileInitTests: XCTestCase {
    func testInit_EmptyHistoryReturnsNil() {
        XCTAssertNil(FeePercentile(history: []))
    }

    func testInit_ComputesPercentiles() {
        // Sorted values [0, 1, 2, ..., 99] → 33rd-percentile index = floor(100 * 0.33) = 33,
        // 66th-percentile index = 66. Production code uses `Int(Double(n) * percentile)` which
        // truncates toward zero — keep this assertion aligned with that exact indexing.
        let history = (0 ..< 100).map { makeRates(avgFee50: Double($0)) }
        let percentile = FeePercentile(history: history)
        XCTAssertEqual(percentile?.lowThreshold, 33)
        XCTAssertEqual(percentile?.highThreshold, 66)
    }

    func testInit_UnsortedInputProducesSortedThresholds() {
        // Same values as the previous test, just shuffled — thresholds must be computed from
        // sorted order so they should match exactly.
        let values: [Double] = (0 ..< 100).map(Double.init).shuffled()
        let history = values.map { makeRates(avgFee50: $0) }
        let percentile = FeePercentile(history: history)
        XCTAssertEqual(percentile?.lowThreshold, 33)
        XCTAssertEqual(percentile?.highThreshold, 66)
    }

    func testInit_SingleSampleProducesSameLowAndHighThreshold() {
        let history = [makeRates(avgFee50: 7.5)]
        let percentile = FeePercentile(history: history)
        XCTAssertEqual(percentile?.lowThreshold, 7.5)
        XCTAssertEqual(percentile?.highThreshold, 7.5)
    }

    // MARK: - Helpers

    private func makeRates(avgFee50: Double) -> BlockFeeRates {
        BlockFeeRates(
            avgHeight: 0,
            timestamp: 0,
            avgFee_0: 0,
            avgFee_10: 0,
            avgFee_25: 0,
            avgFee_50: avgFee50,
            avgFee_75: 0,
            avgFee_90: 0,
            avgFee_100: 0
        )
    }
}
