@testable import Bitkit
import XCTest

@MainActor
final class TransferNavigationTests: XCTestCase {
    private let amountPath: [Route] = [.transferIntro, .fundingOptions, .spendingIntro, .spendingAmount]

    func testContinueOpensConfirmWhileAmountIsShown() {
        let navigation = NavigationViewModel()
        navigation.path = amountPath

        navigation.navigate(.spendingConfirm, from: amountPath)

        XCTAssertEqual(navigation.path, amountPath + [.spendingConfirm])
    }

    func testQuoteFinishingAfterBackKeepsTransferClosed() {
        let navigation = NavigationViewModel()
        navigation.path = amountPath

        // Back while the quote loads, then the quote returns.
        navigation.navigateBack()
        navigation.navigate(.spendingConfirm, from: amountPath)

        XCTAssertEqual(navigation.path, Array(amountPath.dropLast()))
    }

    func testQuoteFinishingAfterLeavingTransferKeepsItClosed() {
        let navigation = NavigationViewModel()
        navigation.path = amountPath

        navigation.reset()
        navigation.navigate(.spendingHwSign(walletId: "wallet"), from: amountPath)

        XCTAssertEqual(navigation.path, [])
    }
}
