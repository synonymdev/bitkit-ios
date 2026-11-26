@testable import Bitkit
import LDKNode
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

    func testSavingsTransferWithOnlySparkSkipsAvailability() {
        let navigation = NavigationViewModel()
        let transfer = TransferViewModel()
        transfer.isSparkSelected = false

        navigation.navigateToTransferSavings(isSparkOnly: true, transfer: transfer)

        XCTAssertEqual(navigation.path, [.savingsConfirm])
        XCTAssertTrue(transfer.isSparkSelected, "the transfer starts over from moving everything")
    }

    func testSavingsTransferWithAChannelOpensAvailability() {
        let navigation = NavigationViewModel()
        let transfer = TransferViewModel()
        transfer.isSparkSelected = false

        navigation.navigateToTransferSavings(isSparkOnly: false, transfer: transfer)

        XCTAssertEqual(navigation.path, [.savingsAvailability])
        XCTAssertFalse(transfer.isSparkSelected, "Availability starts the transfer on Continue")
    }

    func testSparkOnlyNeedsARunningNodeWithNoOpenChannelAndASparkBalance() {
        let pending = ChannelDetails.mock(isChannelReady: false)
        let open = ChannelDetails.mock(isChannelReady: true)

        XCTAssertTrue(NavigationViewModel.isSparkOnly(nodeLifecycleState: .running, channels: [], sparkSpendingSats: 1000))
        XCTAssertTrue(NavigationViewModel.isSparkOnly(nodeLifecycleState: .running, channels: [pending], sparkSpendingSats: 1000))
        XCTAssertFalse(NavigationViewModel.isSparkOnly(nodeLifecycleState: .running, channels: [open], sparkSpendingSats: 1000))
        XCTAssertFalse(NavigationViewModel.isSparkOnly(nodeLifecycleState: .running, channels: [], sparkSpendingSats: 0))
        XCTAssertFalse(
            NavigationViewModel.isSparkOnly(nodeLifecycleState: .running, channels: nil, sparkSpendingSats: 1000),
            "channels are unknown until they load"
        )
        XCTAssertFalse(
            NavigationViewModel.isSparkOnly(nodeLifecycleState: .starting, channels: [], sparkSpendingSats: 1000),
            "channels are unknown until the node runs"
        )
    }

    func testAStartedForceTransferOpensItsProgressAboveTheSparkConnection() {
        let navigation = NavigationViewModel()
        navigation.path = [.connections, .sparkConnectionDetail, .sparkExitIntro, .sparkExitQuote, .sparkExitFunding, .sparkExitPay]

        navigation.openSparkExitProgress()

        XCTAssertEqual(navigation.path, [.connections, .sparkConnectionDetail, .sparkExitProgress])
    }
}
