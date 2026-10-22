@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class SendSheetLifecycleTests: XCTestCase {
    func testScannerReplacementPreservesLnurlConfirmation() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        wallet.nodeLifecycleState = .running
        let sheets = SheetViewModel()
        let prompt = ScanPromptState()
        let root = SendPresentationHarness(sheets: sheets, prompt: prompt)
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
        defer {
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
}

private struct SendPresentationHarness: View {
    @ObservedObject var sheets: SheetViewModel
    @ObservedObject var prompt: ScanPromptState
    var body: some View {
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
                SendSheet(config: config)
                    .environmentObject(sheets)
            }
    }
}

private final class ScanPromptState: ObservableObject {
    @Published var isPresented = false
}
