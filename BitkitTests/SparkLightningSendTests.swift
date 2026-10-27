@testable import Bitkit
import BitkitCore
import BreezSdkSpark
import XCTest

@MainActor
final class SparkLightningSendTests: XCTestCase {
    func testLightningInvoiceWithoutChannelsOpensPaymentWhenSparkCanPay() async throws {
        var checkedAmount: UInt64?
        let app = makeApp(hasChannelFreeRail: true) {
            checkedAmount = $0
            return true
        }

        try await app.handleScannedData("lnbcrt1sparkonly")

        XCTAssertEqual(checkedAmount, 100)
        XCTAssertNotNil(app.scannedLightningInvoice)
        XCTAssertEqual(app.selectedWalletToPayFrom, .lightning)
        XCTAssertFalse(app.didRejectScannedPayment)
    }

    func testSparkSendReturnsBeforeCompletionSoCallersSeeTheCompletionEvent() {
        guard case let .bolt11Invoice(_, completionTimeoutSecs) = SparkManager.bolt11SendOptions else {
            return XCTFail("Expected bolt11 send options")
        }
        XCTAssertNil(completionTimeoutSecs)
    }

    func testLightningInvoiceWithoutChannelsOrSparkIsRejected() async throws {
        let app = makeApp(hasChannelFreeRail: false) { _ in false }

        try await app.handleScannedData("lnbcrt1sparkonly")

        XCTAssertTrue(app.didRejectScannedPayment)
    }

    private func makeApp(hasChannelFreeRail: Bool, canSendLightning: @escaping (UInt64) -> Bool) -> AppViewModel {
        AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 9572,
                        hasChannels: false,
                        hasUsableChannels: false,
                        hasChannelFreeRail: hasChannelFreeRail
                    )
                },
                canSendLightning: canSendLightning,
                decodeInvoice: { _ in .lightning(invoice: self.invoice) }
            )
        )
    }

    private var invoice: LightningInvoice {
        LightningInvoice(
            bolt11: "lnbcrt1sparkonly",
            paymentHash: Data(),
            amountSatoshis: 100,
            timestampSeconds: UInt64(Date().timeIntervalSince1970),
            expirySeconds: 3600,
            isExpired: false,
            description: nil,
            networkType: .regtest,
            payeeNodeId: nil
        )
    }
}
