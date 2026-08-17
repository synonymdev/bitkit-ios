@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class PaymentNavigationHelperTests: XCTestCase {
    private let settings = SettingsViewModel.shared
    private var originalEnableQuickpay = false
    private var originalQuickpayAmount: Double = 0
    private var originalPinEnabled = false
    private var originalRequirePinForPayments = false
    private var originalCachedRates: Data?

    override func setUp() {
        super.setUp()
        originalEnableQuickpay = settings.enableQuickpay
        originalQuickpayAmount = settings.quickpayAmount
        originalPinEnabled = settings.pinEnabled
        originalRequirePinForPayments = settings.requirePinForPayments
        originalCachedRates = UserDefaults.standard.data(forKey: "cached_fx_rates")

        settings.enableQuickpay = true
        settings.quickpayAmount = 5
        guard let encodedRates = try? JSONEncoder().encode([usdRate]) else {
            XCTFail("Failed to encode the QuickPay test exchange rate")
            return
        }
        UserDefaults.standard.set(encodedRates, forKey: "cached_fx_rates")
    }

    override func tearDown() {
        settings.enableQuickpay = originalEnableQuickpay
        settings.quickpayAmount = originalQuickpayAmount
        settings.pinEnabled = originalPinEnabled
        settings.requirePinForPayments = originalRequirePinForPayments

        if let originalCachedRates {
            UserDefaults.standard.set(originalCachedRates, forKey: "cached_fx_rates")
        } else {
            UserDefaults.standard.removeObject(forKey: "cached_fx_rates")
        }
        super.tearDown()
    }

    func testPaymentPinDoesNotChangeEligibleQuickpayRoute() {
        settings.pinEnabled = true
        settings.requirePinForPayments = true

        XCTAssertEqual(
            PaymentNavigationHelper.appropriateSendRoute(
                app: appWithEligibleInvoice,
                currency: CurrencyViewModel(),
                settings: settings
            ),
            .quickpay
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
