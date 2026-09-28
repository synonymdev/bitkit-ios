@testable import Bitkit
import XCTest

@MainActor
final class TabBarReceiveTests: XCTestCase {
    func testSpendingReceiveUsesFreshVariableAmountCheck() {
        let wallet = WalletViewModel()
        wallet.channels = [
            .mock(isChannelReady: true, isUsable: true, inboundCapacityMsat: 50_000_000),
        ]
        wallet.invoiceAmountSats = 100_000

        XCTAssertFalse(wallet.canCreateReceiveLightningInvoice)
        XCTAssertTrue(wallet.canCreateReceiveLightningInvoice(amountSats: nil))
        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                wallet: wallet,
                hasPendingTransfersToSpending: false
            )
        )
    }

    func testSpendingReceiveOpensCjitOnlyWhenVariableLightningReceiveIsUnavailable() {
        let wallet = WalletViewModel()

        XCTAssertTrue(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                wallet: wallet,
                hasPendingTransfersToSpending: false
            )
        )

        wallet.channels = [
            .mock(isChannelReady: true, isUsable: true, inboundCapacityMsat: 1000),
        ]

        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                wallet: wallet,
                hasPendingTransfersToSpending: false
            )
        )
    }

    func testSpendingReceiveDoesNotOpenCjitOutsideSpendingWalletOrWithPendingTransfers() {
        let wallet = WalletViewModel()

        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: false,
                wallet: wallet,
                hasPendingTransfersToSpending: false
            )
        )

        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                wallet: wallet,
                hasPendingTransfersToSpending: true
            )
        )
    }
}
