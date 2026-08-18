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

    func testSkipsQuickpayWhenDailySpendCapIsExceeded() {
        // 1000 sats invoice; $5 × 5 = 25_000 sats at the test rate.
        spendStore.record(amountSats: 25000, dayKey: QuickPaySpendStore.dayKey())

        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .confirm)
    }

    func testAllowsQuickpayWhenSpendPlusAmountEqualsDailyCap() {
        spendStore.record(amountSats: 24000, dayKey: QuickPaySpendStore.dayKey())

        XCTAssertEqual(sendRoute(for: appWithEligibleInvoice), .quickpay)
    }

    func testReserveRaceFallsBackToConfirm() {
        XCTAssertEqual(
            PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: appWithEligibleInvoice),
            .confirm
        )
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
