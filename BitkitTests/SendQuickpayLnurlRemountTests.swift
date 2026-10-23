@testable import Bitkit
import BitkitCore
import Network
import SwiftUI
import XCTest

/// F1 (PR #1099): a QuickPay-routed fixed LNURL is re-requested and re-paid when Send content is
/// recreated while the presentation stays current.
@MainActor
final class SendQuickpayLnurlRemountTests: XCTestCase {
    private static let metadata = #"[["text/plain","test"]]"#
    /// Two distinct, validly signed regtest invoices for 500500 msat whose `h` tag is sha256(metadata).
    private static let invoices = [
        "lnbcrt5005000p1p4d5kcvpp5ldcnltt7re50tv7a7jjxv0nzh9xl3e3ktuxqzf09nh2tgxdqdnmssp5xzj6kuaug34a3aqgdvnqge85vdhy9rmsvxnq8s5wpct0u2fxe49shp5plegz60wa3rk9cxru5wtzfdxq32hh50rga6aa6eeh2gl6q0z9g8qxqrrsscqpj9qyysgqt6m4mumhw8emmnw9rcrfhazxk9pewm30yyhhf9ynzl039jwt5xfn4u3n79m6z77pteygwqs57qljk26ztlm27jr5644zfm8spp3yvvqqhv2z5w",
        "lnbcrt5005000p1p4d5kcvpp5xqwmxyea8wll3nc6sw7ur7xvzcqnczvq4uwxekwldsv25zpr94tqsp5v8jde8cev4p5agl3kskk2fne2mtk505m56naa48ducg5yt2fp8qshp5plegz60wa3rk9cxru5wtzfdxq32hh50rga6aa6eeh2gl6q0z9g8qxqrrsscqpj9qyysgqz7dwdadwpxm36j4c4w6d4ga9jtqa4e4lkaj99r5fdejwr943rfqz5hr57xcx8tfd3arfzerzs66apanuntv7f9de6c55d7y5teav2xgqcrch44",
    ]

    override func setUp() {
        super.setUp()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        snapshotAppDefaults("primaryDisplay", "cached_fx_rates", "enableQuickpay", "quickpayAmount", "quickpayDailyLimitMultiplier")
        SettingsViewModel.shared.enableQuickpay = true
        SettingsViewModel.shared.quickpayAmount = 5
        SettingsViewModel.shared.quickpayDailyLimitMultiplier = 5
        let rate = FxRate(symbol: "BTCUSD", lastPrice: "100000", base: "BTC", baseName: "Bitcoin", quote: "USD",
                          quoteName: "US Dollar", currencySymbol: "$", currencyFlag: "", lastUpdatedAt: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode([rate]), forKey: "cached_fx_rates")
    }

    private func lnurl(callback: String) -> LnurlPayData {
        LnurlPayData(uri: "https://example.com/quickpay", callback: callback,
                     minSendable: 500_500, maxSendable: 500_500, metadataStr: Self.metadata,
                     commentAllowed: nil, allowsNostr: false, nostrPubkey: nil)
    }

    /// Production path: Send opened at `.quickpay` (as `PaymentNavigationHelper` does for a fixed LNURL under
    /// the threshold), then the Send content is recreated while the presentation is current (the same event
    /// `testTransientSendUnmountKeepsCurrentLnurlState` models). The recreated `SendQuickpay` must not ask the
    /// LNURL service for another invoice for the same presentation.
    func testRecreatedQuickpayDoesNotRequestSecondLnurlInvoice() async throws {
        let server = try LnurlCallbackServer(hold: true, invoices: Self.invoices)
        defer { server.stop() }
        try await server.waitReady()
        let (app, sheets, mount, window) = makeHost()
        defer { sheets.hideSheet(reason: "Test cleanup"); window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = lnurl(callback: server.callbackURL)
        app.selectedWalletToPayFrom = .lightning
        sheets.showSheet(.send, data: SendConfig(view: .quickpay))
        try await waitUntil(timeout: 5) { server.requestCount >= 1 }
        XCTAssertEqual(server.requestCount, 1, "Opening QuickPay fetches one invoice")
        let presentationID = try XCTUnwrap(sheets.activeSheetConfiguration?.presentationID)

        mount.isSendMounted = false
        try await Task.sleep(for: .milliseconds(500))
        mount.isSendMounted = true
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID, "Presentation stayed current")
        XCTAssertNotNil(app.lnurlPayData, "Head retains the LNURL target across recreation")
        XCTAssertEqual(server.requestCount, 1,
                       "Recreated SendQuickpay requested another LNURL invoice for the same presentation (F1)")
    }

