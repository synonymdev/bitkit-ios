import BigNumber
@testable import Bitkit
import XCTest

final class SparkUsdTests: XCTestCase {
    func testRecognizesSparkAddressesAndInvoicesBeforeParsing() {
        XCTAssertTrue(SparkUsd.isSparkInput("sparkrt1pgssyuuuhnrrdjswal5c3s3rafw9w3y5dd4cuy3whr3f0zhs8hu"))
        XCTAssertTrue(SparkUsd.isSparkInput(" SPARK1abc"))
        XCTAssertFalse(SparkUsd.isSparkInput("lnbcrt1abc"))
        XCTAssertFalse(SparkUsd.isSparkInput("0x2d8a9f6c4c37a2f8b7f3a3b1d6c3c8f8d1a2b3c4"))
    }

    func testScalesTokenUnitsToDollarUnitsAndBack() {
        XCTAssertEqual(SparkUsd.toUsdUnits(BInt(1_500_000), decimals: 6), 1_500_000)
        XCTAssertEqual(SparkUsd.toUsdUnits(BInt(150_000_000), decimals: 8), 1_500_000)
        XCTAssertEqual(SparkUsd.fromUsdUnits(1_500_000, decimals: 8), BInt(150_000_000))
        XCTAssertEqual(SparkUsd.fromUsdUnits(1_500_000, decimals: 6), BInt(1_500_000))
    }

    func testRegtestHasADollarTokenAndOtherNetworksWaitForOne() {
        if Env.network == .regtest {
            XCTAssertEqual(Env.sparkUsdTokenId?.hasPrefix("btknrt1"), true)
        } else {
            XCTAssertNil(Env.sparkUsdTokenId)
        }
    }
}
