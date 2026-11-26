@testable import Bitkit
import XCTest

/// Where the Funding screen's hardware-wallet option starts Transfer to Spending once Spark is ready.
final class FundingHardwareTests: XCTestCase {
    private func wallet(_ id: String, sats: UInt64) -> HwWallet {
        HwWallet(id: id, walletId: id, name: id, model: nil, isConnected: false, balanceSats: sats)
    }

    func testNoPairedWalletHasNoRoute() {
        XCTAssertNil(FundingOptions.hardwareFundingRoute(wallets: [], hasSeenIntro: true))
    }

    func testFundedWalletIsChosenFirst() {
        let wallets = [wallet("empty", sats: 0), wallet("funded", sats: 5000)]
        XCTAssertEqual(FundingOptions.hardwareFundingRoute(wallets: wallets, hasSeenIntro: true), .spendingAmountHw(walletId: "funded"))
        XCTAssertEqual(FundingOptions.hardwareFundingRoute(wallets: wallets, hasSeenIntro: false), .spendingIntroHw(walletId: "funded"))
    }

    func testUnfundedWalletStillOpensItsTransfer() {
        XCTAssertEqual(
            FundingOptions.hardwareFundingRoute(wallets: [wallet("empty", sats: 0)], hasSeenIntro: true),
            .spendingAmountHw(walletId: "empty")
        )
    }
}
