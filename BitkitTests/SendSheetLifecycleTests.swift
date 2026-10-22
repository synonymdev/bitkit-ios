@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class SendSheetLifecycleTests: XCTestCase {
    func testScannerReplacementPreservesLnurlConfirmation() async throws {
        let (app, sheets, prompt, window, _) = makeHost()
        defer {
            sheets.hideSheet(reason: "Test cleanup")
            window.isHidden = true
            window.rootViewController = nil
        }
        sheets.showSheet(.send, data: SendConfig(view: .options))
        try await Task.sleep(for: .seconds(1))
        sheets.hideSheet(reason: "Close previous send")
        // A new scan can resolve while the previous send is still animating out.
        sheets.showSheet(.scanner)
        app.resetSendState()
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/replacement", callback: "https://example.com/callback",
            minSendable: 222_538, maxSendable: 222_538,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        app.selectedWalletToPayFrom = .lightning
        sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_538, "The retiring send must not clear the replacement scan")
        sheets.hideSheet(reason: "Close replacement")
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(app.lnurlPayData, "Closing the current send must still clean up its state")
        for amount: UInt64 in [222_000, 222_538, 222_222, 500_500] {
            sheets.showSheet(.scanner)
            try await Task.sleep(for: .seconds(1))
            prompt.isPresented = true
            try await Task.sleep(for: .milliseconds(500))
            app.lnurlPayData = LnurlPayData(
                uri: "https://example.com/pay", callback: "https://example.com/callback",
                minSendable: amount, maxSendable: amount,
                metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
            )
            app.selectedWalletToPayFrom = .lightning
            sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
            prompt.isPresented = false
            try await Task.sleep(for: .seconds(2))
            XCTAssertEqual(app.lnurlPayData?.minSendable, amount)
            XCTAssertEqual(sheets.sendSheetItem?.initialRoute, .lnurlPayConfirm)
            // Scanning again inside the current send transfers ownership to its new state.
            let current = app.lnurlPayData
            app.resetSendState()
            app.lnurlPayData = current
            app.selectedWalletToPayFrom = .lightning
            try await Task.sleep(for: .milliseconds(100))
            sheets.hideSheet(reason: "Close LNURL send")
            try await Task.sleep(for: .seconds(1))
            XCTAssertNil(app.lnurlPayData, "Closing the current send must still clean up its state")
        }
    }

    func testTransientSendUnmountKeepsCurrentLnurlState() async throws {
        let (app, sheets, prompt, window, _) = makeHost()
        defer { window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = makeLnurlData()
        app.selectedWalletToPayFrom = .lightning
        sheets.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
        try await Task.sleep(for: .seconds(1))
        let presentationID = try XCTUnwrap(sheets.activeSheetConfiguration?.presentationID)
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_222)
        // Nested sheet dismissal may recreate Send content without ending its presentation.
        prompt.isSendMounted = false
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID)
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_222, "A transient unmount must retain the active scan")
        prompt.isSendMounted = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_222, "Replacement content needs the active scan")
        sheets.hideSheet(reason: "Close current presentation")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(app.lnurlPayData, "Ending the presentation must still clean up")
    }

    func testRemountDoesNotRepeatOptionsSetupAfterLnurlScan() async throws {
        let (app, sheets, prompt, window, wallet) = makeHost()
        defer { window.isHidden = true; window.rootViewController = nil }
        sheets.showSheet(.send, data: SendConfig(view: .options))
        try await Task.sleep(for: .seconds(1))
        app.resetSendState()
        app.lnurlPayData = makeLnurlData()
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 150
        try await Task.sleep(for: .milliseconds(100))
        prompt.isSendMounted = false
        try await Task.sleep(for: .milliseconds(500))
        prompt.isSendMounted = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_222, "Recreated options-root Send must not clear its scanned target")
        XCTAssertEqual(wallet.sendAmountSats, 150, "Recreated Send must not reset the entered amount")
        sheets.hideSheet(reason: "Close remounted send")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(app.lnurlPayData)
        XCTAssertNil(wallet.sendAmountSats)
    }

    func testRemountPreservesVariableLnurlEnteredAmount() async throws {
        let (app, sheets, prompt, window, wallet) = makeHost()
        defer { window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = LnurlPayData(
            uri: "https://example.com/variable", callback: "https://example.com/callback",
            minSendable: 149_500, maxSendable: 200_999,
            metadataStr: "[]", commentAllowed: 12, allowsNostr: false, nostrPubkey: nil
        )
        app.selectedWalletToPayFrom = .lightning
        sheets.showSheet(.send, data: SendConfig(view: .lnurlPayAmount))
        try await Task.sleep(for: .seconds(1))
        wallet.sendAmountSats = 150
        prompt.isSendMounted = false
        try await Task.sleep(for: .milliseconds(500))
        prompt.isSendMounted = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(app.lnurlPayData?.minSendable, 149_500)
        XCTAssertEqual(wallet.sendAmountSats, 150, "Recreated amount-root Send must retain its confirmed amount")
        sheets.hideSheet(reason: "Close remounted variable send")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(app.lnurlPayData)
        XCTAssertNil(wallet.sendAmountSats)
    }

    func testEmbeddedSendExitCleansStateWhileSubscriptionRemainsActive() async throws {
        let (app, sheets, prompt, window, _) = makeHost(isEmbedded: true)
        defer { window.isHidden = true; window.rootViewController = nil }
        app.lnurlPayData = makeLnurlData()
        app.selectedWalletToPayFrom = .lightning
        try await Task.sleep(for: .seconds(1))
        let presentationID = try XCTUnwrap(sheets.activeSheetConfiguration?.presentationID)
        XCTAssertEqual(app.lnurlPayData?.minSendable, 222_222)
        prompt.isSendMounted = false
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .subscription)
        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID)
        XCTAssertNil(app.lnurlPayData, "Leaving embedded Send must clean up even while its parent stays open")
    }

    private func makeLnurlData() -> LnurlPayData {
        LnurlPayData(uri: "https://example.com/current", callback: "https://example.com/callback",
                     minSendable: 222_222, maxSendable: 222_222, metadataStr: "[]",
                     commentAllowed: nil, allowsNostr: false, nostrPubkey: nil)
    }

    private func makeHost(isEmbedded: Bool = false) -> (AppViewModel, SheetViewModel, ScanPromptState, UIWindow, WalletViewModel) {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        wallet.nodeLifecycleState = .running
        let sheets = SheetViewModel()
        if isEmbedded {
            sheets.showSheet(.subscription)
        }
        let prompt = ScanPromptState()
        let root = SendPresentationHarness(sheets: sheets, prompt: prompt, isEmbedded: isEmbedded)
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
        return (app, sheets, prompt, window, wallet)
    }
}

private struct SendPresentationHarness: View {
    @ObservedObject var sheets: SheetViewModel
    @ObservedObject var prompt: ScanPromptState
    var isEmbedded = false
    var body: some View {
        if isEmbedded {
            if prompt.isSendMounted {
                SendSheet(config: SendSheetItem(presentationID: sheets.activeSheetConfiguration?.presentationID,
                                                initialRoute: .lnurlPayConfirm), isEmbedded: true)
                    .environmentObject(sheets)
            }
        } else {
            Color.black
                .sheet(item: $sheets.scannerSheetItem, onDismiss: {
                    sheets.hideSheetIfActive(.scanner, reason: "Scanner sheet dismissed")
                }) { _ in
                    Text("Scanner fixture")
                        .sheet(isPresented: $prompt.isPresented) { Text("Manual entry fixture") }
                }
                .sheet(item: $sheets.sendSheetItem, onDismiss: {
                    sheets.hideSheetIfActive(.send, reason: "Send sheet dismissed")
                }) { config in
                    if prompt.isSendMounted {
                        SendSheet(config: config)
                            .environmentObject(sheets)
                    }
                }
        }
    }
}

private final class ScanPromptState: ObservableObject {
    @Published var isPresented = false
    @Published var isSendMounted = true
}
