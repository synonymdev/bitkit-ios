@testable import Bitkit
import XCTest

@MainActor
final class ScannerManagerTests: XCTestCase {
    private let paymentURI = "bitcoin:bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
    private let authURIs = [
        "pubkyauth://signin",
        "PUBKYAUTH://signin_grant",
        "bitkit://pubky-auth/setup?caps=/pub/example/:rw",
        "pubkyring://signup",
    ]

    override func setUp() {
        super.setUp()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
    }

    func testSendScanRejectsPubkyAuthWithoutSuccessHaptic() async {
        var hapticCount = 0
        let scanner = ScannerManager { hapticCount += 1 }
        let app = configure(scanner)
        var completionCount = 0

        for uri in authURIs {
            XCTAssertTrue(PubkyAuthRequest.isProtocolURL(uri), uri)
            await scanner.handleSendScan(QRCodePayload(string: uri, data: nil)) { route in
                completionCount += 1
                XCTAssertNil(route)
            }
        }

        XCTAssertEqual(completionCount, authURIs.count)
        XCTAssertEqual(hapticCount, 0)
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testGenericSendScanRejectsPubkyAuthWithoutSuccessHaptic() async {
        var hapticCount = 0
        let scanner = ScannerManager { hapticCount += 1 }
        let app = configure(scanner)

        for uri in authURIs {
            XCTAssertTrue(PubkyAuthRequest.isProtocolURL(uri), uri)
            await scanner.handleScan(QRCodePayload(string: uri, data: nil), context: .send)
        }

        XCTAssertEqual(hapticCount, 0)
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testSendPaymentScanPlaysOneSuccessHapticAndReturnsAmountRoute() async {
        var hapticCount = 0
        let scanner = ScannerManager { hapticCount += 1 }
        let app = configure(scanner)
        var completionCount = 0

        await scanner.handleSendScan(paymentURI) { route in
            completionCount += 1
            XCTAssertEqual(route, .amount)
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(hapticCount, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    func testGenericSendPaymentScanPlaysOneSuccessHaptic() async {
        var hapticCount = 0
        let scanner = ScannerManager { hapticCount += 1 }
        let app = configure(scanner)

        await scanner.handleScan(paymentURI, context: .send)

        XCTAssertEqual(hapticCount, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    private func configure(_ scanner: ScannerManager) -> AppViewModel {
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: false,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 0,
                        hasChannels: false,
                        hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false }
            )
        )
        scanner.configure(
            app: app,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared
        )
        return app
    }
}
