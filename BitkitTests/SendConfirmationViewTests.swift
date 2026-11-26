@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class SendConfirmationViewTests: XCTestCase {
    @MainActor
    func testFeeWarningsUseTheFeeOfThePreparedTransactionAfterAFeeIncrease() async throws {
        let service = OnchainSendAttemptService(store: MemoryAttemptStore())
        let sender = PreparedAttemptNodeMock()
        sender.amount = 1000
        sender.miningFee = 520
        let reviewedFee: UInt64 = 203
        XCTAssertEqual(SendConfirmationView.feeWarnings(feeSats: reviewedFee, amountSats: 1000, isOverUsdLimit: false), [])

        var reapproval: SendConfirmationView.FeeReapproval?
        do {
            _ = try await service.send(
                using: sender, address: "bcrt1qexample", amountSats: 1000, satsPerVbyte: 1, utxosToSpend: nil,
                isMaxAmount: false, reviewedMiningFeeSats: reviewedFee
            )
            XCTFail("A 520 sat transaction went out under a 203 sat approval")
        } catch let OnchainSendAttemptError.preDispatch(error) {
            let increased = try XCTUnwrap(error as? OnchainSendFeeIncreased)
            reapproval = .init(increased, address: "bcrt1qexample", requestedSats: 1000, isMaxAmount: false, feeRate: 1, utxos: nil)
        }
        let review = try XCTUnwrap(reapproval)
        XCTAssertEqual(review.miningFeeSats, 520)
        XCTAssertEqual(
            SendConfirmationView.feeWarnings(feeSats: review.miningFeeSats, amountSats: review.recipientAmountSats, isOverUsdLimit: false),
            [.feePercentage]
        )
        XCTAssertEqual(
            SendConfirmationView.feeWarnings(feeSats: review.miningFeeSats, amountSats: review.recipientAmountSats, isOverUsdLimit: true),
            [.fee, .feePercentage]
        )
    }

    @MainActor
    func testFeeRefusalIsIgnoredOnceItsSendWasClosedOrReplaced() {
        let presentation = UUID()
        XCTAssertTrue(SendConfirmationView.isFeeRefusalCurrent(
            presentationID: presentation, activePresentationID: presentation, address: "bcrt1qexample", currentAddress: "bcrt1qexample"
        ))
        let stale: [(UUID?, String?)] = [(nil, "bcrt1qexample"), (UUID(), "bcrt1qexample"), (presentation, nil), (presentation, "bcrt1qother")]
        for (active, address) in stale {
            XCTAssertFalse(SendConfirmationView.isFeeRefusalCurrent(
                presentationID: presentation, activePresentationID: active, address: "bcrt1qexample", currentAddress: address
            ))
        }
        XCTAssertFalse(SendConfirmationView.isFeeRefusalCurrent(
            presentationID: nil, activePresentationID: nil, address: "bcrt1qexample", currentAddress: "bcrt1qexample"
        ))
    }

    func testFeeReapprovalCoversOnlyThePaymentItsTransactionWasPreparedFor() {
        let utxo = SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "a", count: 64), vout: 0), valueSats: 20000)
        // A send-all's prepared transaction delivers less once its fee is higher, and that amount is the one reviewed.
        let increased = OnchainSendFeeIncreased(candidateTxid: String(repeating: "ab", count: 32), miningFeeSats: 212, recipientAmountSats: 19788)
        let review = SendConfirmationView.FeeReapproval(
            increased, address: "bcrt1qexample", requestedSats: 19797, isMaxAmount: true, feeRate: 1, utxos: [utxo]
        )
        XCTAssertTrue(review.covers(address: "bcrt1qexample", amountSats: 19788, feeRate: 1, utxos: [utxo]))
        XCTAssertFalse(review.covers(address: "bcrt1qother", amountSats: 19788, feeRate: 1, utxos: [utxo]))
        XCTAssertFalse(review.covers(address: "bcrt1qexample", amountSats: 19797, feeRate: 1, utxos: [utxo]))
        XCTAssertFalse(review.covers(address: "bcrt1qexample", amountSats: 19788, feeRate: 2, utxos: [utxo]))
        XCTAssertFalse(review.covers(address: "bcrt1qexample", amountSats: 19788, feeRate: nil, utxos: [utxo]))
        XCTAssertFalse(review.covers(address: "bcrt1qexample", amountSats: 19788, feeRate: 1, utxos: nil))
    }

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

    func testConsentingFromALockedReviewShowsTheCurrentFeeBeforeSigning() {
        let signed = HwFundingSignedTx(serializedTx: "original", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)

        XCTAssertTrue(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: signed, rebroadcastTx: nil, consentedToNewSignature: true
        ))
        // The record stays until the new bytes are signed, and that must not keep the review on the old fee.
        XCTAssertTrue(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: signed, rebroadcastTx: signed, consentedToNewSignature: true
        ))
    }

    func testConsentingFromAnUnlockedReviewGoesStraightToSigning() {
        XCTAssertFalse(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: nil, rebroadcastTx: nil, consentedToNewSignature: true
        ))
    }

    func testLockedReviewSignsOnlyWhenItsBytesWouldBeRebroadcast() {
        let signed = HwFundingSignedTx(serializedTx: "original", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)
        let other = HwFundingSignedTx(serializedTx: "other", miningFeeSats: 181, feeRate: 2.25, totalSpent: 42181)

        XCTAssertFalse(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: signed, rebroadcastTx: signed, consentedToNewSignature: false
        ))
        for rebroadcastTx in [nil, other] {
            XCTAssertTrue(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
                reviewedRetainedTx: signed, rebroadcastTx: rebroadcastTx, consentedToNewSignature: false
            ))
        }
        XCTAssertFalse(SendConfirmationView.mustReviewCurrentFeeBeforeSigning(
            reviewedRetainedTx: nil, rebroadcastTx: signed, consentedToNewSignature: false
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

    func testARouteRefusedWhenConfirmOpensKeepsTheSwipeAndTheAutomaticPaymentOff() {
        // Confirm's first routing call keeps a refusal the way a source switch does.
        let refused = SendConfirmationView.refusedRouteSource(after: .refused, on: .lightning, previous: nil)

        XCTAssertFalse(SendConfirmationView.canStartAutomaticPayment(
            shouldAutomaticallyPay: true,
            hasStartedAutomaticPayment: false,
            isSetupPending: false,
            isPreparingWallet: false,
            isRouteRefused: refused == .lightning
        ), "an automatic attempt must not pay a source the router refused")
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .lightning,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5,
            isRouteRefused: refused == .lightning
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

    func testSwapRouteWarningsReadTheQuoteDebitPaidFromSpending() {
        let endpoint = PaykitEndpoint(methodId: "bitcoin", value: "bcrt1qcontact")
        var route = PaykitSwapRoute(endpoint: endpoint)
        XCTAssertEqual(SendConfirmationView.swapRouteWarningAmountSats(route, sendAmountSats: 50000), 50000)
        XCTAssertEqual(SendConfirmationView.swapRouteWarningAmountSats(route, sendAmountSats: nil), 0)
        route.quote = PubkySwapRouteQuote(
            providerPubky: "provider", quoteId: "quote", endpoint: endpoint, deliveredSat: 50000, lockSat: 50300, debitSat: 51200,
            serviceFeeSat: 500, providerOnchainFeeSat: 400, claimFeeSat: 300, totalFeeSat: 1200, atomicity: "hold_invoice",
            validUntilUnix: 0, providersQuoted: 1
        )
        XCTAssertEqual(SendConfirmationView.swapRouteWarningAmountSats(route, sendAmountSats: 50000), 51200)
    }

    func testSwapRouteResultReachesOnlyTheSheetThatStartedIt() {
        let started = UUID()
        func isCurrent(_ start: UUID?, _ active: UUID?) -> Bool {
            SendConfirmationView.isSwapRouteResultCurrent(startedIn: start, active: active, quoteId: "quote", activeQuoteId: "quote")
        }
        XCTAssertTrue(isCurrent(started, started))
        XCTAssertFalse(isCurrent(started, UUID()))
        XCTAssertFalse(isCurrent(started, nil))
        XCTAssertFalse(isCurrent(nil, nil))
    }

    func testSwapRouteResultSkipsAPaymentEditedInTheSameSheet() {
        let sheet = UUID()
        func isCurrent(_ activeQuoteId: String?) -> Bool {
            SendConfirmationView.isSwapRouteResultCurrent(startedIn: sheet, active: sheet, quoteId: "quote", activeQuoteId: activeQuoteId)
        }
        XCTAssertFalse(isCurrent("edited-quote"))
        XCTAssertFalse(isCurrent(nil))
    }

    func testOnlyAFailedSwapEndsASentHoldPayment() {
        let electrumError = AppError(message: "electrum", debugMessage: nil)
        XCTAssertTrue(SendConfirmationView.isDefiniteSwapFailure(PubkySwapClaimError.failed("lockup expired")))
        XCTAssertFalse(SendConfirmationView.isDefiniteSwapFailure(PubkySwapClaimError.timedOut(electrumError)))
        XCTAssertFalse(SendConfirmationView.isDefiniteSwapFailure(CancellationError()))
        XCTAssertFalse(SendConfirmationView.isDefiniteSwapFailure(electrumError))
    }

    func testASparkLegThatMayHaveSentStaysPendingInsteadOfOfferingTryAgain() {
        struct Refused: Error {}
        struct Lost: Error {}
        let attempt = SparkWithdrawalAttempt(
            address: "bcrt1qcontact",
            amountSats: 20000,
            requestId: PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "payee")
        )

        let unresolved = SendConfirmationView.serviceLegFailureRoute(Lost(), attempt: attempt, routingCacheResetAttempted: false)
        XCTAssertEqual(
            unresolved,
            .sparkWithdrawalPending(attempt),
            "Spark may have sent it, so the screen follows its journal until it settles"
        )

        let refused = SendConfirmationView.serviceLegFailureRoute(
            SparkWithdrawalNotSent(underlying: Refused()),
            attempt: attempt,
            routingCacheResetAttempted: false
        )
        guard case .failure = refused else { return XCTFail("A leg Spark refused before sending can be tried again") }
    }

    func testRepayingAnInvoiceShowsTheAmountItsEarlierSendPaid() throws {
        let earlier = Self.sentLightning(invoice: "lnbcrt1amountless", value: 1000, status: .succeeded)
        XCTAssertEqual(try SendConfirmationView.earlierLightningSendSats(earlier, bolt11: "LNBCRT1AMOUNTLESS"), 1000)
        XCTAssertNil(try SendConfirmationView.earlierLightningSendSats(nil, bolt11: "lnbcrt1amountless"))
    }

    func testRepayingAnInvoiceWhoseEarlierSendFailedPaysNormally() throws {
        let earlier = Self.sentLightning(invoice: "lnbcrt1failed", value: 1000, status: .failed)
        XCTAssertNil(try SendConfirmationView.earlierLightningSendSats(earlier, bolt11: "lnbcrt1failed"))
    }

    func testAnInvoiceSharingThePaymentHashOfAnotherPaidInvoiceIsRefusedAsPaid() {
        let earlier = Self.sentLightning(invoice: "lnbcrt1otherpayee", value: 1000, status: .succeeded)
        XCTAssertThrowsError(try SendConfirmationView.earlierLightningSendSats(earlier, bolt11: "lnbcrt1samehash")) {
            XCTAssertEqual(sendFailureMessage(for: $0), t("wallet__send_quickpay__already_paid"))
        }
    }

    private static func sentLightning(invoice: String, value: UInt64, status: PaymentState) -> Activity {
        .lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "hash",
                txType: .sent,
                status: status,
                value: value,
                fee: 0,
                invoice: invoice,
                message: "",
                timestamp: 0,
                preimage: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )
    }
}
