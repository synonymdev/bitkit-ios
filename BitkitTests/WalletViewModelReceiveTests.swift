@testable import Bitkit
import XCTest

@MainActor
final class WalletViewModelReceiveTests: XCTestCase {
    func testOfflineRequestNeverFallsBackToOrdinaryInvoiceCreation() async {
        let wallet = WalletViewModel()
        wallet.nodeLifecycleState = .running
        wallet.channels = [.mock(isChannelReady: true, isUsable: true, inboundCapacityMsat: 1_000_000)]

        do {
            _ = try await wallet.createReceiveInvoice(amountSats: 1000, note: "", receiveOffline: true)
            XCTFail("An unavailable offline provider must fail")
        } catch OfflineReceiveError.unavailable {
            // Ordinary invoice creation would fail with nodeNotSetup instead.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOfflineRequestRequiresFixedAmount() async {
        let wallet = WalletViewModel()
        wallet.nodeLifecycleState = .running
        wallet.channels = [.mock(isChannelReady: true, isUsable: true, inboundCapacityMsat: 1_000_000)]

        do {
            _ = try await wallet.createReceiveInvoice(amountSats: nil, note: "", receiveOffline: true)
            XCTFail("An offline invoice must have an amount")
        } catch OfflineReceiveError.insufficientLiquidity {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNewReceiveSessionResetsInvoiceMode() {
        let wallet = WalletViewModel()
        wallet.invoiceReceiveOffline = true
        wallet.resetOfflineReceive()

        XCTAssertFalse(wallet.invoiceReceiveOffline)
        XCTAssertFalse(wallet.offlineReceive.isSelected)
        XCTAssertFalse(wallet.offlineReceive.isEligible)
    }

    func testReceiveLightningInvoiceRequiresReadyChannel() {
        let wallet = WalletViewModel()
        wallet.channels = [
            .mock(isChannelReady: false, isUsable: false, inboundCapacityMsat: 50_000_000),
        ]

        XCTAssertFalse(wallet.canCreateReceiveLightningInvoice(amountSats: nil))
        XCTAssertEqual(wallet.totalReadyInboundLightningSats, 0)
    }

    func testReceiveLightningInvoiceUsesReadyInboundCapacityOnly() {
        let wallet = WalletViewModel()
        wallet.channels = [
            .mock(isChannelReady: false, isUsable: false, inboundCapacityMsat: 100_000_000),
            .mock(isChannelReady: true, isUsable: false, inboundCapacityMsat: 25_000_000),
        ]

        XCTAssertEqual(wallet.totalReadyInboundLightningSats, 25000)
        XCTAssertTrue(wallet.canCreateReceiveLightningInvoice(amountSats: 25000))
        XCTAssertFalse(wallet.canCreateReceiveLightningInvoice(amountSats: 25001))
    }
}
