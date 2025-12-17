@testable import Bitkit
import XCTest

final class LnurlAmountConversionTests: XCTestCase {
    func testSatsCeilRoundsUpWhenNotDivisibleBy1000() {
        XCTAssertEqual(LnurlAmountConversion.satsCeil(fromMsats: 100_500), 101)
        XCTAssertEqual(LnurlAmountConversion.satsCeil(fromMsats: 1500), 2)
    }

    func testSatsCeilKeepsExactSatAmounts() {
        XCTAssertEqual(LnurlAmountConversion.satsCeil(fromMsats: 100_000), 100)
        XCTAssertEqual(LnurlAmountConversion.satsCeil(fromMsats: 0), 0)
    }

    func testSatsFloorRoundsDown() {
        XCTAssertEqual(LnurlAmountConversion.satsFloor(fromMsats: 100_999), 100)
        XCTAssertEqual(LnurlAmountConversion.satsFloor(fromMsats: 100_000), 100)
    }
}
