@testable import Bitkit
import XCTest

final class TabBarReceiveTests: XCTestCase {
    func testSpendingReceiveOpensCjitOnlyWhenVariableLightningReceiveIsUnavailable() {
        XCTAssertTrue(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                canCreateVariableLightningInvoice: false,
                hasPendingTransfersToSpending: false
            )
        )

        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                canCreateVariableLightningInvoice: true,
                hasPendingTransfersToSpending: false
            )
        )
    }

    func testSpendingReceiveDoesNotOpenCjitOutsideSpendingWalletOrWithPendingTransfers() {
        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: false,
                canCreateVariableLightningInvoice: false,
                hasPendingTransfersToSpending: false
            )
        )

        XCTAssertFalse(
            TabBar.shouldOpenSpendingCjitEntry(
                isSpendingWallet: true,
                canCreateVariableLightningInvoice: false,
                hasPendingTransfersToSpending: true
            )
        )
    }
}
