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

    func testOnchainPaymentScopeRejectsLightning() {
        XCTAssertTrue(ShopPaymentRequest.isOnchainPayment(.onChain(invoice: onchainInvoice)))
        XCTAssertFalse(ShopPaymentRequest.isOnchainPayment(.lightning(invoice: lightningInvoice)))
    }

    func testNonPaymentRequestsDoNotClearExistingPaymentState() async {
        let app = AppViewModel()
        let requests = [
            "https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123",
            pubkySignupUrl,
        ]

        for request in requests {
            app.scannedLightningInvoice = lightningInvoice
            do {
                try await app.handleScannedData(request, scope: .paymentRequests)
                XCTFail("Expected the shop payment scope to reject a non-payment request")
            } catch {
                XCTAssertTrue(error is ScanHandlingError)
            }
            XCTAssertNotNil(app.scannedLightningInvoice)
        }
    }

    func testContactPaymentRejectsPubkySignupWithoutClearingSendState() async {
        let app = AppViewModel()
        let context = ContactPaymentContext(publicKey: "pubkycontact")
        XCTAssertTrue(app.claimContactPaymentContext(context))
        app.scannedLightningInvoice = lightningInvoice

        do {
            try await app.handleScannedData(pubkySignupUrl, claimedContactPaymentContext: context)
            XCTFail("Expected contact payment to reject Pubky signup")
        } catch {
            XCTAssertTrue(error is ScanHandlingError)
        }

        XCTAssertFalse(app.ownsContactPaymentContext(context))
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

    private var pubkySignupUrl: String {
        "pubkyring://signup?hs=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo" +
            "&relay=https%3A%2F%2Frelay.example%2Finbox%2F" +
            "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
            "&caps=%2Fpub%2Fexample%2F%3Arw"
    }

    private var onchainInvoice: OnChainInvoice {
        OnChainInvoice(
            address: "bcrt1qexample",
            amountSatoshis: 1000,
            label: nil,
            message: nil,
            params: ["lightning": "test-invoice"]
        )
    }
}
