@testable import Bitkit
import XCTest

final class SendConfirmationViewTests: XCTestCase {
    func testAutomaticPaymentRequiresManualConfirmationForNonLightningFunding() {
        for walletType in [WalletType.lightning, .onchain] {
            for isHardwarePayment in [false, true] {
                XCTAssertEqual(
                    SendConfirmationView.requiresManualConfirmation(
                        isAutomatic: true,
                        walletType: walletType,
                        isHardwarePayment: isHardwarePayment
                    ),
                    walletType == .onchain || isHardwarePayment
                )
                XCTAssertFalse(SendConfirmationView.requiresManualConfirmation(
                    isAutomatic: false,
                    walletType: walletType,
                    isHardwarePayment: isHardwarePayment
                ))
            }
        }
    }
}
