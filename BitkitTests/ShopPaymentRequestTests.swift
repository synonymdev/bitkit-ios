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
            directPubkySignupUrl,
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

    func testWrappedPubkyRequestsAreRejectedBeforeClearingSendState() async {
        let sheets = SheetViewModel()
        let app = AppViewModel(sheetViewModel: sheets, navigationViewModel: NavigationViewModel())
        let requests = [
            pubkySignupUrl,
            directPubkySignupUrl,
            directPubkySignupUrl.replacingOccurrences(of: "direct_signup", with: "signup"),
            "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://relay.example/inbox/" +
                "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s",
        ]

        for prefix in ["lightning:", "LIGHTNING:", "lnurl:", "lnurlw:", "lnurlp:", "lnurlc:", "lightning:lnurl:"] {
            for request in requests {
                app.scannedLightningInvoice = lightningInvoice
                do {
                    try await app.handleScannedData(" \(prefix)\(request)\n")
                    XCTFail("Expected wrapped Pubky request to be rejected")
                } catch ScanHandlingError.pubkyAuthRequest {
                    // Expected before decoding or presenting an approval sheet.
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                XCTAssertNotNil(app.scannedLightningInvoice)
                XCTAssertNil(sheets.activeSheetConfiguration)
            }
        }
    }

    func testSignupScannerRoutesRequireApproval() async throws {
        let defaults = UserDefaults.standard
        let previousEnabled = defaults.object(forKey: PaykitFeatureFlags.uiEnabledKey)
        defer { defaults.set(previousEnabled, forKey: PaykitFeatureFlags.uiEnabledKey) }
        defaults.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        XCTAssertFalse(try PubkyProfileManager.hasStoredIdentity())

        for url in [pubkySignupUrl, directPubkySignupUrl, directPubkySignupUrl.replacingOccurrences(of: "direct_signup", with: "signup")] {
            let sheets = SheetViewModel()
            let app = AppViewModel(
                sheetViewModel: sheets,
                navigationViewModel: NavigationViewModel()
            )

            try await app.handleScannedData(url)

            XCTAssertEqual(sheets.activeSheetConfiguration?.id, .pubkyAuthApproval)
            let config = try XCTUnwrap(sheets.activeSheetConfiguration?.data as? PubkyAuthApprovalConfig)
            XCTAssertTrue(config.request.isSignup)
            XCTAssertEqual(config.request.homeserverPublicKey, "5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo")
            XCTAssertFalse(try PubkyProfileManager.hasStoredIdentity())
        }
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

    private var directPubkySignupUrl: String {
        "pubkyauth://direct_signup?hs=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo&st=invite"
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
