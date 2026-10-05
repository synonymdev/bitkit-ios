@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class ReceiveSheetSessionTests: XCTestCase {
    func testReceiveSheetItemGetsFreshIdentityPerPresentation() {
        let sheets = SheetViewModel()

        sheets.showSheet(.receive)
        let firstID = sheets.receiveSheetItem?.id

        sheets.hideSheet(reason: "test")
        sheets.showSheet(.receive)
        let secondID = sheets.receiveSheetItem?.id

        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
    }

    func testPaykitRoutesDoNotRequireInvoiceRefresh() {
        let draft = PaykitPaymentRequestDraft(amountSats: 1000, note: "Lunch", expiresAt: Date(timeIntervalSince1970: 86400))
        let target = PaykitPaymentRequestTarget(publicKey: "pubkycontact")
        let routes: [ReceiveRoute] = [
            .requestOrPay(publicKey: target.publicKey),
            .paymentRequestRecipient(draft),
            .paymentRequestAmount(draft, target),
            .paymentRequestDetails(draft, target),
            .paymentRequestSent(sentRequest(draft: draft, target: target)),
        ]

        for route in routes {
            XCTAssertFalse(route.requiresInvoiceRefresh, "\(route)")
        }
    }

    func testReceiveRoutesRequireInvoiceRefresh() {
        let routes: [ReceiveRoute] = [
            .qr(cjitInvoice: nil, tab: nil),
            .qr(cjitInvoice: "cjit-invoice", tab: .spending),
            .qr(cjitInvoice: nil, tab: .hardware),
            .edit(tab: .spending, onchainOnly: false),
            .edit(tab: .hardware, onchainOnly: true),
            .tag,
            .cjitAmount,
            .cjitConfirm(entry: .mock(), receiveAmountSats: 1000, isAdditional: false),
            .cjitLearnMore(entry: .mock(), receiveAmountSats: 1000, isAdditional: false),
            .cjitGeoBlocked,
        ]

        for route in routes {
            XCTAssertTrue(route.requiresInvoiceRefresh, "\(route)")
        }
    }

    private func sentRequest(draft: PaykitPaymentRequestDraft, target: PaykitPaymentRequestTarget) -> PaykitPaymentRequest {
        let record = PaymentRequestRecord(
            counterparty: target.publicKey,
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440000",
            localRole: .payee,
            state: .proposed,
            proposalStreamItemId: nil,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: nil,
            proposalAppId: "bitkit",
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: nil,
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
            paymentProofs: [],
            lastStreamItemId: nil,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: nil,
            invalidReason: nil
        )
        return PaykitPaymentRequest(
            createdRecord: record,
            draft: draft,
            target: target,
            acceptedPaymentEndpointIdentifiers: ["btc-regtest-p2wpkh"],
            deliveryStatus: .sent,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
