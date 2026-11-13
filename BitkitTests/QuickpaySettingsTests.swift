@testable import Bitkit
import XCTest

@MainActor
final class QuickpaySettingsTests: XCTestCase {
    private let settings = SettingsViewModel.shared

    override func setUp() {
        super.setUp()
        snapshotAppDefaultsDomain()
        addTeardownBlock { @MainActor [settings] in settings.updatePinEnabledState() }
        settings.storeQuickpaySettings(enabled: false, amount: 5, dailyLimitMultiplier: 5)
        settings.pinEnabled = true
        settings.requirePinForPayments = true
    }

    func testRaisesSaveOnlyTheirOwnSettingOnceApproved() async {
        let raises: [(QuickpaySettingChange, (SettingsViewModel) -> Bool)] = [
            (.enabled(true), { $0.enableQuickpay && $0.quickpayAmount == 5 && $0.quickpayDailyLimitMultiplier == 5 }),
            (.amount(20), { !$0.enableQuickpay && $0.quickpayAmount == 20 && $0.quickpayDailyLimitMultiplier == 5 }),
            (.dailyLimitMultiplier(10), { !$0.enableQuickpay && $0.quickpayAmount == 5 && $0.quickpayDailyLimitMultiplier == 10 }),
        ]
        for (change, isSaved) in raises {
            settings.storeQuickpaySettings(enabled: false, amount: 5, dailyLimitMultiplier: 5)
            let authorization = ControlledAuthorization()

            let pending = settings.changeQuickpaySetting(change, authorize: { await authorization.authorize() })

            XCTAssertNotNil(pending, "\(change)")
            XCTAssertFalse(settings.enableQuickpay, "\(change)")
            XCTAssertEqual(settings.quickpayAmount, 5, "\(change)")
            XCTAssertEqual(settings.quickpayDailyLimitMultiplier, 5, "\(change)")
            authorization.resolve(true)
            await pending?.value
            XCTAssertTrue(isSaved(settings), "\(change)")
            XCTAssertEqual(authorization.requestCount, 1, "\(change)")
        }
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
