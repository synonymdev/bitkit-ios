@testable import Bitkit
import XCTest

@MainActor
final class SendSheetSyncWaitTests: XCTestCase {
    private let paymentHash = String(repeating: "cd", count: 32)

    func testSyncTimeoutFallsBackToOnchainOnlyBeforeASendWentOut() {
        let failure = SendRoute.failure(SendFailureContext(error: AppError(message: "failed", debugMessage: nil), retryRoute: .confirm))
        for route in postSendRoutes() {
            XCTAssertNil(SendSheet.syncTimeoutAction(route: route, isNodeRunning: true, isUnifiedInvoice: true), "\(route)")
            XCTAssertNil(SendSheet.syncTimeoutAction(route: route, isNodeRunning: false, isUnifiedInvoice: false), "\(route)")
        }
        for route in [SendRoute.amount, .confirm, .quickpay, failure] {
            XCTAssertEqual(SendSheet.syncTimeoutAction(route: route, isNodeRunning: true, isUnifiedInvoice: true), .fallBackToOnchain, "\(route)")
            XCTAssertEqual(
                SendSheet.syncTimeoutAction(route: route, isNodeRunning: false, isUnifiedInvoice: true), .showConnectionIssues, "\(route)"
            )
            XCTAssertEqual(
                SendSheet.syncTimeoutAction(route: route, isNodeRunning: true, isUnifiedInvoice: false), .showConnectionIssues, "\(route)"
            )
        }
    }

    func testValidationAfterSyncWaitsWhileConfirmSendsAndStopsOnceTheSendWentOut() {
        for route in [SendRoute.amount, .confirm, .quickpay] {
            XCTAssertTrue(SendSheet.canValidateAfterSync(route: route, isSubmittingPayment: false), "\(route)")
            XCTAssertFalse(SendSheet.canValidateAfterSync(route: route, isSubmittingPayment: true), "\(route)")
        }
        for route in postSendRoutes() {
            XCTAssertFalse(SendSheet.canValidateAfterSync(route: route, isSubmittingPayment: false), "\(route)")
        }
    }

    func testConfirmChecksTheInvoiceOnlyForAnOnchainSendOfAnAddressThatCameWithOne() async {
        let paymentHash = paymentHash
        let storeReads = StoreReads()
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true, spendableOnchainBalanceSats: 0, totalLightningBalanceSats: 0,
                        hasChannels: false, hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false },
                listPayments: {
                    storeReads.count += 1
                    return [AppViewModelTests.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)]
                }
            )
        )

        let lightning = await SendConfirmationView.onchainDispatchRefusal(
            walletType: .lightning, lightningPaymentHash: paymentHash, lightningPaymentStatus: app.lightningPaymentStatus
        )
        let addressAlone = await SendConfirmationView.onchainDispatchRefusal(
            walletType: .onchain, lightningPaymentHash: nil, lightningPaymentStatus: app.lightningPaymentStatus
        )
        XCTAssertNil(lightning)
        XCTAssertNil(addressAlone)
        XCTAssertEqual(storeReads.count, 0)

        let unifiedAddress = await SendConfirmationView.onchainDispatchRefusal(
            walletType: .onchain, lightningPaymentHash: paymentHash, lightningPaymentStatus: app.lightningPaymentStatus
        )
        XCTAssertEqual(unifiedAddress?.status, .pending)
    }

    private func postSendRoutes() -> [SendRoute] {
        let txid = String(repeating: "ab", count: 32)
        let context = OnchainSendPendingContext(attemptId: UUID(), walletId: WalletScope.default, txid: txid)
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "pubky" + String(repeating: "y", count: 52))
        return [
            .pending(paymentHash: paymentHash, retryRoute: .confirm, paymentRequest: nil),
            .success(paymentId: paymentHash),
            .recoveredSuccess(paymentId: paymentHash, walletId: WalletScope.default),
            .onchainPending(context),
            .onchainOperationPending(context, requestId: nil),
            .hardwarePending(requestId: requestId, walletId: "hardware", transactionId: txid, paymentIdentity: nil),
        ]
    }
}

private final class StoreReads {
    var count = 0
}
