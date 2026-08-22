@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

@MainActor
final class QuickPayPaymentCoordinatorTests: XCTestCase {
    private let settings = SettingsViewModel.shared
    private var originalEnableQuickpay = false
    private var originalQuickpayAmount: Double = 0
    private var originalQuickpayDailyLimitMultiplier: Double = 0
    private var originalCachedRates: Data?
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: QuickPaySpendStore!
    private let rates = QuickPaySpendRates(
        satsToUsdCents: { sats in Int64(sats) / 2 },
        usdToSats: { usd in UInt64(usd * 200) }
    )

    override func setUp() {
        super.setUp()
        originalEnableQuickpay = settings.enableQuickpay
        originalQuickpayAmount = settings.quickpayAmount
        originalQuickpayDailyLimitMultiplier = settings.quickpayDailyLimitMultiplier
        originalCachedRates = UserDefaults.standard.data(forKey: "cached_fx_rates")
        suiteName = "QuickPayPaymentCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = QuickPaySpendStore(defaults: defaults, dayKey: { "2026-08-15" })
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
        if let originalCachedRates {
            UserDefaults.standard.set(originalCachedRates, forKey: "cached_fx_rates")
        } else {
            UserDefaults.standard.removeObject(forKey: "cached_fx_rates")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testDuplicatePaymentIsHardReject() {
        XCTAssertTrue(QuickPayPaymentCoordinator.isHardReject(NodeError.DuplicatePayment(message: "dup")))
    }

    func testInvalidInvoiceIsHardReject() {
        XCTAssertTrue(QuickPayPaymentCoordinator.isHardReject(NodeError.InvalidInvoice(message: "bad")))
    }

    func testPersistenceIsNotHardReject() {
        XCTAssertFalse(QuickPayPaymentCoordinator.isHardReject(NodeError.PersistenceFailed(message: "io")))
    }

    func testLeftoverRecordGoesPendingWithoutSending() async throws {
        let invoiceHash = try Self.invoiceHash
        var sent = false
        XCTAssertNotNil(
            try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: 1000,
                thresholdUsd: 5,
                multiplier: 5,
                rates: rates
            )
        )

        let route = await firstRoute(
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            }
        )

        XCTAssertFalse(sent)
        guard case let .pending(paymentHash, retryRoute, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertEqual(retryRoute, .quickpay)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testSendAfterTerminalGoesToSuccess() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { [store] _ in
                store?.noteTerminal(paymentId: nil, paymentHash: invoiceHash, success: true)
                return invoiceHash
            }
        )

        guard case let .success(paymentId) = route else {
            return XCTFail("Expected success, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentId, invoiceHash)
        XCTAssertNil(store.record(matching: invoiceHash))
    }

    func testAmbiguousDispatchWithOpenRecordGoesPending() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.PersistenceFailed(message: "io")
            }
        )

        guard case let .pending(paymentHash, retryRoute, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertEqual(retryRoute, .quickpay)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testAmbiguousDispatchWithFailedRowGoesToFailure() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.PersistenceFailed(message: "io")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .failed
                    ),
                ]
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
    }

    func testDuplicateDispatchGoesToFailureAndReleases() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.DuplicatePayment(message: "dup")
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    private func firstRoute(
        sendBolt11: @escaping (String) async throws -> String,
        listRows: @escaping () async -> [QuickPayReconcileRow]? = { [] }
    ) async -> SendRoute? {
        let coordinator = QuickPayPaymentCoordinator(store: store, sendBolt11: sendBolt11, listRows: listRows)
        var route: SendRoute?
        let exp = expectation(description: "route")
        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(),
            presentation: QuickPayPaymentCoordinator.Presentation(
                appendRoute: {
                    route = $0
                    exp.fulfill()
                },
                replaceQuickPay: { _ in },
                addPendingPaymentHash: { _ in },
                routingCacheResetAttempted: false
            )
        )
        await fulfillment(of: [exp], timeout: 2)
        return route
    }

    private var appWithInvoice: AppViewModel {
        let app = AppViewModel()
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: Self.regtestBolt11,
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

    private static var invoiceHash: String {
        get throws {
            try String(Bolt11Invoice.fromStr(invoiceStr: regtestBolt11).paymentHash())
        }
    }

    private static let regtestBolt11 =
        "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"
}
