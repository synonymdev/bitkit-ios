@testable import Bitkit
import Foundation
import XCTest

@MainActor
final class HomeWalletBalanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var rate: PaykitExchangeRate {
        PaykitExchangeRate(price: "100000", timestamp: now)
    }

    func testTotalIsUnavailableUntilVisibleUsdtHasABalanceAndFreshRate() {
        XCTAssertNil(total(balance: nil, rate: rate))
        XCTAssertNil(total(balance: 1_000_000_000, rate: nil))
        XCTAssertNil(total(balance: 1_000_000_000, rate: PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-601))))
        XCTAssertEqual(total(balance: 1_000_000_000, rate: rate), 1_150_000)
    }

    func testKnownZeroAndHiddenUsdtDoNotRequireAnExchangeRate() {
        XCTAssertEqual(total(balance: 0, rate: nil), 150_000)
        XCTAssertEqual(HomeWalletView.aggregateBalance(bitcoinSats: 100_000, hardwareSats: 50000, includesUsdt: false,
                                                       usdtBalance: nil, rate: nil, now: now), 150_000)
    }

    func testLargeCombinedBalanceSaturatesWithoutOverflow() {
        XCTAssertEqual(HomeWalletView.aggregateBalance(bitcoinSats: Int.max, hardwareSats: UInt64.max, includesUsdt: true,
                                                       usdtBalance: 1_000_000, rate: rate, now: now), Int.max)
    }

    private func total(balance: UInt64?, rate: PaykitExchangeRate?) -> Int? {
        HomeWalletView.aggregateBalance(bitcoinSats: 100_000, hardwareSats: 50000, includesUsdt: true,
                                        usdtBalance: balance, rate: rate, now: now)
    }
}
