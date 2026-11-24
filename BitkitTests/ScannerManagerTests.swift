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
            await scanner.handleSendScan(paymentURI + "?amount=0.00001") { route in
                if let route {
                    flow.navigationPath.append(route)
                }
            }
            XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, 1000)
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
            XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, 1000)
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

    func testGiftCodeScanShowsTheInvalidCodeToastAndNoSheet() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(false, forKey: ToastWindowManager.disableAllToastsKey)
        let previousToast = ToastWindowManager.shared.currentToast
        defer { ToastWindowManager.shared.currentToast = previousToast }
        ToastWindowManager.shared.currentToast = nil
        let sheets = SheetViewModel()
        let app = configure(ScannerManager {}, sheets: sheets, decodeInvoice: { _ in .gift(code: "gift-code", amount: 1000) })

        try await app.handleScannedData("bitkit://gift-code-1000")

        XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "InvalidAddressToast")
        XCTAssertNil(sheets.activeSheetConfiguration)
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

// MARK: - NFC

extension ScannerManagerTests {
    func testNfcAvailabilityFollowsReader() {
        let reader = FakeNfcReader(.success(""))
        reader.isAvailable = false
        XCTAssertFalse(ScannerManager(nfcReader: reader) {}.isNfcReadingAvailable)
        reader.isAvailable = true
        XCTAssertTrue(ScannerManager(nfcReader: reader) {}.isNfcReadingAvailable)
    }

