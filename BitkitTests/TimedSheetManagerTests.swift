@testable import Bitkit
import SwiftUI
import XCTest

@MainActor
final class TimedSheetManagerTests: XCTestCase {
    func testDismissalRetriesAnIntroBlockedByAnotherSheet() async throws {
        let sheets = SheetViewModel()
        let manager = TimedSheetManager(sheetViewModel: sheets, checkDelay: 0.01)
        defer { manager.onPrimaryScreenExited() }
        let shown = expectation(description: "Intro presented")
        let intro = TestTimedSheet(onShown: { shown.fulfill() })
        manager.registerSheet(intro)
        sheets.showSheet(.receive)
        manager.onPrimaryScreenEntered()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .receive)
        XCTAssertEqual(manager.getQueueStatus().map(\.id), [.usdtIntro])

        sheets.receiveSheetItem = nil
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .usdtIntro)
        XCTAssertTrue(manager.getQueueStatus().isEmpty)
    }

    func testInterruptedEligibilityCannotReplaceAnotherSheetAndRetriesLater() async {
        let sheets = SheetViewModel()
        let manager = TimedSheetManager(sheetViewModel: sheets, checkDelay: 0.01)
        defer { manager.onPrimaryScreenExited() }
        let checking = expectation(description: "Eligibility started")
        let shown = expectation(description: "Intro presented after interruption")
        var resume: CheckedContinuation<Bool, Never>?
        let intro = TestTimedSheet(onShown: { shown.fulfill() }, shouldShow: {
            await withCheckedContinuation {
                resume = $0
                checking.fulfill()
            }
        })
        manager.registerSheet(intro)
        manager.onPrimaryScreenEntered()
        await fulfillment(of: [checking], timeout: 1)
        sheets.showSheet(.send)
        resume?.resume(returning: true)
        await Task.yield()
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
        XCTAssertEqual(manager.getQueueStatus().map(\.id), [.usdtIntro])

        intro.eligibility = { true }
        sheets.hideSheet()
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .usdtIntro)
    }

    func testLeavingHomeCancelsEligibilityUntilReturning() async {
        let sheets = SheetViewModel()
        let manager = TimedSheetManager(sheetViewModel: sheets, checkDelay: 0.01)
        defer { manager.onPrimaryScreenExited() }
        let checking = expectation(description: "Eligibility started")
        let shown = expectation(description: "Intro presented after returning home")
        var resume: CheckedContinuation<Bool, Never>?
        let intro = TestTimedSheet(onShown: { shown.fulfill() }, shouldShow: {
            await withCheckedContinuation {
                resume = $0
                checking.fulfill()
            }
        })
        manager.registerSheet(intro)
        manager.onPrimaryScreenEntered()
        await fulfillment(of: [checking], timeout: 1)
        manager.onPrimaryScreenExited()
        resume?.resume(returning: true)
        await Task.yield()
        XCTAssertNil(sheets.activeSheetConfiguration)
        XCTAssertEqual(manager.getQueueStatus().map(\.id), [.usdtIntro])

        intro.eligibility = { true }
        manager.onPrimaryScreenEntered()
        await fulfillment(of: [shown], timeout: 1)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .usdtIntro)
    }

    func testIntroRecordsSeenOnlyWhenItsViewAppears() async throws {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        let previousSeen = settings.hasSeenUsdtIntro
        defer { settings.hasSeenUsdtIntro = previousSeen }
        settings.hasSeenUsdtIntro = false
        let view = UsdtIntroSheet(config: UsdtIntroSheetItem())
            .environment(UsdtWalletManager())
            .environmentObject(settings)
            .environmentObject(SheetViewModel())
        let host = UIHostingController(rootView: view.environment(\.scenePhase, .inactive))
        XCTAssertFalse(settings.hasSeenUsdtIntro)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(settings.hasSeenUsdtIntro)
        host.rootView = view.environment(\.scenePhase, .active)
        for _ in 0 ..< 20 where !settings.hasSeenUsdtIntro {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(settings.hasSeenUsdtIntro)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "USDT intro appearance"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUnseenUpgradeRemainsEligibleButSeenOrDecidedIntroDoesNot() async {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        let oldPreference = settings.usdtPreference
        let oldSeen = settings.hasSeenUsdtIntro
        defer {
            settings.usdtPreference = oldPreference
            settings.hasSeenUsdtIntro = oldSeen
        }
        settings.usdtPreference = .undecided
        settings.hasSeenUsdtIntro = false
        let wallet = WalletViewModel()
        wallet.walletExists = true
        let intro = UsdtIntroTimedSheet(wallet: wallet, settings: settings)
        let initiallyEligible = await intro.shouldShow()
        XCTAssertTrue(initiallyEligible)
        intro.onShown()
        XCTAssertFalse(settings.hasSeenUsdtIntro)

        settings.hasSeenUsdtIntro = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasSeenUsdtIntro"))
        let relaunched = UsdtIntroTimedSheet(wallet: wallet, settings: settings)
        let eligibleAfterSeen = await relaunched.shouldShow()
        XCTAssertFalse(eligibleAfterSeen)

        settings.hasSeenUsdtIntro = false
        for choice in [UsdtPreference.enabled, .disabled] {
            settings.usdtPreference = choice
            let eligibleAfterChoice = await relaunched.shouldShow()
            XCTAssertFalse(eligibleAfterChoice)
        }
    }
}

private final class TestTimedSheet: TimedSheetItem {
    let id = SheetID.usdtIntro
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = UsdtIntroSheetItem()
    var eligibility: () async -> Bool
    private let shown: () -> Void

    init(onShown: @escaping () -> Void, shouldShow: @escaping () async -> Bool = { true }) {
        shown = onShown
        eligibility = shouldShow
    }

    func shouldShow() async -> Bool {
        await eligibility()
    }

    func onShown() {
        shown()
    }

    func onDismissed() {}
}
