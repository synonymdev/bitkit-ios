@testable import Bitkit
import XCTest

extension SettingsViewModel {
    /// Stores QuickPay settings the way a restore does, since their setters are private: write the defaults, then
    /// re-read them. A value left nil keeps the one the settings report now.
    func storeQuickpaySettings(enabled: Bool? = nil, amount: Double? = nil, dailyLimitMultiplier: Double? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(enabled ?? enableQuickpay, forKey: "enableQuickpay")
        defaults.set(amount ?? quickpayAmount, forKey: "quickpayAmount")
        defaults.set(dailyLimitMultiplier ?? quickpayDailyLimitMultiplier, forKey: "quickpayDailyLimitMultiplier")
        syncAppStorageFromDefaults()
    }
}

@MainActor
final class QuickpaySettingsTests: XCTestCase {
    private let settings = SettingsViewModel.shared
    private var originalPinEnabled = false

    override func setUp() {
        super.setUp()
        // Re-reading the stored settings writes every @AppStorage key, not only the QuickPay ones.
        snapshotAppDefaultsDomain()
        originalPinEnabled = settings.pinEnabled
        settings.storeQuickpaySettings(enabled: false, amount: 5, dailyLimitMultiplier: 5)
        settings.pinEnabled = true
        settings.requirePinForPayments = true
    }

    override func tearDown() {
        settings.pinEnabled = originalPinEnabled
        super.tearDown()
    }

    func testEnablingWaitsForApproval() async {
        let authorization = ControlledAuthorization()

        let pending = settings.changeQuickpaySetting(.enabled(true), authorize: { await authorization.authorize() })

        XCTAssertNotNil(pending)
        XCTAssertFalse(settings.enableQuickpay)
        authorization.resolve(true)
        await pending?.value
        XCTAssertTrue(settings.enableQuickpay)
        XCTAssertEqual(authorization.requestCount, 1)
    }

    func testRaisingAmountWaitsForApproval() async {
        let authorization = ControlledAuthorization()

        let pending = settings.changeQuickpaySetting(.amount(20), authorize: { await authorization.authorize() })

        XCTAssertNotNil(pending)
        XCTAssertEqual(settings.quickpayAmount, 5)
        authorization.resolve(true)
        await pending?.value
        XCTAssertEqual(settings.quickpayAmount, 20)
    }

    func testRaisingDailyLimitMultiplierWaitsForApproval() async {
        let authorization = ControlledAuthorization()

        let pending = settings.changeQuickpaySetting(.dailyLimitMultiplier(10), authorize: { await authorization.authorize() })

        XCTAssertNotNil(pending)
        XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 5)
        authorization.resolve(true)
        await pending?.value
        XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 10)
    }

    func testDeniedRaisesSaveNothing() async {
        for change in [QuickpaySettingChange.enabled(true), .amount(50), .dailyLimitMultiplier(50)] {
            let authorization = ControlledAuthorization()
            authorization.resolve(false)

            await settings.changeQuickpaySetting(change, authorize: { await authorization.authorize() })?.value

            XCTAssertEqual(authorization.requestCount, 1, "\(change)")
            XCTAssertFalse(settings.enableQuickpay, "\(change)")
            XCTAssertEqual(settings.quickpayAmount, 5, "\(change)")
            XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 5, "\(change)")
        }
    }

    func testDisablingAndLoweringSaveWithoutAsking() {
        settings.storeQuickpaySettings(enabled: true)
        let authorization = ControlledAuthorization()

        for change in [QuickpaySettingChange.enabled(false), .amount(1), .dailyLimitMultiplier(1)] {
            XCTAssertNil(settings.changeQuickpaySetting(change, authorize: { await authorization.authorize() }), "\(change)")
        }

        XCTAssertFalse(settings.enableQuickpay)
        XCTAssertEqual(settings.quickpayAmount, 1)
        XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 1)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    func testRaisesSaveWithoutAskingWhenPaymentsNeedNoPin() {
        for (pinEnabled, requirePinForPayments) in [(false, true), (true, false)] {
            settings.storeQuickpaySettings(enabled: false, amount: 5, dailyLimitMultiplier: 5)
            settings.pinEnabled = pinEnabled
            settings.requirePinForPayments = requirePinForPayments
            let authorization = ControlledAuthorization()

            for change in [QuickpaySettingChange.enabled(true), .amount(20), .dailyLimitMultiplier(10)] {
                XCTAssertNil(settings.changeQuickpaySetting(change, authorize: { await authorization.authorize() }), "\(change)")
            }

            XCTAssertTrue(settings.enableQuickpay)
            XCTAssertEqual(settings.quickpayAmount, 20)
            XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 10)
            XCTAssertEqual(authorization.requestCount, 0)
        }
    }

    func testRaiseWhileAnotherWaitsIsIgnored() async {
        let authorization = ControlledAuthorization()
        let pending = settings.changeQuickpaySetting(.amount(20), authorize: { await authorization.authorize() })

        XCTAssertNil(settings.changeQuickpaySetting(.dailyLimitMultiplier(10), authorize: { await authorization.authorize() }))
        XCTAssertNil(settings.changeQuickpaySetting(.amount(50), authorize: { await authorization.authorize() }))
        authorization.resolve(true)
        await pending?.value

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(settings.quickpayAmount, 20)
        XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 5)
    }

    func testFreeChangeWhileRaiseWaitsDropsTheRaise() async {
        let authorization = ControlledAuthorization()
        let pending = settings.changeQuickpaySetting(.enabled(true), authorize: { await authorization.authorize() })

        XCTAssertNil(settings.changeQuickpaySetting(.amount(1), authorize: { await authorization.authorize() }))
        XCTAssertEqual(settings.quickpayAmount, 1)
        authorization.resolve(true)
        await pending?.value

        XCTAssertFalse(settings.enableQuickpay, "An approval after a later change must not save the earlier raise")
        let next = settings.changeQuickpaySetting(.amount(5), authorize: { await authorization.authorize() })
        XCTAssertNotNil(next, "The dropped raise must not block the next one")
        await next?.value
        XCTAssertEqual(settings.quickpayAmount, 5)
    }

    func testApprovalSavesOnlyTheApprovedSetting() async {
        let authorization = ControlledAuthorization()
        let pending = settings.changeQuickpaySetting(.dailyLimitMultiplier(10), authorize: { await authorization.authorize() })

        authorization.resolve(true)
        await pending?.value

        XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 10)
        XCTAssertFalse(settings.enableQuickpay)
        XCTAssertEqual(settings.quickpayAmount, 5)
    }
}

/// Holds each authorization until the test resolves it; a decision made before the check starts is used at once.
@MainActor
private final class ControlledAuthorization {
    private(set) var requestCount = 0
    private var decision: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func authorize() async -> Bool {
        requestCount += 1
        if let decision {
            return decision
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ isApproved: Bool) {
        decision = isApproved
        continuation?.resume(returning: isApproved)
        continuation = nil
    }
}
