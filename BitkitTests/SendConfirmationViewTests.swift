@testable import Bitkit
import LDKNode
import XCTest

final class SendConfirmationViewTests: XCTestCase {
    func testRetainedHardwareConfirmationLocksSignedFeeRateDespitePresetEdits() {
        let signed = HwFundingSignedTx(serializedTx: "original", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)
        for preset: UInt32? in [1, 17, 99, nil] {
            XCTAssertEqual(SendConfirmationView.confirmationFeeRate(retained: signed, selected: preset), 3)
            XCTAssertFalse(SendConfirmationView.canEditConfirmationFee(retained: signed, isLoading: false))
        }
        XCTAssertEqual(SendConfirmationView.confirmationFeeRate(retained: nil, selected: 17), 17)
        XCTAssertTrue(SendConfirmationView.canEditConfirmationFee(retained: nil, isLoading: false))
        XCTAssertFalse(SendConfirmationView.canEditConfirmationFee(retained: nil, isLoading: true))
    }

    func testAutomaticPaymentRequiresManualConfirmationOnlyForHardwareFunding() {
        for isHardwarePayment in [false, true] {
            XCTAssertEqual(
                SendConfirmationView.requiresManualConfirmation(
                    isAutomatic: true,
                    isHardwarePayment: isHardwarePayment
                ),
                isHardwarePayment
            )
            XCTAssertFalse(SendConfirmationView.requiresManualConfirmation(
                isAutomatic: false,
                isHardwarePayment: isHardwarePayment
            ))
        }
    }

    func testAutomaticPaymentLacksFeeOnlyForOnchainWithoutCalculatedFee() {
        XCTAssertTrue(SendConfirmationView.automaticPaymentLacksFee(walletType: .onchain, transactionFee: 0))
        XCTAssertFalse(SendConfirmationView.automaticPaymentLacksFee(walletType: .onchain, transactionFee: 143))
        XCTAssertFalse(SendConfirmationView.automaticPaymentLacksFee(walletType: .lightning, transactionFee: 0))
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
                error: OnchainSendAttemptError.preDispatch(NodeError.InsufficientFunds(message: "insufficient funds"))
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
