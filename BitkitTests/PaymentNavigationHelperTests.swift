@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

@MainActor
final class PaymentNavigationHelperTests: XCTestCase {
    private let settings = SettingsViewModel.shared
    private var spendDefaults: UserDefaults!
    private var spendSuiteName: String!
    private var spendStore: QuickPaySpendStore!

    override func setUp() {
        super.setUp()
        // Building a `CurrencyViewModel` syncs the display currency into the shared group.bitkit
        // suite from its initializer, which the widget extension reads.
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        // Snapshot from disk, not from `SettingsViewModel.shared`. Its `@AppStorage` properties do not
        // observe `setPersistentDomain`, so after an earlier suite's `resetToDefaults()` the singleton
        // still reports the defaults — capturing those as "originals" and writing them back in
        // tearDown overwrote the user's values that the domain restore had just put back.
        snapshotAppDefaults(
            "primaryDisplay",
            "cached_fx_rates",
            "enableQuickpay",
            "quickpayAmount",
            "quickpayDailyLimitMultiplier",
            "pinEnabled",
            "requirePinForPayments",
            "usdtPreference"
        )

        spendSuiteName = "PaymentNavigationHelperTests.\(UUID().uuidString)"
        spendDefaults = UserDefaults(suiteName: spendSuiteName)
        spendStore = QuickPaySpendStore(defaults: spendDefaults)

        settings.enableQuickpay = true
        settings.quickpayAmount = 5
        settings.quickpayDailyLimitMultiplier = 5
        guard let encodedRates = try? JSONEncoder().encode([usdRate]) else {
            XCTFail("Failed to encode the QuickPay test exchange rate")
            return
        }
        UserDefaults.standard.set(encodedRates, forKey: "cached_fx_rates")
    }

    override func tearDown() {
        // No settings restored here: teardown blocks run before this, so writing the singleton's
        // values back would land on top of the snapshot's restore.
        spendDefaults.removePersistentDomain(forName: spendSuiteName)
        spendDefaults = nil
        spendStore = nil
        super.tearDown()
    }

