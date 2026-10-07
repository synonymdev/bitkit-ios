@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class LnurlPayConfirmTests: XCTestCase {
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
