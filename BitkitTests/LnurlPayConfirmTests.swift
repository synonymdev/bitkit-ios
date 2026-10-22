@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class LnurlPayConfirmTests: XCTestCase {
    func testAmountScreenSurvivesContextResetDuringDismissal() async {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 149_500, maxSendable: 200_999,
            metadataStr: "[]", commentAllowed: 12, allowsNostr: false, nostrPubkey: nil
        )
        var path: [SendRoute] = []
        let view = LnurlPayAmount(navigationPath: Binding(get: { path }, set: { path = $0 }))
            .environmentObject(app)
            .environmentObject(wallet)
            .environmentObject(CurrencyViewModel(currencyService: OfflineCurrencyService()))
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(ContactsManager())
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await Task.yield()
        app.resetSendState()
        await Task.yield()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.sizeThatFits(in: window.bounds.size).height, 0)
        XCTAssertNil(app.lnurlPayData)
        XCTAssertNil(wallet.sendAmountSats)
        XCTAssertTrue(path.isEmpty)
    }

    func testFixedLnurlLocksReviewedAmountAndPreservesMillisatoshis() {
        let data = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 222_222, maxSendable: 222_538,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        let app = AppViewModel()
        app.lnurlPayData = data
        app.selectedWalletToPayFrom = .lightning
        XCTAssertEqual(app.fixedLightningAmountSats, 223)
        XCTAssertTrue(data.accepts(amountSats: 223))
        XCTAssertFalse(data.accepts(amountSats: 222))
        XCTAssertFalse(data.accepts(amountSats: 224))
        XCTAssertEqual(data.callbackAmountMsats(userSats: 223), 222_222)
        app.selectedWalletToPayFrom = .onchain
        XCTAssertNil(app.fixedLightningAmountSats)
    }

    func testVariableLnurlAcceptsOnlyAmountsWithinItsBounds() {
        let data = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 1_000_001, maxSendable: 5_000_999,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        XCTAssertFalse(data.accepts(amountSats: 1000))
        XCTAssertTrue(data.accepts(amountSats: 1001))
        XCTAssertTrue(data.accepts(amountSats: 5000))
        XCTAssertFalse(data.accepts(amountSats: 5001))
        XCTAssertEqual(data.callbackAmountMsats(userSats: 1001), 1_001_000)
    }

    func testResetWhileMountedDoesNotCrashOrPreparePayment() async {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        let lnurlPayData = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 1_000_000, maxSendable: 5_000_000,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        app.lnurlPayData = lnurlPayData
        var navigationPath: [SendRoute] = []
        var isSubmittingPayment = false
        let view = LnurlPayConfirm(
            navigationPath: Binding(get: { navigationPath }, set: { navigationPath = $0 }),
            isSubmittingPayment: Binding(get: { isSubmittingPayment }, set: { isSubmittingPayment = $0 }),
            requestPinCheck: {
                XCTFail("Rendering confirmation must not request payment authorization")
                return false
            },
            prepareIncomingPaymentRequest: {
                XCTFail("Rendering confirmation must not prepare a payment")
                throw CancellationError()
            },
            routingCacheResetAttempted: false
        )
        .environment(PaykitPaymentRequestManager())
        .environmentObject(app)
        .environmentObject(wallet)
        .environmentObject(SheetViewModel())
        .environmentObject(CurrencyViewModel(currencyService: OfflineCurrencyService()))
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(ContactsManager())
        let hostingController = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostingController.view.layoutIfNeeded()
        XCTAssertGreaterThan(hostingController.sizeThatFits(in: window.bounds.size).height, 0)
        await Task.yield()

        // Retry clears the send state before fresh payment details arrive or the sheet is dismissed.
        app.resetSendState()
        wallet.resetSendState(speed: SettingsViewModel.shared.defaultTransactionSpeed)
        XCTAssertNil(app.lnurlPayData)
        await Task.yield()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        _ = hostingController.sizeThatFits(in: window.bounds.size)
        XCTAssertNotNil(hostingController.view.window)
        XCTAssertTrue(navigationPath.isEmpty)
        XCTAssertFalse(isSubmittingPayment)

        app.lnurlPayData = lnurlPayData
        await Task.yield()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        XCTAssertGreaterThan(hostingController.sizeThatFits(in: window.bounds.size).height, 0)
        XCTAssertTrue(navigationPath.isEmpty)
        XCTAssertFalse(isSubmittingPayment)
    }
}
