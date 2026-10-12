@testable import Bitkit
import LDKNode
import XCTest

final class SendConfirmationViewTests: XCTestCase {
    func testLightningPaymentRejectsAmountsThatDifferFromTheFixedInvoice() async throws {
        for (invoiceAmount, reviewedAmount, expectedSend) in [(10000, 1000, false), (10000, 10000, true), (0, 1000, true)] {
            var sent = false
            do {
                try await SendConfirmationView.sendLightningPayment(
                    invoiceAmountSats: UInt64(invoiceAmount),
                    reviewedAmountSats: UInt64(reviewedAmount),
                    request: nil,
                    authorize: { _ in },
                    onAuthorizationFailure: { _ in }
                ) { sent = true }
                XCTAssertTrue(expectedSend)
            } catch {
                XCTAssertFalse(expectedSend)
                XCTAssertEqual(error as? PaykitPaymentRequestError, .amountMismatch)
            }
            XCTAssertEqual(sent, expectedSend)
        }
    }

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