    func testNfcSendReadRoutesLikeAScannedQrCode() async {
        var hapticCount = 0
        let reader = FakeNfcReader(.success(paymentURI))
        let scanner = ScannerManager(nfcReader: reader) { hapticCount += 1 }
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var routes: [SendRoute?] = []

        await scanner.handleSendNfcRead { routes.append($0) }

        XCTAssertEqual(reader.alertMessages, [t("other__nfc_alert")])
        XCTAssertEqual(routes, [.amount])
        XCTAssertEqual(hapticCount, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    func testNfcGenericReadRoutesLikeAScannedQrCode() async {
        var hapticCount = 0
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(paymentURI))) { hapticCount += 1 }
        let app = configure(scanner)

        await scanner.handleNfcRead(context: .send)

        XCTAssertEqual(hapticCount, 1)
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    func testFailedNfcReadCompletesWithoutRoute() async {
        let previousToast = ToastWindowManager.shared.currentToast
        defer { ToastWindowManager.shared.currentToast = previousToast }
        for error in [NfcReadError.cancelled, .timedOut, .noPaymentRequest, .multiplePaymentRequests, .unavailable] {
            ToastWindowManager.shared.currentToast = nil
            let scanner = ScannerManager(nfcReader: FakeNfcReader(.failure(error))) {
                XCTFail("A failed NFC read must not play a success haptic")
            }
            let app = configure(scanner)
            var routes: [SendRoute?] = []

            await scanner.handleSendNfcRead { routes.append($0) }

            XCTAssertEqual(routes, [nil], "\(error)")
            XCTAssertNil(app.scannedOnchainInvoice, "\(error)")
            // The payer sees why the read failed, except when they cancelled it or it timed out.
            let shown = ToastWindowManager.shared.currentToast
            if error.isSilent {
                XCTAssertNil(shown, "\(error)")
            } else {
                XCTAssertEqual(shown?.title, t("other__nfc_error_header"), "\(error)")
                XCTAssertEqual(shown?.description, error.message, "\(error)")
            }
        }
    }

    func testCameraScanFromBeforeALockDoesNotRoute() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let started = expectation(description: "Lookup suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let scan = Task { await scanner.handleScan(paymentURI, context: .main) }
        await fulfillment(of: [started], timeout: 2)

        // The app locks while the lookup runs, and the payer unlocks before it returns.
        scanner.invalidateScansForAppLock()
        try XCTUnwrap(continuation).resume(returning: decoded)
        await scan.value

        XCTAssertNil(app.scannedOnchainInvoice, "A scan from before the lock must not open Send after the unlock")
    }

    func testSendScanFromBeforeALockDoesNotRoute() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let started = expectation(description: "Lookup suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var routes: [SendRoute?] = []
        func record(_ route: SendRoute?) {
            routes.append(route)
        }
        let scan = Task { await scanner.handleSendScan(paymentURI, completion: record) }
        await fulfillment(of: [started], timeout: 2)

        scanner.invalidateScansForAppLock()
        try XCTUnwrap(continuation).resume(returning: decoded)
        await scan.value

        XCTAssertTrue(routes.allSatisfy { $0 == nil }, "A scan from before the lock must not route after the unlock")
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testNearbyRequestWithARequiredParameterIsRefused() async {
        let required = "\(paymentURI)?amount=0.001&REQ-POP=callback%3a"
        XCTAssertFalse(ScannerManager.isNearbyPaymentRequest(required))
        XCTAssertTrue(ScannerManager.isNearbyPaymentRequest("\(paymentURI)?amount=0.001&pop=callback%3a"))

        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(required))) {
            XCTFail("An NFC request with a required parameter must not play a success haptic")
        }
        let app = configure(scanner)
        var routes: [SendRoute?] = []
        await scanner.handleSendNfcRead { routes.append($0) }
        XCTAssertEqual(routes, [nil])
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testNearbyRequestRoutesWithQuickPaySuppressed() async {
        var hapticCount = 0
        let scanner = ScannerManager { hapticCount += 1 }
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var suppressedAtRoute: [Bool] = []
        var routes: [SendRoute?] = []

        await scanner.handleSendNearbyRequest(paymentURI) { route in
            routes.append(route)
            suppressedAtRoute.append(app.isQuickPaySuppressed)
        }

        XCTAssertEqual(routes, [.amount])
        XCTAssertEqual(suppressedAtRoute, [true])
        XCTAssertFalse(app.isQuickPaySuppressed)
        XCTAssertEqual(hapticCount, 1)
    }

    func testNearbyAllowlistAcceptsPaymentSchemesOnly() {
        let invoice = PosNfcFixtures.squareInvoice
        for uri in ["bitcoin:bcrt1qexample", "BITCOIN:BCRT1Q", "lightning:\(invoice)", "lightning:\(invoice.lowercased())",
                    "ethereum:0xabc@42161", " bitcoin:bcrt1q?lightning=\(invoice) ", "bitcoin:bcrt1q?amount=0.1&label=lightning",
                    "lightning:\(ChannelFreeRailTests.invoice)", PosNfcFixtures.squareUri, PosNfcFixtures.bip321Uri]
        {
            XCTAssertTrue(ScannerManager.isNearbyPaymentRequest(uri), uri)
        }
        for uri in authURIs + nearbyNetworkLookups + ["lnurlw://example.com/w", "lnurlc://example.com/c", "LNURL1DP68GURN8GHJ7",
                                                      "lightning:lno1qgsqvgnwgcg35z6ee2h3yczraddm72xrfua9uve2rlrm9deu7xyfzr",
                                                      "bcrt1qexample",
                                                      "lnbcrt10u1pjexample", "lightning:lnbcrt1", "lightning:lnsb1qqqqqq",
                                                      "lightning:\(PosNfcFixtures.squareInvoice.dropLast())x",
                                                      "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw374y",
                                                      "https://example.com", "bitkit://contact/abc", "02aaaa@127.0.0.1:9735", ""]
        {
            XCTAssertFalse(ScannerManager.isNearbyPaymentRequest(uri), uri)
        }
    }

    /// Requests the decoder would resolve over the network before the user picked them.
    private var nearbyNetworkLookups: [String] {
        [
            "LIGHTNING:LNURL1DP68GURN8GHJ7", "lnurlp://example.com/pay", "lightning:alice@example.com",
            "bitcoin:bcrt1q?amount=0.1&lightning=LNURL1DP68GURN8GHJ7", "bitcoin:?lightning=lnurl1dp68gurn8ghj7",
            "lightning:lnsb@example.com", "bitcoin:?lightning=lnsb@example.com", "bitcoin:bcrt1q?lightning=lnsb@example.com",
            "lightning:lnbc@example.com", "bitcoin:bcrt1q?lightning=lntb1@example.com",
            // Each repeated Lightning value is checked, since the decoder takes the last one.
            "bitcoin:bcrt1q?lightning=\(PosNfcFixtures.squareInvoice)&lightning=LNURL1DP68GURN8GHJ7",
        ]
    }

    func testNearbyRequestDoesNotResolveAnLnurlBeforeReview() async {
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { uri in
            XCTFail("Bluetooth discovery alone must not decode \(uri)")
            return .gift(code: "gift-code", amount: 1000)
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )

        for uri in nearbyNetworkLookups {
            let sendWasTaken = await scanner.handleSendNearbyRequest(uri) { XCTAssertNil($0, uri) }
            let mainWasTaken = await scanner.handleNearbyRequest(uri, context: .main)
            XCTAssertFalse(sendWasTaken, uri)
            XCTAssertFalse(mainWasTaken, uri)
        }
    }

    func testNearbyRequestRefusesNonPaymentPayloads() async {
        let scanner = ScannerManager { XCTFail("A refused Bluetooth payload must not play a success haptic") }
        let app = configure(scanner)
        var routes: [SendRoute?] = []

        for uri in authURIs + ["lnurlw://example.com/withdraw", "bitkit://contact/abc"] {
            let wasTaken = await scanner.handleSendNearbyRequest(uri) { routes.append($0) }
            XCTAssertFalse(wasTaken, uri)
        }
        let mainWasTaken = await scanner.handleNearbyRequest("pubkyauth://signin", context: .main)

        XCTAssertFalse(mainWasTaken)
        XCTAssertEqual(routes, Array(repeating: nil, count: authURIs.count + 2))
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testNearbyRequestRefusesDecodedNonPaymentTypes() async {
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in .gift(code: "gift-code", amount: 1000) })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var routes: [SendRoute?] = []

        let wasTaken = await scanner.handleSendNearbyRequest("lightning:\(PosNfcFixtures.squareInvoice)") { routes.append($0) }

        XCTAssertFalse(wasTaken)
        XCTAssertEqual(routes, [nil])
    }

