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

    func testRetainedOrdinarySendLocksReviewToItsOriginalFee() {
        let signed = HwFundingSignedTx(serializedTx: "original", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)

        XCTAssertEqual(SendConfirmationView.confirmationFeeRate(retained: signed, selected: 99), 3)
        XCTAssertEqual(SendConfirmationView.confirmationFeeRate(retained: signed, selected: nil), 3)
        XCTAssertFalse(SendConfirmationView.canEditConfirmationFee(retained: signed, isLoading: false))
    }

    func testAbandoningARetainedSendFromALockedReviewShowsTheCurrentFeeBeforeSigning() {
        let signed = HwFundingSignedTx(serializedTx: "original", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)

        XCTAssertTrue(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: signed, rebroadcastTx: nil, abandonedRetainedSend: true
        ))
        // A record that could not be deleted still warns on the next swipe, which must come from the current fee.
        XCTAssertTrue(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: signed, rebroadcastTx: signed, abandonedRetainedSend: true
        ))
    }

    func testAbandoningARetainedSendFromAnUnlockedReviewGoesStraightToSigning() {
        XCTAssertFalse(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: nil, rebroadcastTx: nil, abandonedRetainedSend: true
        ))
    }

    func testLockedReviewSignsOnlyWhenItsBytesWouldBeRebroadcast() {
        let signed = HwFundingSignedTx(serializedTx: "original", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)
        let other = HwFundingSignedTx(serializedTx: "other", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)

        XCTAssertFalse(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: signed, rebroadcastTx: signed, abandonedRetainedSend: false
        ))
        for rebroadcastTx in [nil, other] {
            XCTAssertTrue(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
                reviewedRetainedTx: signed, rebroadcastTx: rebroadcastTx, abandonedRetainedSend: false
            ))
        }
        XCTAssertFalse(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: nil, rebroadcastTx: signed, abandonedRetainedSend: false
        ))
    }

    func testAmountScreenAcceptsOnlyTheRetainedAmountAboveTheCurrentMaximum() {
        let available: UInt64 = 90000
        let retained: UInt64 = 95000

        XCTAssertTrue(SendAmountView.isWithinSendableLimit(amountSats: retained, availableSats: available, retainedRetrySats: retained))
        XCTAssertTrue(SendAmountView.isWithinSendableLimit(amountSats: available, availableSats: available, retainedRetrySats: retained))
        XCTAssertFalse(SendAmountView.isWithinSendableLimit(amountSats: retained - 1, availableSats: available, retainedRetrySats: retained))
        XCTAssertFalse(SendAmountView.isWithinSendableLimit(amountSats: retained + 1, availableSats: available, retainedRetrySats: retained))
        XCTAssertFalse(SendAmountView.isWithinSendableLimit(amountSats: retained, availableSats: available, retainedRetrySats: nil))
    }

    func testAmountInputCapLetsTheRetainedAmountBeTyped() {
        XCTAssertEqual(SendAmountView.amountInputCap(availableSats: 90000, retainedRetrySats: 95000), 95000)
        XCTAssertEqual(SendAmountView.amountInputCap(availableSats: 90000, retainedRetrySats: 42000), 90000)
        XCTAssertEqual(SendAmountView.amountInputCap(availableSats: 90000, retainedRetrySats: nil), 90000)
        XCTAssertEqual(SendAmountView.amountInputCap(availableSats: 0, retainedRetrySats: 95000), 95000)
        XCTAssertNil(SendAmountView.amountInputCap(availableSats: 0, retainedRetrySats: nil))
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

    func testAutomaticPaymentStartsOnlyAfterSetupAndWalletSwitchFinish() {
        XCTAssertTrue(SendConfirmationView.canStartAutomaticPayment(
            shouldAutomaticallyPay: true, hasStartedAutomaticPayment: false, isSetupPending: false, isPreparingWallet: false
        ))
        XCTAssertFalse(SendConfirmationView.canStartAutomaticPayment(
            shouldAutomaticallyPay: true, hasStartedAutomaticPayment: false, isSetupPending: false, isPreparingWallet: true
        ))
        XCTAssertFalse(SendConfirmationView.canStartAutomaticPayment(
            shouldAutomaticallyPay: true, hasStartedAutomaticPayment: false, isSetupPending: true, isPreparingWallet: false
        ))
        XCTAssertFalse(SendConfirmationView.canStartAutomaticPayment(
            shouldAutomaticallyPay: true, hasStartedAutomaticPayment: true, isSetupPending: false, isPreparingWallet: false
        ))
        XCTAssertFalse(SendConfirmationView.canStartAutomaticPayment(
            shouldAutomaticallyPay: false, hasStartedAutomaticPayment: false, isSetupPending: false, isPreparingWallet: false
        ))
    }

    func testAutomaticPaymentAwaitsFeeRateOnlyWhileItIsLoading() {
        XCTAssertTrue(SendConfirmationView.automaticPaymentAwaitsFeeRate(isFeeRateMissing: true, feeRateLoadFailed: false))
        XCTAssertFalse(SendConfirmationView.automaticPaymentAwaitsFeeRate(isFeeRateMissing: true, feeRateLoadFailed: true))
        XCTAssertFalse(SendConfirmationView.automaticPaymentAwaitsFeeRate(isFeeRateMissing: false, feeRateLoadFailed: false))
    }

    func testAutomaticPaymentLacksFeeOnlyForOnchainWithoutCalculatedFee() {
        XCTAssertTrue(SendConfirmationView.automaticPaymentLacksFee(walletType: .onchain, transactionFee: 0))
        XCTAssertFalse(SendConfirmationView.automaticPaymentLacksFee(walletType: .onchain, transactionFee: 143))
        XCTAssertFalse(SendConfirmationView.automaticPaymentLacksFee(walletType: .lightning, transactionFee: 0))
    }

    func testManualCoinSelectionIsNeededOnlyForOnchainSavingsWithoutSelectedCoins() {
        func needs(_ walletType: WalletType, hardware: Bool = false, method: CoinSelectionMethod = .manual) -> Bool {
            SendConfirmationView.needsManualCoinSelection(
                walletType: walletType,
                isHardwarePayment: hardware,
                coinSelectionMethod: method,
                selectedUtxos: nil
            )
        }
        XCTAssertTrue(needs(.onchain))
        XCTAssertFalse(needs(.lightning))
        XCTAssertFalse(needs(.onchain, hardware: true))
        XCTAssertFalse(needs(.onchain, method: .autopilot))
        XCTAssertTrue(SendConfirmationView.needsManualCoinSelection(
            walletType: .onchain,
            isHardwarePayment: false,
            coinSelectionMethod: .manual,
            selectedUtxos: []
        ))
    }

    func testManuallyChosenCoinsAreDetectedOnlyForOnchainSavingsWithManualSelection() {
        func hasChosen(
            _ walletType: WalletType = .onchain, hardware: Bool = false, method: CoinSelectionMethod = .manual,
            utxos: [SpendableUtxo]?
        ) -> Bool {
            SendConfirmationView.hasManuallyChosenCoins(
                walletType: walletType,
                isHardwarePayment: hardware,
                coinSelectionMethod: method,
                selectedUtxos: utxos
            )
        }
        let utxo = SpendableUtxo(outpoint: OutPoint(txid: "00", vout: 0), valueSats: 1000)
        XCTAssertTrue(hasChosen(utxos: [utxo]))
        XCTAssertFalse(hasChosen(utxos: nil))
        XCTAssertFalse(hasChosen(utxos: []))
        XCTAssertFalse(hasChosen(.lightning, utxos: [utxo]))
        XCTAssertFalse(hasChosen(hardware: true, utxos: [utxo]))
        XCTAssertFalse(hasChosen(method: .autopilot, utxos: [utxo]))
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
