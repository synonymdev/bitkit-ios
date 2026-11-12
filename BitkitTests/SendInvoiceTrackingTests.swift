@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

@MainActor
final class SendInvoiceTrackingTests: XCTestCase {
    func testAPaymentRequestTracksItsInvoiceAcrossRailsButAContactsEndpointsDoNot() throws {
        let paymentHash = String(repeating: "ab", count: 32)
        let record = try paymentRequestRecord(endpointIdentifiers: [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue])
        let request = try PaykitPaymentRequest.parseIncoming(record: record, now: Date(), network: .regtest).get()

        let requestApp = AppViewModel()
        XCTAssertTrue(requestApp.claimContactPaymentContext(
            ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [])
        ))
        setUnifiedSend(requestApp, paymentHash: paymentHash)
        XCTAssertTrue(requestApp.tracksInvoiceAcrossRails)
        XCTAssertEqual(requestApp.scannedLightningPaymentHash, paymentHash)

        let contactApp = AppViewModel()
        XCTAssertTrue(contactApp.claimContactPaymentContext(ContactPaymentContext(publicKey: request.counterparty, endpoints: [])))
        setUnifiedSend(contactApp, paymentHash: paymentHash)
        XCTAssertFalse(contactApp.tracksInvoiceAcrossRails)
        XCTAssertNil(contactApp.scannedLightningPaymentHash)

        let scannedApp = AppViewModel()
        setUnifiedSend(scannedApp, paymentHash: paymentHash)
        XCTAssertTrue(scannedApp.tracksInvoiceAcrossRails)
        XCTAssertEqual(scannedApp.scannedLightningPaymentHash, paymentHash)
    }

    private func setUnifiedSend(_ app: AppViewModel, paymentHash: String) {
        app.scannedOnchainInvoice = OnChainInvoice(
            address: "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x", amountSatoshis: 0, label: nil, message: nil, params: nil
        )
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: "test-invoice", paymentHash: paymentHash.hexaData, amountSatoshis: 0, timestampSeconds: 0, expirySeconds: 0,
            isExpired: false, description: nil, networkType: .regtest, payeeNodeId: nil
        )
    }

    private func paymentRequestRecord(endpointIdentifiers: [String]) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: "pubky" + String(repeating: "y", count: 52),
            paymentRequestId: "71300000-0000-4000-8000-000000000001",
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "71300000-0000-4000-8000-000000000002",
            proposalAppId: "bitkit",
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: "btc"),
                paymentReference: PaymentReference(text: "order"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: endpointIdentifiers,
                paymentEndpoints: nil,
                requiredAppId: "bitkit",
                conversion: nil,
                paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2026-09-02T12:00:00Z",
            invalidReason: nil
        )
    }
}
