@testable import Bitkit
import Foundation
import XCTest

@MainActor
final class HomeWalletBalanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var rate: PaykitExchangeRate {
        PaykitExchangeRate(price: "100000", timestamp: now)
    }

    func testTotalUsesCachedRatesWhilePaymentConversionsRequireFreshRates() {
        XCTAssertNil(total(balance: nil, rate: rate))
        XCTAssertNil(total(balance: 1_000_000_000, rate: nil))
        let oldRate = PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-3600))
        XCTAssertEqual(total(balance: 1_000_000_000, rate: oldRate), 1_150_000)
        XCTAssertThrowsError(try oldRate.value(at: now))
        XCTAssertNil(total(balance: 1_000_000_000, rate: PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(1))))
        XCTAssertNil(total(balance: 1_000_000_000, rate: PaykitExchangeRate(price: "0", timestamp: now)))
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

    func testUpdatingRemainsVisibleUntilBalanceAndRatesFinish() {
        let cachedRate = PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-300))
        func updating(_ balanceRefreshing: Bool, _ rateRefreshing: Bool) -> Bool {
            HomeWalletView.isBalanceUpdating(balance: 1_000_000, refreshing: balanceRefreshing, balanceIsStale: false,
                                             rate: cachedRate, rateRefreshing: rateRefreshing, now: now)
        }
        XCTAssertTrue(updating(true, true))
        XCTAssertTrue(updating(false, true))
        XCTAssertFalse(updating(false, false))
    }

    func testFailedBalanceReadKeepsPreviousBalanceUpdating() {
        XCTAssertTrue(HomeWalletView.isBalanceUpdating(balance: 1_000_000, refreshing: false, balanceIsStale: true,
                                                       rate: rate, rateRefreshing: false, now: now))
        XCTAssertFalse(HomeWalletView.isBalanceUpdating(balance: 1_000_000, refreshing: false, balanceIsStale: false,
                                                        rate: rate, rateRefreshing: false, now: now))
        XCTAssertTrue(HomeWalletView.isBalanceUpdating(balance: nil, refreshing: false, balanceIsStale: false,
                                                       rate: rate, rateRefreshing: false, now: now))
    }

    private func total(balance: UInt64?, rate: PaykitExchangeRate?) -> Int? {
        HomeWalletView.aggregateBalance(bitcoinSats: 100_000, hardwareSats: 50000, includesUsdt: true,
                                        usdtBalance: balance, rate: rate, now: now)
    }
}
