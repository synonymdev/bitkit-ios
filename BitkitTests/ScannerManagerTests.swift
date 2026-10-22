@testable import Bitkit
import BitkitCore
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
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var completionCount = 0

        await scanner.handleSendScan(paymentURI) { route in
            completionCount += 1
            XCTAssertEqual(route, .amount)
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(hapticCount, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
        XCTAssertEqual(app.sendStateOwnerID, sheets.activeSheetConfiguration?.presentationID)
    }

    func testGenericSendPaymentScanPlaysOneSuccessHaptic() async {
        var hapticCount = 0
        let scanner = ScannerManager { hapticCount += 1 }
        let app = configure(scanner)

        await scanner.handleScan(paymentURI, context: .send)

        XCTAssertEqual(hapticCount, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    func testSendScanOfUsdtAddressContinuesInSendSheet() async throws {
        try XCTSkipUnless(Env.isUsdtEnabled, "USDT is not configured in this build")
        let recipient = "0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E"
        let scanner = ScannerManager {}
        let app = configure(scanner)
        let navigation = NavigationViewModel()
        scanner.configure(
            app: app,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared,
            navigation: navigation,
            wallet: WalletViewModel()
        )
        var routes: [SendRoute?] = []

        await scanner.handleSendScan(recipient) { routes.append($0) }

        XCTAssertEqual(routes, [.usdtAddress(recipient: recipient, amount: "")])
        XCTAssertTrue(navigation.path.isEmpty)
    }

    func testDelayedImageCannotOverwriteReplacementPayment() async throws {
        let scanner = ScannerManager { XCTFail("Stale image must not play a success haptic") }
        let app = configure(scanner)
        let sheets = SheetViewModel()
        scanner.configure(app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                          settings: SettingsViewModel.shared, sheets: sheets)
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let started = expectation(description: "Image decoding started")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        var routes: [SendRoute?] = []
        let task = Task {
            await scanner.handleImageScan(context: .send, decode: {
                try await withCheckedThrowingContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }) { routes.append($0) }
        }
        await fulfillment(of: [started], timeout: 2)
        sheets.hideSheet(reason: "Replace image origin")
        sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
        let replacementID = sheets.activeSheetConfiguration?.presentationID
        app.resetSendState(ownerID: replacementID)
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/new", callback: "https://example.com/callback",
            minSendable: 222_222, maxSendable: 222_222,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        let replacementGeneration = app.sendStateGeneration
        try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await task.value
        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, replacementID)
        XCTAssertEqual(app.sendStateGeneration, replacementGeneration)
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_222)
        XCTAssertNil(app.scannedOnchainInvoice)
        XCTAssertTrue(routes.isEmpty, "The retiring image's completion must not navigate")
    }

    func testDelayedImageIsIgnoredAfterDismissalOrTaskCancellation() async throws {
        for cancelTask in [false, true] {
            let scanner = ScannerManager { XCTFail("Dismissed/cancelled image must not play a success haptic") }
            let app = configure(scanner)
            let sheets = SheetViewModel()
            scanner.configure(app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                              settings: SettingsViewModel.shared, sheets: sheets)
            sheets.showSheet(.send, data: SendConfig(view: .options))
            let started = expectation(description: "Image decoding suspended")
            var continuation: CheckedContinuation<QRCodePayload, Error>?
            var didComplete = false
            let task = Task {
                await scanner.handleImageScan(context: .send, decode: {
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }) { _ in didComplete = true }
            }
            await fulfillment(of: [started], timeout: 2)
            let generation = app.sendStateGeneration
            if cancelTask {
                task.cancel()
            } else {
                sheets.hideSheet(reason: "Close image origin")
            }
            try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
            await task.value
            XCTAssertEqual(app.sendStateGeneration, generation)
            XCTAssertNil(app.scannedOnchainInvoice)
            XCTAssertFalse(didComplete)
        }
    }

    func testImageInCurrentPresentationStillProcessesNormally() async {
        var haptics = 0
        let scanner = ScannerManager { haptics += 1 }
        let app = configure(scanner)
        let sheets = SheetViewModel()
        scanner.configure(app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                          settings: SettingsViewModel.shared, sheets: sheets)
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var routes: [SendRoute?] = []
        await scanner.handleImageScan(context: .send, decode: { QRCodePayload(string: self.paymentURI, data: nil) }) {
            routes.append($0)
        }
        XCTAssertEqual(routes, [.amount])
        XCTAssertEqual(haptics, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
        XCTAssertEqual(app.sendStateOwnerID, sheets.activeSheetConfiguration?.presentationID)
    }

    func testStaleImageFailureDoesNotShowToastInReplacement() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(false, forKey: ToastWindowManager.disableAllToastsKey)
        let previousToast = ToastWindowManager.shared.currentToast
        ToastWindowManager.shared.currentToast = nil
        defer { ToastWindowManager.shared.currentToast = previousToast }
        let scanner = ScannerManager {}
        let app = configure(scanner)
        let sheets = SheetViewModel()
        scanner.configure(app: app, sheets: sheets)
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let started = expectation(description: "Image decoding suspended before error")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        let task = Task {
            await scanner.handleImageScan(context: .send, decode: {
                try await withCheckedThrowingContinuation {
                    continuation = $0
                    started.fulfill()
                }
            })
        }
        await fulfillment(of: [started], timeout: 2)
        sheets.hideSheet(reason: "Dismiss image origin")
        sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
        try XCTUnwrap(continuation).resume(throwing: QRCodeImageDecoderError.invalidImage)
        await task.value
        XCTAssertNil(ToastWindowManager.shared.currentToast)
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
