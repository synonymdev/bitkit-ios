@testable import Bitkit
import XCTest

@MainActor
final class WalletViewModelReceiveTests: XCTestCase {
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
