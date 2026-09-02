@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

@MainActor
final class PaymentNavigationHelperTests: XCTestCase {
    private let settings = SettingsViewModel.shared
    private var originalEnableQuickpay = false
    private var originalQuickpayAmount: Double = 0
    private var originalQuickpayDailyLimitMultiplier: Double = 0
    private var originalPinEnabled = false
    private var originalRequirePinForPayments = false
    private var originalCachedRates: Data?
    private var spendDefaults: UserDefaults!
    private var spendSuiteName: String!
    private var spendStore: QuickPaySpendStore!

    override func setUp() {
        super.setUp()
        originalEnableQuickpay = settings.enableQuickpay
        originalQuickpayAmount = settings.quickpayAmount
        originalQuickpayDailyLimitMultiplier = settings.quickpayDailyLimitMultiplier
        originalPinEnabled = settings.pinEnabled
        originalRequirePinForPayments = settings.requirePinForPayments
        originalCachedRates = UserDefaults.standard.data(forKey: "cached_fx_rates")

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
        settings.enableQuickpay = originalEnableQuickpay
        settings.quickpayAmount = originalQuickpayAmount
        settings.quickpayDailyLimitMultiplier = originalQuickpayDailyLimitMultiplier
        settings.pinEnabled = originalPinEnabled
        settings.requirePinForPayments = originalRequirePinForPayments

        if let originalCachedRates {
            UserDefaults.standard.set(originalCachedRates, forKey: "cached_fx_rates")
        } else {
            UserDefaults.standard.removeObject(forKey: "cached_fx_rates")
        }

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

    func testEligibleInvoiceUsesQuickpayUnderDailyCap() {
        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .quickpay)
    }

    func testSkipsQuickpayWhenDailySpendCapIsExceeded() throws {
        let rates = QuickPaySpendRates.live(CurrencyViewModel())
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
        let rates = QuickPaySpendRates.live(CurrencyViewModel())
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
                rates: QuickPaySpendRates.live(CurrencyViewModel())
            )
        )
        let coordinator = QuickPayPaymentCoordinator(store: spendStore, sendBolt11: { _ in hash }, listRows: { [] })

        XCTAssertEqual(sendRoute(for: appWithInvoice(paymentHash: hash), coordinator: coordinator), .quickpay)
    }

    func testUsesQuickpayWhenHashIsOpenEvenIfDailyCapIsExceeded() throws {
        settings.quickpayDailyLimitMultiplier = 1
        let rates = QuickPaySpendRates.live(CurrencyViewModel())
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
                rates: QuickPaySpendRates.live(CurrencyViewModel())
            )
        )
        let coordinator = QuickPayPaymentCoordinator(store: spendStore, sendBolt11: { _ in hash }, listRows: { [] })
        let app = appWithInvoice(paymentHash: hash)

        XCTAssertEqual(
            PaymentNavigationHelper.contactPaymentRoute(
                app: app,
                currency: CurrencyViewModel(),
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
            currency: CurrencyViewModel(),
            settings: settings,
            spendStore: spendStore,
            coordinator: coordinator
        )
    }

    private func contactPaymentRoute(for app: AppViewModel) -> SendRoute? {
        PaymentNavigationHelper.contactPaymentRoute(
            app: app,
            currency: CurrencyViewModel(),
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

    private func incomingPaymentRequest(endpointIdentifier: String) throws -> PaykitPaymentRequest {
        let record = try PaymentRequestRecord(
            counterparty: "pubkycontact",
            counterpartyReceiverPath: "bitkit/wallet",
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440000",
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.00001", asset: "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: [endpointIdentifier],
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
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
