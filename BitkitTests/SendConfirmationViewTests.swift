@testable import Bitkit
import LDKNode
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

    func testLightningFailureReleasesOnlyDefinitePreSubmissionAttempts() {
        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeForLightningFailure(
                paymentSubmitted: false,
                proofFailureWasDefinite: true
            ),
            .definitePreBroadcastFailure
        )
        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeForLightningFailure(
                paymentSubmitted: false,
                proofFailureWasDefinite: false
            ),
            .uncertain
        )
        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeForLightningFailure(
                paymentSubmitted: true,
                proofFailureWasDefinite: true
            ),
            .uncertain
        )
    }

    func testFinalFailureClassificationPreservesLightningOutcome() {
        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeAfterFailure(
                currentOutcome: .uncertain,
                walletType: .lightning,
                onchainPaymentStarted: false,
                error: NSError(domain: "payment", code: 1)
            ),
            .uncertain
        )
    }

    func testOnchainFailureReleasesOnlyDefinitePreBroadcastAttempts() {
        let uncertainError = NSError(domain: "payment", code: 1)

        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeAfterFailure(
                currentOutcome: .uncertain,
                walletType: .onchain,
                onchainPaymentStarted: false,
                error: uncertainError
            ),
            .definitePreBroadcastFailure
        )
        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeAfterFailure(
                currentOutcome: .uncertain,
                walletType: .onchain,
                onchainPaymentStarted: true,
                error: NodeError.InsufficientFunds(message: "insufficient funds")
            ),
            .definitePreBroadcastFailure
        )
        XCTAssertEqual(
            SendConfirmationView.privatePaymentListOutcomeAfterFailure(
                currentOutcome: .definitePreBroadcastFailure,
                walletType: .onchain,
                onchainPaymentStarted: true,
                error: uncertainError
            ),
            .uncertain
        )
    }
}
