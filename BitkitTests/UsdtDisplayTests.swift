@testable import Bitkit
import Foundation
import XCTest

final class UsdtDisplayTests: XCTestCase {
    func testBitcoinEquivalentRequiresFreshRateAndFitsDisplayBounds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rate = PaykitExchangeRate(price: "100000", timestamp: now)
        XCTAssertEqual(usdtDisplaySats(amount: "3.5", rate: rate, now: now), 3500)
        XCTAssertEqual(usdtDisplaySats(amount: "0.000001", rate: rate, now: now), 0)
        XCTAssertNil(usdtDisplaySats(amount: "3.5", rate: nil, now: now))
        XCTAssertNil(usdtDisplaySats(amount: "3.5", rate: PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-601)), now: now))
        XCTAssertNil(usdtDisplaySats(amount: "-1", rate: rate, now: now))
        XCTAssertNil(usdtDisplaySats(amount: "999999999999999999999999", rate: rate, now: now))
    }

    func testSmallNonzeroBalancesRemainVisible() {
        XCTAssertEqual(usdtOverviewAmount(0), "0")
        XCTAssertEqual(usdtOverviewAmount(1), "<0.01")
        XCTAssertEqual(usdtOverviewAmount(9999), "<0.01")
    }
}
