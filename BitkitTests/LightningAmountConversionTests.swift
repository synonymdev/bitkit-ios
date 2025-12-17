@testable import Bitkit
import XCTest

final class LightningAmountConversionTests: XCTestCase {
    func testSatsCeilRoundsUpWhenNotDivisibleBy1000() {
        XCTAssertEqual(LightningAmountConversion.satsCeil(fromMsats: 100_500), 101)
        XCTAssertEqual(LightningAmountConversion.satsCeil(fromMsats: 1500), 2)
    }

    func testSatsCeilKeepsExactSatAmounts() {
        XCTAssertEqual(LightningAmountConversion.satsCeil(fromMsats: 100_000), 100)
        XCTAssertEqual(LightningAmountConversion.satsCeil(fromMsats: 0), 0)
    }

    func testSatsFloorRoundsDown() {
        XCTAssertEqual(LightningAmountConversion.satsFloor(fromMsats: 100_999), 100)
        XCTAssertEqual(LightningAmountConversion.satsFloor(fromMsats: 100_000), 100)
        XCTAssertEqual(LightningAmountConversion.satsFloor(fromMsats: 0), 0)
    }
}