    /// Same as above, with the trigger a user performs: PIN enabled, the phone is locked or the app backgrounded
    /// mid-payment, so AppScene swaps MainNavView (the `.sheet` presenter) for AuthCheck, then back after unlock.
    func testPinLockDuringQuickpayDoesNotRequestSecondLnurlInvoice() async throws {
        let server = try LnurlCallbackServer(hold: true, invoices: Self.invoices)
        defer { server.stop() }
        try await server.waitReady()
        let (app, sheets, mount, window) = makeHost()
        defer { sheets.hideSheet(reason: "Test cleanup"); window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = lnurl(callback: server.callbackURL)
        app.selectedWalletToPayFrom = .lightning
        sheets.showSheet(.send, data: SendConfig(view: .quickpay))
        try await waitUntil(timeout: 5) { server.requestCount >= 1 }
        XCTAssertEqual(server.requestCount, 1)
        let presentationID = try XCTUnwrap(sheets.activeSheetConfiguration?.presentationID)

        mount.isPresenterMounted = false
        try await Task.sleep(for: .seconds(1))
        mount.isPresenterMounted = true
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID, "Send is re-presented after unlock")
        XCTAssertEqual(server.requestCount, 1,
                       "Unlock re-presented QuickPay, which requested another LNURL invoice for the same payment (F1)")
    }

    func testRemountedQuickpayReceivesInvoiceFailure() async throws {
        let server = try LnurlCallbackServer(hold: true, invoices: Self.invoices)
        defer { server.stop() }
        try await server.waitReady()
        let (app, sheets, mount, window) = makeHost()
        defer { sheets.hideSheet(reason: "Test cleanup"); window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = lnurl(callback: server.callbackURL)
        app.selectedWalletToPayFrom = .lightning
        sheets.showSheet(.send, data: SendConfig(view: .quickpay))
        try await waitUntil(timeout: 5) { server.requestCount >= 1 }
        let flow = try XCTUnwrap(sheets.activeSheetConfiguration?.sendState)
        mount.isSendMounted = false
        try await Task.sleep(for: .milliseconds(500))
        mount.isSendMounted = true
        try await Task.sleep(for: .milliseconds(500))
        server.failHeldRequests()
        try await waitUntil(timeout: 5) { !flow.navigationPath.isEmpty }
        guard case .failure = flow.navigationPath.last else { return XCTFail("Recreated Send must receive the failure route") }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testNewPresentationAndExplicitRetryStartNewQuickpaySessions() async throws {
        for replace in [false, true] {
            let server = try LnurlCallbackServer(hold: true, invoices: Self.invoices)
            defer { server.stop() }
            try await server.waitReady()
            let (app, sheets, _, window) = makeHost()
            defer { sheets.hideSheet(reason: "Test cleanup"); window.isHidden = true; window.rootViewController = nil }
            app.lnurlPayData = lnurl(callback: server.callbackURL)
            app.selectedWalletToPayFrom = .lightning
            sheets.showSheet(.send, data: SendConfig(view: .quickpay))
            try await waitUntil(timeout: 5) { server.requestCount >= 1 }
            XCTAssertEqual(server.requestCount, 1)
            if replace {
                sheets.hideSheet(reason: "Fresh QuickPay presentation")
                try await Task.sleep(for: .seconds(1))
                app.lnurlPayData = lnurl(callback: server.callbackURL)
                app.selectedWalletToPayFrom = .lightning
                sheets.showSheet(.send, data: SendConfig(view: .quickpay))
            } else {
                try XCTUnwrap(sheets.activeSheetConfiguration?.sendState).quickPaySession += 1
            }
            try await waitUntil(timeout: 5) { server.requestCount >= 2 }
            XCTAssertEqual(server.requestCount, 2, "replace=\(replace)")
        }
    }

    /// Grounds the PIN-lock trigger: removing the `.sheet` presenter (AppScene swaps MainNavView for AuthCheck)
    /// does not end the Send presentation, and restoring it re-presents the same Send with its LNURL retained.
    func testPresenterRemovalKeepsAndRepresentsSendPresentation() async throws {
        let (app, sheets, mount, window) = makeHost()
        defer { sheets.hideSheet(reason: "Test cleanup"); window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = lnurl(callback: "http://127.0.0.1:9/never")
        app.selectedWalletToPayFrom = .lightning
        SettingsViewModel.shared.enableQuickpay = false
        sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
        try await Task.sleep(for: .seconds(1))
        let presentationID = try XCTUnwrap(sheets.activeSheetConfiguration?.presentationID)
        mount.isPresenterMounted = false
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID)
        XCTAssertNotNil(app.lnurlPayData)
        mount.isPresenterMounted = true
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID, "Unlock re-presents the same Send")
    }

    /// F2: a home-scanner LNURL whose decode finishes after the user opened Send manually.
    func testLateHomeScanDoesNotCloseSendOpenedDuringDecode() async throws {
        SettingsViewModel.shared.enableQuickpay = false
        let sheets = SheetViewModel()
        let started = expectation(description: "decode suspended")
        var continuation: CheckedContinuation<BitkitCore.Scanner, Error>?
        let app = AppViewModel(
            sheetViewModel: sheets,
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(isNodeRunning: true, spendableOnchainBalanceSats: 0, totalLightningBalanceSats: 1_000_000,
                                     hasChannels: true, hasUsableChannels: true)
                },
                canSendLightning: { _ in true },
                decodeInvoice: { _ in
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }
            )
        )
        let (_, _, _, window) = makeHost(app: app, sheets: sheets)
        defer { sheets.hideSheet(reason: "Test cleanup"); window.isHidden = true; window.rootViewController = nil }
        let scanner = ScannerManager {}
        scanner.configure(app: app, currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
                          settings: SettingsViewModel.shared, sheets: sheets)

