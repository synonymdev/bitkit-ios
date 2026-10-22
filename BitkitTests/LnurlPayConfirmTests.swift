@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class LnurlPayConfirmTests: XCTestCase {
    func testRecreatedConfirmationCannotStartAnotherPaymentDuringAuthorizationOrDispatch() async throws {
        for suspendedStage in ["authorization", "callback"] {
            let flow = SendPresentationState(initialRoute: .lnurlPayConfirm)
            let firstBinding = Binding(get: { flow.isSubmittingPayment }, set: { flow.isSubmittingPayment = $0 })
            let started = expectation(description: "First attempt suspended at \(suspendedStage)")
            var continuation: CheckedContinuation<Void, Never>?
            var authorizations = 0
            var callbacks = 0
            var dispatches = 0
            let task = Task {
                try await LnurlPayConfirm.withSubmissionLock(isSubmitting: firstBinding) {
                    authorizations += 1
                    if suspendedStage == "authorization" {
                        await withCheckedContinuation { continuation = $0; started.fulfill() }
                    }
                    callbacks += 1
                    if suspendedStage == "callback" {
                        await withCheckedContinuation { continuation = $0; started.fulfill() }
                    }
                    dispatches += 1
                }
            }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertTrue(flow.isSubmittingPayment)
            // A recreated confirmation has fresh local state but binds the same presentation.
            let remountedBinding = Binding(get: { flow.isSubmittingPayment }, set: { flow.isSubmittingPayment = $0 })
            try await LnurlPayConfirm.withSubmissionLock(isSubmitting: remountedBinding) {
                authorizations += 1
                callbacks += 1
                dispatches += 1
            }
            XCTAssertTrue(flow.isSubmittingPayment, "Rejected re-entry must not release the original attempt's lock")
            XCTAssertEqual(authorizations, 1)
            XCTAssertEqual(dispatches, 0)
            try XCTUnwrap(continuation).resume()
            try await task.value
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(dispatches, 1)
            XCTAssertFalse(flow.isSubmittingPayment)
        }
    }

    func testSubmissionFailureAndCancellationReleaseLockForExplicitRetry() async throws {
        enum Failure: Error { case callback }
        for error: Error in [Failure.callback, CancellationError()] {
            let flow = SendPresentationState(initialRoute: .lnurlPayConfirm)
            let binding = Binding(get: { flow.isSubmittingPayment }, set: { flow.isSubmittingPayment = $0 })
            do {
                try await LnurlPayConfirm.withSubmissionLock(isSubmitting: binding) { throw error }
                XCTFail("The original attempt's error must propagate")
            } catch {}
            XCTAssertFalse(flow.isSubmittingPayment)
            var retries = 0
            try await LnurlPayConfirm.withSubmissionLock(isSubmitting: binding) {
                XCTAssertTrue(flow.isSubmittingPayment)
                retries += 1
            }
            XCTAssertEqual(retries, 1)
            XCTAssertFalse(flow.isSubmittingPayment)
        }
    }

    func testAutomaticConfirmationRemountDoesNotRepeatAuthorization() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let settings = SettingsViewModel.shared
        let previousPinEnabled = settings.pinEnabled
        defer { settings.pinEnabled = previousPinEnabled }
        settings.pinEnabled = true
        settings.requirePinForPayments = true
        settings.useBiometrics = false
        let app = AppViewModel()
        app.contactPaymentContext = ContactPaymentContext(publicKey: "test-contact", isInitialSubscriptionPayment: true)
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 222_222, maxSendable: 222_222,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        let flow = SendPresentationState(initialRoute: .lnurlPayConfirm)
        let wallet = WalletViewModel()
        let sheets = SheetViewModel()
        let currency = CurrencyViewModel(currencyService: OfflineCurrencyService())
        let manager = PaykitPaymentRequestManager()
        let started = expectation(description: "Automatic confirmation awaiting PIN")
        var pinContinuation: CheckedContinuation<Bool, Never>?
        var pinRequests = 0
        func makeView() -> some View {
            LnurlPayConfirm(
                navigationPath: Binding(get: { flow.navigationPath }, set: { flow.navigationPath = $0 }),
                isSubmittingPayment: Binding(get: { flow.isSubmittingPayment }, set: { flow.isSubmittingPayment = $0 }),
                requestPinCheck: {
                    pinRequests += 1
                    guard pinRequests == 1 else { return false }
                    return await withCheckedContinuation { pinContinuation = $0; started.fulfill() }
                },
                prepareIncomingPaymentRequest: { XCTFail("Cancelled authorization must not prepare or dispatch") },
                routingCacheResetAttempted: false
            )
            .environment(manager)
            .environmentObject(app)
            .environmentObject(wallet)
            .environmentObject(sheets)
            .environmentObject(currency)
            .environmentObject(settings)
            .environmentObject(ContactsManager())
        }
        let host = UIHostingController(rootView: AnyView(makeView()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(flow.isSubmittingPayment)
        host.rootView = AnyView(Color.clear)
        host.view.layoutIfNeeded()
        await Task.yield()
        host.rootView = AnyView(makeView().id(UUID()))
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(pinRequests, 1)
        XCTAssertTrue(flow.isSubmittingPayment)
        try XCTUnwrap(pinContinuation).resume(returning: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while flow.isSubmittingPayment, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(flow.isSubmittingPayment)
    }

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
