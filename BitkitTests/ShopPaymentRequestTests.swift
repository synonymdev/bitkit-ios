@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class ShopPaymentRequestTests: XCTestCase {
    func testLightningInvoiceIsSupported() {
        XCTAssertTrue(ShopPaymentRequest.isSupported(.lightning(invoice: lightningInvoice)))
    }

    func testNonPaymentScannerDataIsRejected() {
        XCTAssertFalse(ShopPaymentRequest.isSupported(.gift(code: "gift-code", amount: 1000)))
        XCTAssertFalse(ShopPaymentRequest.isSupported(.pubkyAuth(data: "pubkyauth://example")))
    }

    func testNonPaymentRequestDoesNotClearExistingPaymentState() async {
        let app = AppViewModel()
        app.scannedLightningInvoice = lightningInvoice

        do {
            try await app.handleScannedData(
                "https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123",
                scope: .paymentRequests
            )
            XCTFail("Expected the shop payment scope to reject a setup request")
        } catch {
            XCTAssertTrue(error is ShopPaymentRequestError)
        }

        XCTAssertNotNil(app.scannedLightningInvoice)
    }

    private var lightningInvoice: LightningInvoice {
        LightningInvoice(
            bolt11: "test-invoice",
            paymentHash: Data(),
            amountSatoshis: 1000,
            timestampSeconds: 0,
            expirySeconds: 0,
            isExpired: false,
            description: nil,
            networkType: .regtest,
            payeeNodeId: nil
        )
    }
}
