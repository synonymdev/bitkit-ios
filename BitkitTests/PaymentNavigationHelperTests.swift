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

    private func incomingPaymentRequest(
        endpointIdentifier: String,
        additionalEndpointIdentifiers: [String] = [],
        amount: PaymentRequestAmount = PaymentRequestAmount(value: "0.00001", asset: "btc"),
        conversion: PaymentConversion? = nil,
        deadline: PaymentDeadline? = nil
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
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: amount,
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: [endpointIdentifier] + additionalEndpointIdentifiers,
                paymentEndpoints: nil,
                requiredAppId: "bitkit",
                conversion: conversion,
                paymentDeadline: deadline,
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
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
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