        let scan = Task { await scanner.handleScan("lnurl1latehomescan", context: .main) }
        await fulfillment(of: [started], timeout: 2)
        // User dismisses the scanner and taps Send while the LNURL pay params are still being fetched.
        sheets.showSheet(.send, data: SendConfig(view: .options))
        try await Task.sleep(for: .seconds(1))
        let manualSend = try XCTUnwrap(sheets.activeSheetConfiguration?.presentationID)
        try XCTUnwrap(continuation).resume(returning: .lnurlPay(data: lnurl(callback: "https://example.com/callback")))
        await scan.value
        try await Task.sleep(for: .seconds(3))

        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, manualSend,
                       "Late scan replaced the user's Send, then the replacement closed itself with no LNURL data (F2)")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeHost(app: AppViewModel? = nil,
                          sheets: SheetViewModel? = nil) -> (AppViewModel, SheetViewModel, MountState, UIWindow)
    {
        snapshotAppDefaultsDomain()
        let app = app ?? AppViewModel()
        let sheets = sheets ?? SheetViewModel()
        let wallet = WalletViewModel()
        wallet.channelCount = 0
        wallet.channels = []
        wallet.nodeLifecycleState = .running
        let mount = MountState()
        let root = RemountHarness(sheets: sheets, mount: mount)
            .environment(PaykitPaymentRequestManager())
            .environment(HwWalletManager())
            .environment(TrezorManager())
            .environment(CameraManager.shared)
            .environmentObject(app)
            .environmentObject(wallet)
            .environmentObject(NetworkMonitor())
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(TagManager())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ActivityListViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(CurrencyViewModel(currencyService: OfflineCurrencyService()))
            .environmentObject(FeeEstimatesManager())
            .environmentObject(ScannerManager())
            .environmentObject(NavigationViewModel())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return (app, sheets, mount, window)
    }
}

private final class MountState: ObservableObject {
    @Published var isSendMounted = true
    @Published var isPresenterMounted = true
}

private struct RemountHarness: View {
    @ObservedObject var sheets: SheetViewModel
    @ObservedObject var mount: MountState
    var body: some View {
        if mount.isPresenterMounted {
            Color.black
                .sheet(item: $sheets.sendSheetItem, onDismiss: {
                    sheets.hideSheetIfActive(.send, reason: "Send sheet dismissed")
                }) { config in
                    if mount.isSendMounted {
                        SendSheet(config: config)
                            .environmentObject(sheets)
                    }
                }
        } else {
            Text("Auth fixture")
        }
    }
}

/// Minimal LNURL-pay callback: counts requests; either holds them open or answers with the next invoice.
final class LnurlCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LnurlCallbackServer")
    private let lock = NSLock()
    private let hold: Bool
    private let invoices: [String]
    private var count = 0
    private var held: [NWConnection] = []
    private var ready = false

    var requestCount: Int {
        lock.withLock { count }
    }

    var callbackURL: String {
        "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/callback"
    }

    init(hold: Bool, invoices: [String]) throws {
        self.hold = hold
        self.invoices = invoices
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.lock.withLock { self?.ready = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func waitReady() async throws {
        for _ in 0 ..< 100 where !lock.withLock({ ready }) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func stop() {
        lock.withLock { held.forEach { $0.cancel() } }
        listener.cancel()
    }

    func failHeldRequests() {
        let connections = lock.withLock {
            let connections = held
            held.removeAll()
            return connections
        }
        let body = #"{"status":"ERROR","reason":"fixture failure"}"#
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        for connection in connections {
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, String(decoding: data, as: UTF8.self).hasPrefix("GET") else {
                connection.cancel()
                return
            }
            let index: Int = lock.withLock {
                self.count += 1
                return self.count - 1
            }
            if hold {
                lock.withLock { self.held.append(connection) }
                return
            }
            let body = #"{"pr":"\#(invoices[index % invoices.count])","routes":[]}"#
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
