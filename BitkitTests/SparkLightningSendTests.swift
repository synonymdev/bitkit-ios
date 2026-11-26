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

    func testExpiredInvoiceRefusalUsesTheScannerExpiryCopy() {
        let refusal = SparkManager.expiredInvoiceRefusal(SdkError.InvalidInput("Invoice has expired"))
        XCTAssertEqual(refusal?.errorDescription, t("other__scan__error__expired"))
        XCTAssertNil(SparkManager.expiredInvoiceRefusal(SdkError.InvalidInput("Invalid amount")))
        XCTAssertNil(SparkManager.expiredInvoiceRefusal(SdkError.Generic("Invoice has expired")))
    }

    func testLightningInvoiceWithoutChannelsOrSparkIsRejected() async throws {
        let app = makeApp(hasChannelFreeRail: false) { _ in false }

        try await app.handleScannedData("lnbcrt1sparkonly")

        XCTAssertTrue(app.didRejectScannedPayment)
    }

    func testAUnifiedInvoiceNothingOnSpendingCanPayOpensSavings() async throws {
        // A channel whose peer is offline, with nothing to send even once it is back, and no Spark balance.
        let app = makeUnifiedApp(channelOutboundSats: 0) { _ in false }

        try await app.handleScannedData(Self.unifiedUri)

        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain, "Spending was picked with nothing to pay from")
        XCTAssertNil(app.scannedLightningInvoice)
        XCTAssertNotNil(app.scannedOnchainInvoice)
    }

    func testAUnifiedInvoiceSparkCanPayOpensSpending() async throws {
        let app = makeUnifiedApp(channelOutboundSats: 0) { _ in true }

        try await app.handleScannedData(Self.unifiedUri)

        XCTAssertEqual(app.selectedWalletToPayFrom, .lightning)
        XCTAssertNotNil(app.scannedLightningInvoice)
    }

    func testAUnifiedInvoiceAChannelWithAnOfflinePeerCouldPayStillOpensSpending() async throws {
        let app = makeUnifiedApp(channelOutboundSats: 5000) { _ in false }

        try await app.handleScannedData(Self.unifiedUri)

        XCTAssertEqual(app.selectedWalletToPayFrom, .lightning)
    }

    private static let unifiedUri = "bitcoin:bcrt1q95ukqhq8q3ymg74zvzpy0n9f8ec6xq26as60u3?lightning=lnbcrt1sparkonly"

    private func makeUnifiedApp(channelOutboundSats: UInt64, canSendLightning: @escaping (UInt64) -> Bool) -> AppViewModel {
        AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true,
                        spendableOnchainBalanceSats: 50000,
                        totalLightningBalanceSats: 0,
                        hasChannels: true,
                        hasUsableChannels: false,
                        hasChannelFreeRail: true,
                        channelOutboundSats: channelOutboundSats
                    )
                },
                canSendLightning: canSendLightning,
                decodeInvoice: { uri in
                    uri.hasPrefix("bitcoin:")
                        ? .onChain(invoice: OnChainInvoice(
                            address: "bcrt1q95ukqhq8q3ymg74zvzpy0n9f8ec6xq26as60u3", amountSatoshis: 0, label: nil, message: nil,
                            params: ["lightning": "lnbcrt1sparkonly"]
                        ))
                        : .lightning(invoice: self.invoice)
                }
            )
        )
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
