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

    func testDelayedImageCannotOverwriteNewerScanInSameSend() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(false, forKey: ToastWindowManager.disableAllToastsKey)
        let previousToast = ToastWindowManager.shared.currentToast
        defer { ToastWindowManager.shared.currentToast = previousToast }
        for fails in [false, true] {
            ToastWindowManager.shared.currentToast = nil
            var haptics = 0
            let scanner = ScannerManager { haptics += 1 }
            let sheets = SheetViewModel()
            let app = configure(scanner, sheets: sheets)
            scanner.configure(app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                              settings: SettingsViewModel.shared, sheets: sheets)
            sheets.showSheet(.send, data: SendConfig(view: .options))
            let presentation = try XCTUnwrap(sheets.activeSheetConfiguration)
            let flow = try XCTUnwrap(presentation.sendState)
            let started = expectation(description: "Older photo decoding suspended")
            var continuation: CheckedContinuation<QRCodePayload, Error>?
            var staleRoutes: [SendRoute?] = []
            let task = Task {
                await scanner.handleImageScan(context: .send, decode: {
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }) { staleRoutes.append($0) }
            }
            await fulfillment(of: [started], timeout: 2)
            await scanner.handleSendScan(paymentURI + "?amount=0.000002") { route in
                if let route {
                    flow.navigationPath.append(route)
                }
            }
            XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, 200)
            let generation = app.sendStateGeneration
            let path = flow.navigationPath
            XCTAssertFalse(path.isEmpty)
            if fails {
                try XCTUnwrap(continuation).resume(throwing: QRCodeImageDecoderError.invalidImage)
            } else {
                try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
            }
            await task.value
            XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentation.presentationID)
            XCTAssertEqual(app.sendStateGeneration, generation)
            XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, 200)
            XCTAssertEqual(flow.navigationPath, path)
            XCTAssertTrue(staleRoutes.isEmpty)
            XCTAssertEqual(haptics, 1)
            XCTAssertNil(ToastWindowManager.shared.currentToast)
        }
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

    func testImageResolutionCannotCompleteAfterOriginDismissalOrReplacement() async throws {
        let oldOnchainResult = try await decode(invoice: paymentURI)
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(false, forKey: ToastWindowManager.disableAllToastsKey)
        let previousToast = ToastWindowManager.shared.currentToast
        defer { ToastWindowManager.shared.currentToast = previousToast }
        for replace in [false, true] {
            for failResolution in [false, true] {
                ToastWindowManager.shared.currentToast = nil
                let sheets = SheetViewModel()
                let started = expectation(description: "Payment target resolution suspended")
                var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
                let scanner = ScannerManager {}
                let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                })
                scanner.configure(app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                                  settings: SettingsViewModel.shared, sheets: sheets)
                sheets.showSheet(.send, data: SendConfig(view: .options))
                var routes: [SendRoute?] = []
                let task = Task {
                    await scanner.handleImageScan(context: .send, decode: {
                        QRCodePayload(string: "https://example.com/old-image", data: nil)
                    }) { routes.append($0) }
                }
                await fulfillment(of: [started], timeout: 2)
                sheets.hideSheet(reason: "Retire image during payment resolution")
                app.resetSendState()
                if replace {
                    sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
                    app.lnurlPayData = imageTestLnurl(amount: 222_222)
                }
                let generation = app.sendStateGeneration
                if failResolution {
                    try XCTUnwrap(continuation).resume(throwing: QRCodeImageDecoderError.invalidImage)
                } else {
                    try XCTUnwrap(continuation).resume(returning: replace ? oldOnchainResult : .lnurlPay(data: imageTestLnurl(amount: 999_000)))
                }
                await task.value
                XCTAssertEqual(app.sendStateGeneration, generation)
                XCTAssertEqual(app.lnurlPayData?.minSendable, replace ? 222_222 : nil)
                XCTAssertNil(app.scannedOnchainInvoice)
                XCTAssertTrue(routes.isEmpty)
                XCTAssertNil(ToastWindowManager.shared.currentToast)
            }
        }
    }

    private func imageTestLnurl(amount: UInt64) -> LnurlPayData {
        LnurlPayData(uri: "https://example.com/pay", callback: "https://example.com/callback",
                     minSendable: amount, maxSendable: amount,
                     metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil)
    }

    private func configure(
        _ scanner: ScannerManager,
        sheets: SheetViewModel = SheetViewModel(),
        decodeInvoice: @escaping (String) async throws -> BitkitCore.Scanner = { try await decode(invoice: $0) }
    ) -> AppViewModel {
        let app = AppViewModel(
            sheetViewModel: sheets,
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
                canSendLightning: { _ in false },
                decodeInvoice: decodeInvoice
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