    func testNearbyRequestCannotRouteAfterItsScannerCloses() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        let started = expectation(description: "Nearby request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var routes: [SendRoute?] = []
        let task = Task { await scanner.handleSendNearbyRequest(paymentURI) { routes.append($0) } }

        await fulfillment(of: [started], timeout: 2)
        sheets.hideSheet(reason: "User left the scanner during a nearby request")
        try XCTUnwrap(continuation).resume(returning: decoded)
        let wasTaken = await task.value

        XCTAssertFalse(wasTaken)
        XCTAssertTrue(routes.isEmpty)
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testNearbyRequestCannotRouteAfterTheSendSheetMovesOn() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        let started = expectation(description: "Nearby request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var navigationPath: [SendRoute] = []
        var routes: [SendRoute?] = []
        let task = Task {
            await scanner.handleSendNearbyRequest(paymentURI, isCurrent: { navigationPath.isEmpty }) { routes.append($0) }
        }

        await fulfillment(of: [started], timeout: 2)
        navigationPath.append(.manual)
        try XCTUnwrap(continuation).resume(returning: decoded)
        let wasTaken = await task.value

        XCTAssertFalse(wasTaken)
        XCTAssertTrue(routes.isEmpty)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
    }

    func testNfcReadCannotRouteAfterItsSendSheetCloses() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        let started = expectation(description: "NFC request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(paymentURI))) {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var routes: [SendRoute?] = []
        let task = Task { await scanner.handleSendNfcRead { routes.append($0) } }

        await fulfillment(of: [started], timeout: 2)
        sheets.hideSheet(reason: "User left the Send sheet during an NFC request")
        try XCTUnwrap(continuation).resume(returning: decoded)
        await task.value

        XCTAssertTrue(routes.allSatisfy { $0 == nil })
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testNfcReadCannotRouteAfterTheAppLocks() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        let started = expectation(description: "NFC request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(paymentURI))) {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var routes: [SendRoute?] = []
        let task = Task { await scanner.handleSendNfcRead { routes.append($0) } }

        await fulfillment(of: [started], timeout: 2)
        // The payer leaves the app mid-decode, and it locks behind the PIN with the Send sheet still set.
        scanner.invalidateScansForAppLock()
        try XCTUnwrap(continuation).resume(returning: decoded)
        await task.value

        XCTAssertTrue(routes.allSatisfy { $0 == nil })
        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testMainScannerRouteDoesNotOpenOnceTheAppLocks() async throws {
        func routeFromTheScanner(lockingBeforeTheSheetOpens: Bool) async throws -> SheetConfiguration? {
            let sheets = SheetViewModel()
            sheets.showSheet(.scanner)
            let scanner = ScannerManager {}
            let app = configure(scanner, sheets: sheets)
            scanner.configure(
                app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                settings: SettingsViewModel.shared, sheets: sheets
            )
            await scanner.handleNearbyRequest(paymentURI, context: .main)
            // The scanner sheet is closing; the payment sheet opens after the replacement delay.
            XCTAssertNil(sheets.activeSheetConfiguration)
            if lockingBeforeTheSheetOpens {
                scanner.invalidateScansForAppLock()
            }
            try await Task.sleep(nanoseconds: UInt64((SheetViewModel.replacementDelaySeconds + 0.3) * 1_000_000_000))
            return sheets.activeSheetConfiguration
        }

        let unlocked = try await routeFromTheScanner(lockingBeforeTheSheetOpens: false)
        XCTAssertNotNil(unlocked, "Without a lock the request opens its payment sheet")
        let locked = try await routeFromTheScanner(lockingBeforeTheSheetOpens: true)
        XCTAssertNil(locked, "A request routed just before the lock must not open after it")
    }

    func testASheetThatReplacedTheScannerDuringADecodeSurvivesALock() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let started = expectation(description: "Nearby request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let task = Task { await scanner.handleNearbyRequest(paymentURI, context: .main) }
        await fulfillment(of: [started], timeout: 2)

        // A received payment replaces the scanner while the request decodes; the request then routes nothing.
        sheets.showSheet(.receivedTx)
        try XCTUnwrap(continuation).resume(returning: decoded)
        _ = await task.value
        scanner.invalidateScansForAppLock()
        try await Task.sleep(nanoseconds: UInt64((SheetViewModel.replacementDelaySeconds + 0.3) * 1_000_000_000))

        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .receivedTx, "A lock must cancel only the scan's own route")
    }

    func testNfcReadCannotRouteAfterTheSendSheetMovesOn() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        let started = expectation(description: "NFC request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(paymentURI))) {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var navigationPath: [SendRoute] = []
        var routes: [SendRoute?] = []
        let task = Task {
            await scanner.handleSendNfcRead(isCurrent: { navigationPath.isEmpty }) { routes.append($0) }
        }

        await fulfillment(of: [started], timeout: 2)
        navigationPath.append(.manual)
        try XCTUnwrap(continuation).resume(returning: decoded)
        await task.value

        XCTAssertTrue(routes.allSatisfy { $0 == nil })
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
    }

    func testNfcReadCannotRouteAfterLeavingAndReturningToTheScanner() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        let navigation = NavigationViewModel()
        let started = expectation(description: "NFC request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(paymentURI))) {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, navigation: navigation, sheets: sheets
        )
        sheets.showSheet(.scanner)
        let task = Task { await scanner.handleNfcRead(context: .main) }

        await fulfillment(of: [started], timeout: 2)
        navigation.path.append(.savingsWallet)
        navigation.path.removeLast()
        try XCTUnwrap(continuation).resume(returning: decoded)
        await task.value

        XCTAssertTrue(navigation.path.isEmpty)
        XCTAssertNil(app.scannedOnchainInvoice, "A read from an earlier visit must not route")
    }

    func testRefusedNearbyRequestOnMainScannerIsNotTaken() async {
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let scanner = ScannerManager {}
        let expired = LightningInvoice(
            bolt11: "lnbcrt1expired",
            paymentHash: Data(repeating: 1, count: 32),
            amountSatoshis: 1000,
            timestampSeconds: 0,
            expirySeconds: 0,
            isExpired: true,
            description: nil,
            networkType: .regtest,
            payeeNodeId: nil
        )
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in .lightning(invoice: expired) })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )

        let wasTaken = await scanner.handleNearbyRequest("lightning:\(PosNfcFixtures.squareInvoice)", context: .main)

        XCTAssertFalse(wasTaken)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .scanner)
    }

    func testNearbyRequestReportsTakenWhenItRoutes() async {
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )

        let wasTaken = await scanner.handleSendNearbyRequest(paymentURI) { _ in }

        XCTAssertTrue(wasTaken)
    }

    func testUserScanTakesOverFromADecodingNearbyRequest() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let nearbyURI = "bitcoin:bcrt1qnearbyrequest"
        let sheets = SheetViewModel()
        let started = expectation(description: "Nearby request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.success(paymentURI))) {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { input in
            guard input.contains("nearbyrequest") else { return decoded }
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        sheets.showSheet(.send, data: SendConfig(view: .options))
        var nearbyRoutes: [SendRoute?] = []
        let task = Task {
            await scanner.handleSendNearbyRequest(nearbyURI) { nearbyRoutes.append($0) }
        }
        await fulfillment(of: [started], timeout: 2)

        var routes: [SendRoute?] = []
        var suppressedAtUserRoute: [Bool] = []
        await scanner.handleSendNfcRead { route in
            routes.append(route)
            suppressedAtUserRoute.append(app.isQuickPaySuppressed)
        }
        try XCTUnwrap(continuation).resume(returning: decoded)
        let wasTaken = await task.value

        XCTAssertEqual(routes, [.amount])
        XCTAssertEqual(suppressedAtUserRoute, [false], "QuickPay must apply to the user's own read")
        XCTAssertFalse(wasTaken)
        XCTAssertTrue(nearbyRoutes.allSatisfy { $0 == nil })
        XCTAssertFalse(app.isQuickPaySuppressed)

        // The lock is free again for the next read.
        var nextRoutes: [SendRoute?] = []
        await scanner.handleSendScan(paymentURI) { nextRoutes.append($0) }
        XCTAssertEqual(nextRoutes, [.amount])
    }

    func testNearbyRequestWaitsForASelectedPhoto() async throws {
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let started = expectation(description: "Photo loading suspended")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        func loadPhoto() async throws -> QRCodePayload {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let photo = Task { await scanner.handleImageScan(context: .main, decode: loadPhoto) }
        await fulfillment(of: [started], timeout: 2)

        let nearbyURI = "bitcoin:bcrt1q59y53uy2h02dlqn76n824ns3maupd3mx4lfm0y"
        let wasTaken = await scanner.handleNearbyRequest(nearbyURI, context: .main)
        XCTAssertFalse(wasTaken, "A nearby request must not open while the selected photo loads")

        try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await photo.value
        XCTAssertEqual(app.scannedOnchainInvoice?.address, "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x")
    }

    func testPhotoTakesOverABluetoothRequestAlreadyDecoding() async throws {
        let nearbyURI = "bitcoin:bcrt1q59y53uy2h02dlqn76n824ns3maupd3mx4lfm0y"
        let nearbyDecoded = try await decode(invoice: nearbyURI)
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let scanner = ScannerManager {}
        let nearbyStarted = expectation(description: "Bluetooth request decoding suspended")
        var nearbyContinuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let app = configure(scanner, sheets: sheets, decodeInvoice: { input in
            guard input.contains("59y53uy2") else { return try await decode(invoice: input) }
            return try await withCheckedThrowingContinuation {
                nearbyContinuation = $0
                nearbyStarted.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let nearby = Task { await scanner.handleNearbyRequest(nearbyURI, context: .main) }
        await fulfillment(of: [nearbyStarted], timeout: 2)

        let photoStarted = expectation(description: "Photo loading suspended")
        var photoContinuation: CheckedContinuation<QRCodePayload, Error>?
        func loadPhoto() async throws -> QRCodePayload {
            try await withCheckedThrowingContinuation {
                photoContinuation = $0
                photoStarted.fulfill()
            }
        }
        let photo = Task { await scanner.handleImageScan(context: .main, decode: loadPhoto) }
        await fulfillment(of: [photoStarted], timeout: 2)

        // The Bluetooth request finishes decoding while the photo still loads.
        try XCTUnwrap(nearbyContinuation).resume(returning: nearbyDecoded)
        let wasTaken = await nearby.value
        XCTAssertFalse(wasTaken, "The picked photo takes over a Bluetooth request still decoding")

        try XCTUnwrap(photoContinuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await photo.value
        XCTAssertEqual(app.scannedOnchainInvoice?.address, "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x")
    }

    func testPhotoStillLoadingFromAClosedScannerDoesNotHoldTheNextOne() async throws {
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let started = expectation(description: "Photo loading suspended")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        func loadPhoto() async throws -> QRCodePayload {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let photo = Task { await scanner.handleImageScan(context: .main, decode: loadPhoto) }
        await fulfillment(of: [started], timeout: 2)

        // The user closes that scanner and opens it again; the old photo is still loading.
        sheets.hideSheet()
        sheets.showSheet(.scanner)
        let wasTaken = await scanner.handleNearbyRequest(paymentURI, context: .main)
        XCTAssertTrue(wasTaken, "A photo from a closed scanner must not hold Bluetooth on the next visit")

        try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await photo.value
    }

    func testPhotoFromAnEarlierSendOptionsVisitNeitherHoldsNorRoutes() async throws {
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var isOnFirstVisit = true
        let started = expectation(description: "Photo loading suspended")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        func loadPhoto() async throws -> QRCodePayload {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        var photoRoutes: [SendRoute?] = []
        func isOnVisit() -> Bool {
            isOnFirstVisit
        }
        func record(_ route: SendRoute?) {
            photoRoutes.append(route)
        }
        let photo = Task { await scanner.handleImageScan(context: .send, isCurrent: isOnVisit, decode: loadPhoto, completion: record) }
        await fulfillment(of: [started], timeout: 2)

        // Enter Manually and Back: the sheet stays open, but Send Options starts a new scanner visit.
        isOnFirstVisit = false
        let wasTaken = await scanner.handleSendNearbyRequest(paymentURI) { _ in }
        XCTAssertTrue(wasTaken, "A photo from an earlier Send Options visit must not hold Bluetooth")

        try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await photo.value
        XCTAssertTrue(photoRoutes.allSatisfy { $0 == nil }, "The earlier visit's photo must not route")
    }

    func testPhotoFromAnEarlierFullScreenScannerVisitDoesNotRoute() async throws {
        let navigation = NavigationViewModel()
        navigation.path = [.scanner]
        let scanner = ScannerManager {}
        let app = configure(scanner)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, navigation: navigation, sheets: SheetViewModel()
        )
        let started = expectation(description: "Photo loading suspended")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        func loadPhoto() async throws -> QRCodePayload {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let photo = Task { await scanner.handleImageScan(context: .main, decode: loadPhoto) }
        await fulfillment(of: [started], timeout: 2)

        // The user leaves the scanner and opens it again: the same path, but a new visit.
        navigation.path = []
        navigation.path = [.scanner]

        try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await photo.value
        XCTAssertNil(app.scannedOnchainInvoice, "The earlier visit's photo must not open its payment")
    }

    func testBluetoothWaitsForEveryPickedPhoto() async throws {
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let started = expectation(description: "First photo loading suspended")
        var continuation: CheckedContinuation<QRCodePayload, Error>?
        func loadSlowPhoto() async throws -> QRCodePayload {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func loadPhotoWithoutQrCode() async throws -> QRCodePayload {
            throw QRCodeImageDecoderError.noQRCode
        }
        let slowPhoto = Task { await scanner.handleImageScan(context: .main, decode: loadSlowPhoto) }
        await fulfillment(of: [started], timeout: 2)

        // A second photo finishes first; the first one is still loading.
        await scanner.handleImageScan(context: .main, decode: loadPhotoWithoutQrCode)
        let nearbyURI = "bitcoin:bcrt1q59y53uy2h02dlqn76n824ns3maupd3mx4lfm0y"
        let wasTaken = await scanner.handleNearbyRequest(nearbyURI, context: .main)
        XCTAssertFalse(wasTaken, "Bluetooth must wait while any picked photo still loads")

        try XCTUnwrap(continuation).resume(returning: QRCodePayload(string: paymentURI, data: nil))
        await slowPhoto.value
        XCTAssertEqual(app.scannedOnchainInvoice?.address, "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x")
    }

    func testPhotoWithoutAQrCodeReleasesNearbyRequests() async {
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        func loadPhoto() async throws -> QRCodePayload {
            throw QRCodeImageDecoderError.noQRCode
        }
        await scanner.handleImageScan(context: .main, decode: loadPhoto)

        let wasTaken = await scanner.handleNearbyRequest(paymentURI, context: .main)
        XCTAssertTrue(wasTaken)
    }

    func testNodeSetupScannerDoesNotReadNearbyRequests() {
        XCTAssertTrue(ScannerScreen.readsNearby(context: .main, path: [.scanner]))
        XCTAssertFalse(ScannerScreen.readsNearby(context: .main, path: [.fundManual(nodeUri: nil), .scanner]))
        XCTAssertFalse(ScannerScreen.readsNearby(context: .electrum, path: [.electrumSettings, .scanner]))
    }

    func testMainScannerQrTakesOverFromADecodingNearbyRequest() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        sheets.showSheet(.scanner)
        let started = expectation(description: "Nearby request decoding suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        var decodedInputs: [String] = []
        let scanner = ScannerManager {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { input in
            decodedInputs.append(input)
            guard input.contains("nearbyrequest") else { return decoded }
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        let task = Task {
            await scanner.handleNearbyRequest("bitcoin:bcrt1qnearbyrequest", context: .main)
        }
        await fulfillment(of: [started], timeout: 2)

        await scanner.handleScan(paymentURI, context: .main)
        try XCTUnwrap(continuation).resume(returning: decoded)
        let wasTaken = await task.value

        XCTAssertFalse(wasTaken)
        XCTAssertEqual(decodedInputs.count, 2, "The QR code must be decoded while the nearby request is pending")
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    func testBluetoothRequestCannotRouteWhileAnNfcReadIsOpen() async throws {
        let decoded = try await decode(invoice: paymentURI)
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let reader = HeldNfcReader()
        let scanner = ScannerManager(nfcReader: reader) {}
        let app = configure(scanner, sheets: sheets, decodeInvoice: { _ in decoded })
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var nfcRoutes: [SendRoute?] = []
        let nfcTask = Task { await scanner.handleSendNfcRead { nfcRoutes.append($0) } }
        await fulfillment(of: [reader.started], timeout: 2)

        var nearbyRoutes: [SendRoute?] = []
        let wasTaken = await scanner.handleSendNearbyRequest("bitcoin:bcrt1qnearbyrequest") { nearbyRoutes.append($0) }
        reader.finish(.success(paymentURI))
        await nfcTask.value

        XCTAssertFalse(wasTaken, "The Bluetooth request must wait for the open NFC read")
        XCTAssertTrue(nearbyRoutes.allSatisfy { $0 == nil })
        XCTAssertEqual(nfcRoutes, [.amount])
    }

    func testFailedNfcReadReleasesTheScanLock() async {
        let sheets = SheetViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .options))
        let scanner = ScannerManager(nfcReader: FakeNfcReader(.failure(.cancelled))) {}
        let app = configure(scanner, sheets: sheets)
        scanner.configure(
            app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared, sheets: sheets
        )
        var nfcRoutes: [SendRoute?] = []
        await scanner.handleSendNfcRead { nfcRoutes.append($0) }

        let wasTaken = await scanner.handleSendNearbyRequest(paymentURI) { _ in }

        XCTAssertEqual(nfcRoutes, [nil])
        XCTAssertTrue(wasTaken)
    }

    func testNfcErrorMessages() {
        XCTAssertEqual(NfcReadError.noPaymentRequest.message, t("other__nfc_error_text"))
        XCTAssertEqual(NfcReadError.multiplePaymentRequests.message, t("other__nfc_error_multiple"))
        XCTAssertEqual(NfcReadError.unavailable.message, t("other__nfc_error_unavailable"))
        XCTAssertEqual(NfcReadError.failed("Tag connection lost").message, t("other__nfc_error_read_failed"))
    }

    func testCancelledAndTimedOutNfcReadsAreSilent() {
        XCTAssertTrue(NfcReadError.cancelled.isSilent)
        XCTAssertTrue(NfcReadError.timedOut.isSilent)
        XCTAssertFalse(NfcReadError.noPaymentRequest.isSilent)
        XCTAssertFalse(NfcReadError.failed("x").isSilent)
    }
}

@MainActor
private final class FakeNfcReader: NfcPaymentReading {
    var isAvailable = true
    private let result: Result<String, NfcReadError>
    private(set) var alertMessages: [String] = []

    init(_ result: Result<String, NfcReadError>) {
        self.result = result
    }

    func readPaymentRequest(alertMessage: String) async throws -> String {
        alertMessages.append(alertMessage)
        return try result.get()
    }
}

/// Holds the NFC read open until the test finishes it, like the system NFC sheet waiting for a tag.
@MainActor
private final class HeldNfcReader: NfcPaymentReading {
    var isAvailable = true
    let started = XCTestExpectation(description: "NFC read open")
    private var continuation: CheckedContinuation<String, Error>?

    func readPaymentRequest(alertMessage _: String) async throws -> String {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ result: Result<String, NfcReadError>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
