@testable import Bitkit
import BitkitCore
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

    private func sendRoute(for app: AppViewModel) -> SendRoute? {
        PaymentNavigationHelper.appropriateSendRoute(
            app: app,
            currency: CurrencyViewModel(),
            settings: settings,
            spendStore: spendStore
        )
    }

    private var appWithEligibleInvoice: AppViewModel {
        let app = AppViewModel()
        app.scannedLightningInvoice = LightningInvoice(
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
        return app
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