    func testPaymentPinDoesNotChangeEligibleQuickpayRoute() {
        settings.pinEnabled = true
        settings.requirePinForPayments = true

        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .quickpay)
    }

    func testContactPaymentErrorsDoNotExposeSdkDetails() {
        for error: Error in [
            PaykitError.ConcurrentUpdate(code: "concurrent_update", context: "peer operation in progress"),
            PaykitError.SharedStateBusy(code: "shared_state_busy", context: "pending write"),
            PaykitError.Transport(code: "transport", context: "private request failed"),
        ] {
            XCTAssertEqual(PaymentNavigationHelper.contactPaymentErrorDescription(error), t("other__try_again"))
            XCTAssertEqual(PaymentNavigationHelper.contactPaymentErrorDescription(Bitkit.AppError(error: error)), t("other__try_again"))
        }
        XCTAssertNil(PaymentNavigationHelper.contactPaymentErrorDescription(CancellationError()))
        XCTAssertNil(PaymentNavigationHelper.contactPaymentErrorDescription(Bitkit.AppError(error: CancellationError())))
        let error = PrivatePaykitError.invalidPublicKey
        XCTAssertEqual(PaymentNavigationHelper.contactPaymentErrorDescription(error), error.localizedDescription)
    }

    func testEligibleInvoiceUsesQuickpayUnderDailyCap() {
        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .quickpay)
    }

    func testSkipsQuickpayWhenDailySpendCapIsExceeded() throws {
        let rates = QuickPaySpendRates.live(CurrencyViewModel(currencyService: OfflineCurrencyService()))
        for i in 0 ..< 5 {
            XCTAssertNotNil(
                try spendStore.reserveBound(
                    paymentHash: "cap\(i)",
                    amountSats: 5000,
                    thresholdUsd: 5,
                    multiplier: 5,
                    rates: rates
                )
            )
        }

        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .confirm)
    }

    func testAllowsQuickpayWhenSpendPlusAmountEqualsDailyCap() throws {
        let rates = QuickPaySpendRates.live(CurrencyViewModel(currencyService: OfflineCurrencyService()))
        for i in 0 ..< 4 {
            XCTAssertNotNil(try spendStore.reserveBound(paymentHash: "under\(i)", amountSats: 5000, thresholdUsd: 5, multiplier: 5, rates: rates))
        }
        XCTAssertNotNil(try spendStore.reserveBound(paymentHash: "under4", amountSats: 4000, thresholdUsd: 5, multiplier: 5, rates: rates))

        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .quickpay)
    }

    func testUsesQuickpayWhenHashIsAlreadyOpenEvenIfDisabled() throws {
        settings.enableQuickpay = false
        let hash = "aabbccdd"
        XCTAssertNotNil(
            try spendStore.reserveBound(
                paymentHash: hash,
                amountSats: 1000,
                thresholdUsd: 5,
                multiplier: 5,
                rates: QuickPaySpendRates.live(CurrencyViewModel(currencyService: OfflineCurrencyService()))
            )
        )
        let coordinator = QuickPayPaymentCoordinator(store: spendStore, sendBolt11: { _ in hash }, listRows: { [] })

        XCTAssertEqual(sendRoute(for: appWithInvoice(paymentHash: hash), coordinator: coordinator), .quickpay)
    }

    func testUsesQuickpayWhenHashIsOpenEvenIfDailyCapIsExceeded() throws {
        settings.quickpayDailyLimitMultiplier = 1
        let rates = QuickPaySpendRates.live(CurrencyViewModel(currencyService: OfflineCurrencyService()))
        let hash = "aabbccdd"
        XCTAssertNotNil(try spendStore.reserveBound(paymentHash: hash, amountSats: 1000, thresholdUsd: 5, multiplier: 1, rates: rates))
        XCTAssertNotNil(try spendStore.reserveBound(paymentHash: "cap0", amountSats: 4000, thresholdUsd: 5, multiplier: 1, rates: rates))
        let coordinator = QuickPayPaymentCoordinator(store: spendStore, sendBolt11: { _ in hash }, listRows: { [] })

        XCTAssertEqual(sendRoute(for: appWithInvoice(paymentHash: hash), coordinator: coordinator), .quickpay)
    }

    func testContactPaymentSkipsQuickpayEvenWhenHashIsOpen() throws {
        let hash = "c0c0c0c0"
        XCTAssertNotNil(
            try spendStore.reserveBound(
                paymentHash: hash,
                amountSats: 1000,
                thresholdUsd: 5,
                multiplier: 5,
                rates: QuickPaySpendRates.live(CurrencyViewModel(currencyService: OfflineCurrencyService()))
            )
        )
        let coordinator = QuickPayPaymentCoordinator(store: spendStore, sendBolt11: { _ in hash }, listRows: { [] })
        let app = appWithInvoice(paymentHash: hash)

        XCTAssertEqual(
            PaymentNavigationHelper.contactPaymentRoute(
                app: app,
                currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                settings: settings,
                spendStore: spendStore,
                coordinator: coordinator
            ),
            .confirm
        )
    }

    func testIncomingRequestWithAmountlessLightningInvoiceOpensConfirm() throws {
        let app = appWithInvoice(paymentHash: "incoming", amountSatoshis: 0)
        app.contactPaymentContext = try ContactPaymentContext(
            publicKey: "pubkycontact",
            incomingPaymentRequest: incomingPaymentRequest(
                endpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
            )
        )

        XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
    }

    func testIncomingRequestWithAmountlessOnchainInvoiceOpensConfirm() throws {
        let app = AppViewModel()
        app.scannedOnchainInvoice = OnChainInvoice(
            address: "bcrt1qexample",
            amountSatoshis: 0,
            label: nil,
            message: nil,
            params: nil
        )
        app.contactPaymentContext = try ContactPaymentContext(
            publicKey: "pubkycontact",
            incomingPaymentRequest: incomingPaymentRequest(
                endpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
            )
        )

        XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
    }

    func testFixedDollarRequestPreparesExactBitcoinTermsForConfirmation() async throws {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let method = PublicPaykitService.onchainMethodId(for: address)
        let request = try incomingPaymentRequest(
            endpointIdentifier: method.rawValue,
            amount: PaymentRequestAmount(value: "2.50", asset: "usd"),
            conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.00001")])
        )
        for enabled in [false, true] {
            settings.usdtPreference = enabled ? .enabled : .disabled
            let app = AppViewModel()
            let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [
                .init(methodId: method, value: address, min: nil, max: nil, rawPayload: ""),
            ])
            XCTAssertTrue(app.claimContactPaymentContext(context))
            try await app.handleScannedData(address, claimedContactPaymentContext: context)

            XCTAssertEqual(app.paykitPaymentTerms?.amount.atomic, 2500)
            XCTAssertEqual(app.paykitReviewedAmount, app.paykitPaymentTerms?.amount)
            XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
            XCTAssertFalse(app.paykitUsesUsdt)
            XCTAssertTrue(request.acceptsPaymentAmount(2500, method: method, paymentTerms: app.paykitPaymentTerms))
            XCTAssertFalse(request.acceptsPaymentAmount(2501, method: method, paymentTerms: app.paykitPaymentTerms))
            app.resetSendState()
            XCTAssertNil(app.paykitPaymentTerms)
            XCTAssertNil(app.paykitReviewedAmount)
        }
    }

    func testQuotedLnurlRequestConfirmsWithSavingsAvailable() throws {
        settings.usdtPreference = .disabled
        let lightning = PublicPaykitService.MethodId.bitcoinLightningLnurl
        let onchain = PublicPaykitService.MethodId.regtestOnchainP2wpkh
        for offersSavings in [false, true] {
            let request = try incomingPaymentRequest(
                endpointIdentifier: lightning.rawValue,
                additionalEndpointIdentifiers: offersSavings ? [onchain.rawValue] : [],
                amount: PaymentRequestAmount(value: "2.50", asset: "usd"),
                conversion: .fixed(rates: [
                    ConversionRate(asset: "btc-lightning", value: "0.00001"),
                    ConversionRate(asset: "btc-regtest", value: "0.00002"),
                ])
            )
            let app = AppViewModel()
            app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            app.lnurlPayData = LnurlPayData(
                uri: "https://example.com/pay", callback: "https://example.com/callback",
                minSendable: 1000, maxSendable: 100_000_000,
                metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
            )
            app.selectedWalletToPayFrom = .lightning
            app.paykitPaymentTerms = try request.payment(using: lightning)
            app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
            XCTAssertEqual(app.paykitReviewedAmount?.atomic, 2500)
            if offersSavings {
                app.scannedOnchainInvoice = OnChainInvoice(
                    address: "bcrt1qexample", amountSatoshis: 0, label: nil, message: nil, params: nil
                )
                XCTAssertEqual(try request.payment(using: onchain).amount.atomic, 5000)
            }
            XCTAssertEqual(contactPaymentRoute(for: app), .lnurlPayConfirm)
            XCTAssertTrue(SendSheet.requiresLightningReadiness(app: app))
            let limits: [(UInt64, UInt64, SendRoute)] = [
                (2_500_001, 100_000_000, .amount),
                (1000, 2_499_999, .amount),
                (2_500_000, 2_500_000, .lnurlPayConfirm),
            ]
            for (minimum, maximum, route) in limits {
                app.lnurlPayData = LnurlPayData(
                    uri: "https://example.com/pay", callback: "https://example.com/callback",
                    minSendable: minimum, maxSendable: maximum,
                    metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
                )
                XCTAssertEqual(contactPaymentRoute(for: app), route)
            }
            if offersSavings {
                app.selectedWalletToPayFrom = .onchain
                XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
                XCTAssertFalse(SendSheet.requiresLightningReadiness(app: app))
            }
        }
    }

    func testMixedRequestRoutesBeforeOpeningLnurlConfirmation() throws {
        let lightning = PublicPaykitService.MethodId.bitcoinLightningLnurl
        let onchain = PublicPaykitService.MethodId.regtestOnchainP2wpkh
        let request = try incomingPaymentRequest(
            endpointIdentifier: lightning.rawValue, additionalEndpointIdentifiers: [onchain.rawValue],
            amount: PaymentRequestAmount(value: "0.00005", asset: "btc")
        )
        let app = AppViewModel()
        app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
        app.scannedOnchainInvoice = OnChainInvoice(address: "bcrt1qexample", amountSatoshis: 0, label: nil, message: nil, params: nil)
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback", minSendable: 10_000_000, maxSendable: 100_000_000,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        app.paykitRoute = PaykitRouteUi(
            endpoints: [PaykitEndpoint(methodId: onchain.rawValue, value: "bcrt1qexample")], offersSparkLeg: true
        )
        app.paykitPaymentTerms = try request.payment(using: lightning)
        app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
        let wallet = WalletViewModel()
        let hwSend = HwSendCoordinator()
        let flow = SendPresentationState(initialRoute: .confirm)
        flow.isSetupPending = false

        flow.selectRequestFundingSource(.spending, app: app, wallet: wallet, hwSend: hwSend)

        XCTAssertEqual(flow.rootRoute, .confirm, "Confirm must ask the router before a direct LNURL can preempt the Spark leg")
        XCTAssertTrue(flow.navigationPath.isEmpty)
        XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
        XCTAssertEqual(wallet.sendAmountSats, 5000)
        XCTAssertEqual(app.paykitMinimumBitcoinAmount, UInt64(Env.dustLimit))
        XCTAssertTrue(
            SendSheet.defersLightningValidationToRequestRouter(app: app),
            "LNURL range, balance and channel sync must not preempt the router"
        )
        app.paykitUsesUsdt = true
        XCTAssertFalse(SendSheet.defersLightningValidationToRequestRouter(app: app))
        app.paykitUsesUsdt = false
        app.paykitRoute = nil
        XCTAssertFalse(SendSheet.defersLightningValidationToRequestRouter(app: app))
        XCTAssertEqual(app.paykitMinimumBitcoinAmount, 10000)
        XCTAssertEqual(contactPaymentRoute(for: app), .amount, "Without Spark the LNURL minimum still applies")
    }

    func testNativeBitcoinLnurlRequestConfirmsWithoutCachedTerms() throws {
        let request = try incomingPaymentRequest(
            endpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningLnurl.rawValue
        )
        let app = AppViewModel()
        app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 1_000_000, maxSendable: 1_000_000,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        app.selectedWalletToPayFrom = .lightning

        XCTAssertNil(app.paykitPaymentTerms)
        XCTAssertEqual(contactPaymentRoute(for: app), .lnurlPayConfirm)
    }

    func testDollarRequestConfirmsWhetherUsdtIsEnabled() async throws {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let method = PublicPaykitService.onchainMethodId(for: address)
        let request = try incomingPaymentRequest(
            endpointIdentifier: method.rawValue,
            amount: PaymentRequestAmount(value: "2.50", asset: "usd"),
            conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.00001")])
        )
        for enabled in [false, true] {
            settings.usdtPreference = enabled ? .enabled : .disabled
            let app = AppViewModel()
            let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [
                .init(methodId: method, value: address, min: nil, max: nil, rawPayload: ""),
                .init(methodId: .usdtArbitrum, value: "0x1111111111111111111111111111111111111111", min: nil, max: nil, rawPayload: ""),
            ])
            XCTAssertTrue(app.claimContactPaymentContext(context))
            try await app.handleScannedData(address, claimedContactPaymentContext: context)
            XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
            XCTAssertNotNil(app.paykitPaymentTerms)
        }
    }

    func testUsdtRequestConfirmationDoesNotUseLightningMinimum() async throws {
        settings.usdtPreference = .enabled
        let lightning = PublicPaykitService.MethodId.bitcoinLightningLnurl
        let usdt = try PaykitUsdt.endpoint(address: "0x1111111111111111111111111111111111111111")
        let request = try incomingPaymentRequest(
            endpointIdentifier: lightning.rawValue,
            additionalEndpointIdentifiers: [usdt.methodId.rawValue],
            amount: PaymentRequestAmount(value: "1", asset: "usd"),
            conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.00001"), ConversionRate(asset: "usdt", value: "1")])
        )
        let lnurl = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 2_000_000_000, maxSendable: 3_000_000_000,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: { ScanPaymentState(isNodeRunning: true, spendableOnchainBalanceSats: 0,
                                          totalLightningBalanceSats: 0, hasChannels: false, hasUsableChannels: false) },
                canSendLightning: { _ in false },
                decodeInvoice: { _ in .lnurlPay(data: lnurl) }
            ), usdtBalance: { 1_000_000 }
        )
        let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [
            .init(methodId: lightning, value: lnurl.uri, min: nil, max: nil, rawPayload: ""), usdt,
        ])
        XCTAssertTrue(app.claimContactPaymentContext(context))
        try await app.handleScannedData(lnurl.uri, claimedContactPaymentContext: context)

        XCTAssertTrue(app.paykitUsesUsdt)
        XCTAssertEqual(app.paykitPaymentTerms?.amount.atomic, 1_000_000)
        XCTAssertEqual(app.paykitReviewedAmount, app.paykitPaymentTerms?.amount)
        XCTAssertEqual(contactPaymentRoute(for: app), .usdt(recipient: usdt.value, amount: "1.00"))
    }

    func testRequestSourceSwitchPreservesAmountBackRouteAcrossAssets() throws {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let method = PublicPaykitService.onchainMethodId(for: address)
        let usdt = try PaykitUsdt.endpoint(address: "0x1111111111111111111111111111111111111111")
        let request = try incomingPaymentRequest(
            endpointIdentifier: method.rawValue, additionalEndpointIdentifiers: [usdt.methodId.rawValue],
            amount: PaymentRequestAmount(value: "2.50", asset: "usd"),
            conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.00001"), ConversionRate(asset: "usdt", value: "1")])
        )
        let app = AppViewModel()
        let wallet = WalletViewModel()
        let hwSend = HwSendCoordinator()
        app.scannedOnchainInvoice = OnChainInvoice(address: address, amountSatoshis: 0, label: nil, message: nil, params: nil)
        app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [
            .init(methodId: method, value: address, min: nil, max: nil, rawPayload: ""), usdt,
        ])
        for amountIsRoot in [true, false] {
            let flow = SendPresentationState(initialRoute: .confirm)
            flow.rootOverride = amountIsRoot ? .amount : nil
            flow.navigationPath = [.utxoSelection, .confirm]
            flow.isSetupPending = false

            flow.selectRequestFundingSource(.usdt, app: app, wallet: wallet, hwSend: hwSend)
            let usdtRoute = SendRoute.usdt(recipient: usdt.value, amount: "2.50")
            XCTAssertEqual(flow.navigationPath, amountIsRoot ? [usdtRoute] : [])
            XCTAssertEqual(flow.rootOverride ?? flow.rootRoute, amountIsRoot ? .amount : usdtRoute)
            XCTAssertEqual(app.paykitReviewedAmount?.asset, .usdt)
            XCTAssertNil(wallet.sendAmountSats)

            flow.selectRequestFundingSource(.savings, app: app, wallet: wallet, hwSend: hwSend)
            XCTAssertEqual(flow.navigationPath, amountIsRoot ? [.confirm] : [])
            XCTAssertEqual(flow.rootOverride ?? flow.rootRoute, amountIsRoot ? .amount : .confirm)
            XCTAssertEqual(app.paykitReviewedAmount, try request.payment(using: method).amount)
            XCTAssertEqual(wallet.sendAmountSats, app.paykitReviewedAmount?.atomic)
            XCTAssertNil(wallet.selectedUtxos, "Returning to Savings must prepare coins for the newly bound amount")
            if amountIsRoot {
                flow.navigationPath.removeLast()
                XCTAssertTrue(flow.navigationPath.isEmpty)
                XCTAssertEqual(flow.rootOverride, .amount)
            }
        }
    }

    func testExpiredDollarRequestOpensRateReview() async throws {
        settings.usdtPreference = .disabled
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let method = PublicPaykitService.onchainMethodId(for: address)
        let request = try incomingPaymentRequest(
            endpointIdentifier: method.rawValue,
            amount: PaymentRequestAmount(value: "2.50", asset: "usd"),
            conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.00001")]),
            deadline: .at(timestamp: "2020-01-01T00:00:00Z")
        )
        let app = AppViewModel()
        let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [
            .init(methodId: method, value: address, min: nil, max: nil, rawPayload: ""),
        ])
        XCTAssertTrue(app.claimContactPaymentContext(context))
        try await app.handleScannedData(address, claimedContactPaymentContext: context)
        XCTAssertNil(app.paykitPaymentTerms)
        XCTAssertNil(app.paykitReviewedAmount)
        XCTAssertEqual(contactPaymentRoute(for: app), .amount)
    }

    func testDollarRequestWithoutConversionOpensRateReview() async throws {
        settings.usdtPreference = .disabled
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let method = PublicPaykitService.onchainMethodId(for: address)
        let request = try incomingPaymentRequest(
            endpointIdentifier: method.rawValue,
            amount: PaymentRequestAmount(value: "2.50", asset: "usd")
        )
        let app = AppViewModel()
        let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, endpoints: [
            .init(methodId: method, value: address, min: nil, max: nil, rawPayload: ""),
        ])
        XCTAssertTrue(app.claimContactPaymentContext(context))
        try await app.handleScannedData(address, claimedContactPaymentContext: context)
        XCTAssertNil(app.paykitPaymentTerms)
        XCTAssertNil(app.paykitReviewedAmount)
        XCTAssertEqual(contactPaymentRoute(for: app), .amount)
        XCTAssertThrowsError(try request.payment(using: method)) { error in
            XCTAssertEqual(error as? PaykitAmountError, .rateUnavailable)
        }
    }

    func testOnchainInvoiceWithAmountOpensConfirm() {
        let app = appWithOnchainInvoice(amountSatoshis: 10000)

        XCTAssertEqual(sendRoute(for: app), .confirm)
        XCTAssertEqual(paymentSheetRoute(for: app), .confirm)
    }

    func testOnchainInvoiceWithoutAmountOpensAmount() {
        let app = appWithOnchainInvoice(amountSatoshis: 0)

        XCTAssertEqual(sendRoute(for: app), .amount)
        XCTAssertEqual(paymentSheetRoute(for: app), .amount)
    }

    func testScannedOnchainAmountBelowMinimumIsRejected() async throws {
        let app = AppViewModel()
        try await app.handleScannedData("bitcoin:bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x?amount=0.000005")
        XCTAssertTrue(app.didRejectScannedPayment)
    }

    func testOnchainInvoiceBelowMinimumOpensAmount() {
        let app = appWithOnchainInvoice(amountSatoshis: UInt64(Env.dustLimit) - 1)

        XCTAssertEqual(sendRoute(for: app), .amount)
        XCTAssertEqual(paymentSheetRoute(for: app), .amount)
    }

    func testOnchainInvoiceAtMinimumOpensConfirm() {
        let app = appWithOnchainInvoice(amountSatoshis: UInt64(Env.dustLimit))

        XCTAssertEqual(sendRoute(for: app), .confirm)
    }

    func testOnchainInvoiceWithAmountSkipsQuickpay() {
        let app = appWithOnchainInvoice(amountSatoshis: 1000)

        XCTAssertEqual(sendRoute(for: app), .confirm)
    }

    func testContactOnchainInvoiceWithAmountKeepsAmount() {
        let app = appWithOnchainInvoice(amountSatoshis: 10000)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "pubkycontact", endpoints: [])

        XCTAssertEqual(contactPaymentRoute(for: app), .amount)
    }

    func testIncomingRequestWithOnchainAmountOpensConfirm() throws {
        let app = appWithOnchainInvoice(amountSatoshis: 1000)
        app.contactPaymentContext = try ContactPaymentContext(
            publicKey: "pubkycontact",
            incomingPaymentRequest: incomingPaymentRequest(
                endpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
            )
        )

        XCTAssertEqual(contactPaymentRoute(for: app), .confirm)
    }

    func testContactWithUsdtLocksOnlyFixedLightningFunding() {
        let app = appWithInvoice(paymentHash: "fixed", amountSatoshis: 10000)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "pubkycontact", endpoints: [
            .init(methodId: .usdtArbitrum, value: "0x1111111111111111111111111111111111111111", min: nil, max: nil, rawPayload: ""),
        ])
        XCTAssertEqual(contactPaymentRoute(for: app), .amount)
        app.selectedWalletToPayFrom = .lightning
        XCTAssertEqual(app.fixedLightningAmountSats, 10000)
        app.paykitUsesUsdt = true
        XCTAssertNil(app.fixedLightningAmountSats)
        app.paykitUsesUsdt = false
        app.selectedWalletToPayFrom = .onchain
        XCTAssertNil(app.fixedLightningAmountSats)
        app.selectedWalletToPayFrom = .lightning
        XCTAssertEqual(app.fixedLightningAmountSats, 10000)
        app.scannedLightningInvoice = appWithInvoice(paymentHash: "amountless", amountSatoshis: 0).scannedLightningInvoice
        XCTAssertNil(app.fixedLightningAmountSats)
    }

    func testReserveRaceFallsBackToConfirm() {
        XCTAssertEqual(
            PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: appWithEligibleInvoice),
            .confirm
        )
    }

    func testReplacingQuickPayRootLeavesConfirmWithoutABackTarget() {
        let next = PaymentNavigationHelper.replacingQuickPay(in: [], root: .quickpay, with: .confirm)

        XCTAssertEqual(next.root, .confirm)
        XCTAssertTrue(next.path.isEmpty)
    }

    func testReplacingQuickPayOnThePathKeepsTheExistingRoot() {
        let next = PaymentNavigationHelper.replacingQuickPay(
            in: [.amount, .quickpay],
            root: .options,
            with: .confirm
        )

        XCTAssertEqual(next.root, .options)
        XCTAssertEqual(next.path, [.amount, .confirm])
    }

    private func sendRoute(for app: AppViewModel, coordinator: QuickPayPaymentCoordinator? = nil) -> SendRoute? {
        PaymentNavigationHelper.appropriateSendRoute(
            app: app,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: settings,
            spendStore: spendStore,
            coordinator: coordinator
        )
    }

    private func contactPaymentRoute(for app: AppViewModel) -> SendRoute? {
        PaymentNavigationHelper.contactPaymentRoute(
            app: app,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: settings,
            spendStore: spendStore
        )
    }

    private func paymentSheetRoute(for app: AppViewModel) -> SendRoute? {
        let sheets = SheetViewModel()
        PaymentNavigationHelper.openPaymentSheet(
            app: app,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: settings,
            sheetViewModel: sheets,
            spendStore: spendStore
        )
        return (sheets.activeSheetConfiguration?.data as? SendConfig)?.initialRoute
    }

    private func appWithOnchainInvoice(amountSatoshis: UInt64) -> AppViewModel {
        let app = AppViewModel()
        app.scannedOnchainInvoice = OnChainInvoice(
            address: "bcrt1qexample",
            amountSatoshis: amountSatoshis,
            label: nil,
            message: nil,
            params: nil
        )
        return app
    }

    private var appWithEligibleInvoice: AppViewModel {
        appWithInvoice(paymentHash: "")
    }

    private func appWithInvoice(paymentHash: String, amountSatoshis: UInt64 = 1000) -> AppViewModel {
        let app = AppViewModel()
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: "test-invoice",
            paymentHash: paymentHash.hexaData,
            amountSatoshis: amountSatoshis,
            timestampSeconds: 0,
            expirySeconds: 0,
            isExpired: false,
            description: nil,
            networkType: .regtest,
            payeeNodeId: nil
        )
        return app
    }

    func testEmbeddedSubscriptionRetryRestoresSelectedRailAmount() throws {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let onchain = PublicPaykitService.onchainMethodId(for: address)
        let usdt = try PaykitUsdt.endpoint(address: "0x1111111111111111111111111111111111111111")
        let period = PaykitBillingPeriod(startsAt: Date().addingTimeInterval(-60), endsAt: Date().addingTimeInterval(86400))
        for method in [PublicPaykitService.MethodId.bitcoinLightningBolt11, .bitcoinLightningLnurl, onchain, .usdtArbitrum] {
            let request = try incomingPaymentRequest(
                endpointIdentifier: method.rawValue,
                amount: PaymentRequestAmount(value: "2.50", asset: "usd"),
                conversion: .fixed(rates: [ConversionRate(asset: "btc-lightning", value: "0.00001"),
                                           ConversionRate(asset: "btc-regtest", value: "0.00002"),
                                           ConversionRate(asset: "usdt", value: "1")]),
                billingPeriod: period
            )
            let app = appWithInvoice(paymentHash: "retry", amountSatoshis: 0)
            app.scannedOnchainInvoice = OnChainInvoice(address: address, amountSatoshis: 0, label: nil, message: nil, params: nil)
            if method == .bitcoinLightningLnurl {
                app.lnurlPayData = LnurlPayData(uri: "https://example.com/pay", callback: "https://example.com/callback",
                                                minSendable: 1000, maxSendable: 100_000_000, metadataStr: "[]",
                                                commentAllowed: nil, allowsNostr: false, nostrPubkey: nil)
            }
            app.selectedWalletToPayFrom = method == onchain ? .onchain : .lightning
            app.paykitUsesUsdt = method == .usdtArbitrum
            let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request,
                                                isInitialSubscriptionPayment: true, endpoints: [usdt])
            app.contactPaymentContext = context
            XCTAssertTrue(context.requiresAssetSelection)
            let flow = SendPresentationState(initialRoute: .confirm)
            let wallet = WalletViewModel()
            // The retry has reset the wallet; scanning has bound the selected rail's terms.
            app.paykitPaymentTerms = try request.payment(using: method)
            app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
            try flow.prepareEmbeddedRetry(context: context, app: app, wallet: wallet)
            let expectedRoute: SendRoute = switch method {
            case .usdtArbitrum: .usdt(recipient: usdt.value, amount: "2.5")
            case .bitcoinLightningLnurl: .lnurlPayConfirm
            default: .confirm
            }
            XCTAssertEqual(flow.pendingEmbeddedRetryRoute, expectedRoute, method.rawValue)
            XCTAssertEqual(wallet.sendAmountSats, method == .usdtArbitrum ? nil : (method == onchain ? 5000 : 2500), method.rawValue)

            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
            app.paykitPaymentTerms = nil
            app.paykitReviewedAmount = nil
            if method != .usdtArbitrum {
                try flow.prepareEmbeddedRetry(context: context, app: app, wallet: wallet)
                XCTAssertEqual(flow.pendingEmbeddedRetryRoute, .amount, "An unbound quote must still be reviewed")
                XCTAssertNil(wallet.sendAmountSats)
            }
        }
    }

    func testEmbeddedSubscriptionRetryKeepsTheBoundPeriodQuote() throws {
        let now = Date()
        let period = PaykitBillingPeriod(startsAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(86400))
        let first = PaymentConversionQuoteRecord(eventId: "first", billingPeriod: period.sdkValue,
                                                 rates: [ConversionRate(asset: "btc", value: "0.00001")],
                                                 validFrom: period.sdkValue.startsAt, expiresAt: period.sdkValue.endsAt, outboundStatus: nil)
        var newer = first
        newer.eventId = "newer"
        newer.rates = [ConversionRate(asset: "btc", value: "0.00002")]
        let request = try incomingPaymentRequest(endpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                                                 amount: PaymentRequestAmount(value: "2.50", asset: "usd"), conversion: .perPeriod,
                                                 billingPeriod: period, quotes: [first, newer])
        let app = appWithInvoice(paymentHash: "period-retry", amountSatoshis: 0)
        app.selectedWalletToPayFrom = .lightning
        let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request, isInitialSubscriptionPayment: true)
        app.contactPaymentContext = context
        app.paykitPaymentTerms = try request.payment(using: .bitcoinLightningBolt11, quoteId: "first")
        app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
        let wallet = WalletViewModel()
        let flow = SendPresentationState(initialRoute: .confirm)

        try flow.prepareEmbeddedRetry(context: context, app: app, wallet: wallet)

        XCTAssertEqual(flow.pendingEmbeddedRetryRoute, .confirm)
        XCTAssertEqual(wallet.sendAmountSats, 2500)
        XCTAssertEqual(app.paykitPaymentTerms?.quoteId, "first")
        XCTAssertEqual(app.paykitReviewedAmount?.atomic, 2500)
    }

    private func incomingPaymentRequest(
        endpointIdentifier: String,
        additionalEndpointIdentifiers: [String] = [],
        amount: PaymentRequestAmount = PaymentRequestAmount(value: "0.00001", asset: "btc"),
        conversion: PaymentConversion? = nil,
        deadline: PaymentDeadline? = nil,
        billingPeriod: PaykitBillingPeriod? = nil,
        quotes: [PaymentConversionQuoteRecord] = []
    ) throws -> PaykitPaymentRequest {
        let record = try PaymentRequestRecord(
            counterparty: "pubkycontact",
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440000",
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            proposalAppId: "bitkit",
            proposalRecordedAt: nil,
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: amount,
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: billingPeriod.map { PaymentRequestRecurrence(every: 1, unit: "day", startsAt: $0.sdkValue.startsAt,
                                                                         anchor: $0.sdkValue.startsAt, endsAt: nil) },
                acceptedPaymentEndpointIdentifiers: [endpointIdentifier] + additionalEndpointIdentifiers,
                paymentEndpoints: nil,
                requiredAppId: "bitkit",
                conversion: conversion,
                paymentDeadline: deadline,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            acceptanceRecordedAt: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: quotes,
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
        if let billingPeriod {
            let subscription = try XCTUnwrap(PaykitSubscription(record: record))
            return PaykitPaymentRequest(subscription: subscription, billingPeriod: billingPeriod, lifecycleState: .accepted)
        }
        return try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date(timeIntervalSince1970: 0)))
    }

    private var usdRate: FxRate {
        FxRate(
            symbol: "BTCUSD",
            lastPrice: "100000",
            base: "BTC",
            baseName: "Bitcoin",
            quote: "USD",
            quoteName: "US Dollar",
            currencySymbol: "$",
            currencyFlag: "🇺🇸",
            lastUpdatedAt: 0
        )
    }
}
