@testable import Bitkit
import XCTest

@MainActor
final class WalletViewModelReceiveTests: XCTestCase {
    func testChannelUsabilityRefreshHonorsPaykitMaintenancePermission() {
        XCTAssertTrue(WalletViewModel.shouldRefreshPaykitAfterChannelChange(
            allowPaykitMaintenance: true,
            hadUsableChannels: false,
            hasUsableChannels: true
        ))
        XCTAssertFalse(WalletViewModel.shouldRefreshPaykitAfterChannelChange(
            allowPaykitMaintenance: false,
            hadUsableChannels: false,
            hasUsableChannels: true
        ))
    }

    func testEventDrivenPaykitMaintenanceRemainsSuspendedAfterFailedValidation() {
        let wallet = WalletViewModel()

        XCTAssertFalse(wallet.isPaykitMaintenanceAllowed)
        wallet.setPaykitMaintenanceAllowed(false)

        XCTAssertFalse(wallet.isPaykitMaintenanceAllowed)
        XCTAssertFalse(WalletViewModel.shouldRefreshPaykitAfterChannelChange(
            allowPaykitMaintenance: wallet.isPaykitMaintenanceAllowed,
            hadUsableChannels: false,
            hasUsableChannels: true
        ))
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
