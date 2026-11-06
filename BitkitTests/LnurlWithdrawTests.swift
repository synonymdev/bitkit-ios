@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class LnurlWithdrawTests: XCTestCase {
    private let withdrawData = LnurlWithdrawData(
        uri: "https://example.com/withdraw", callback: "https://example.com/callback", k1: "k1",
        defaultDescription: "Withdraw", minWithdrawable: 1_000_000, maxWithdrawable: 5_000_000, tag: "withdrawRequest"
    )

    func testAmountResetWhileMountedDoesNotCrash() async {
        var continued = false
        await assertResetWhileMountedDoesNotCrash(LnurlWithdrawAmount { continued = true })
        XCTAssertFalse(continued)
    }

    func testConfirmResetWhileMountedDoesNotCrash() async {
        var failedAmount: UInt64?
        await assertResetWhileMountedDoesNotCrash(LnurlWithdrawConfirm { failedAmount = $0 })
        XCTAssertNil(failedAmount)
    }

    func testWithdrawFailingAfterDismissalIsNotReported() async {
        for isDismissed in [false, true] {
            let wallet = SuspendedInvoiceWallet()
            var failureCount = 0
            let withdraw = Task {
                await LnurlWithdrawConfirm.withdraw(withdrawData: withdrawData, amountSats: 2000, wallet: wallet) {
                    XCTFail("A failed withdraw must not report success")
                } onFailure: {
                    failureCount += 1
                }
            }
            await fulfillment(of: [wallet.started], timeout: 3)
            if isDismissed {
                // The screen cancels its withdraw when it disappears, while the invoice is still pending.
                withdraw.cancel()
            }
            wallet.failInvoice()
            await withdraw.value

            XCTAssertEqual(failureCount, isDismissed ? 0 : 1, "dismissed: \(isDismissed)")
        }
    }

    private func assertResetWhileMountedDoesNotCrash(_ screen: some View) async {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        app.lnurlWithdrawData = withdrawData
        wallet.lnurlWithdrawAmount = 2000
        let view = screen
            .environmentObject(app)
            .environmentObject(wallet)
            .environmentObject(SheetViewModel())
            .environmentObject(CurrencyViewModel(currencyService: OfflineCurrencyService()))
            .environmentObject(SettingsViewModel.shared)
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

        // A deep link or scan resets the send state while the sheet still shows this screen.
        app.resetSendState()
        XCTAssertNil(app.lnurlWithdrawData)
        await Task.yield()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        _ = hostingController.sizeThatFits(in: window.bounds.size)
        XCTAssertNotNil(hostingController.view.window)

        app.lnurlWithdrawData = withdrawData
        await Task.yield()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        XCTAssertGreaterThan(hostingController.sizeThatFits(in: window.bounds.size).height, 0)
    }
}

private final class SuspendedInvoiceWallet: WalletViewModel {
    let started = XCTestExpectation(description: "Invoice creation suspended")
    private var continuation: CheckedContinuation<Void, Never>?

    init() {
        super.init(
            transferService: TransferService(lightningService: .shared),
            sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager()
        )
    }

    override func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        throw URLError(.timedOut)
    }

    func failInvoice() {
        continuation?.resume()
        continuation = nil
    }
}
