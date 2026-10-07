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

    func testReceiveRefreshCanSkipPublicSyncWithoutChangingReceiveDetails() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        let wallet = ReceiveWalletSpy()
        let address = "receive-\(UUID().uuidString)"
        wallet.onchainAddress = address
        wallet.bolt11 = "stale-invoice"
        wallet.channels = []
        wallet.invoiceAmountSats = 1234
        wallet.invoiceNote = "test note"
        let expectedBip21 = "bitcoin:\(address)?amount=0.00001234&message=test%20note"

        try await wallet.refreshBip21(syncPublicPaykit: false)

        XCTAssertEqual(wallet.bip21, expectedBip21)
        XCTAssertTrue(wallet.bolt11.isEmpty)
        XCTAssertEqual(wallet.metadataPersistenceCount, 1)
        XCTAssertEqual(wallet.publicEndpointRefreshCount, 0)

        try await wallet.refreshBip21()

        XCTAssertEqual(wallet.bip21, expectedBip21)
        XCTAssertEqual(wallet.metadataPersistenceCount, 2)
        XCTAssertEqual(wallet.publicEndpointRefreshCount, 1)
    }

    private final class ReceiveWalletSpy: WalletViewModel {
        var metadataPersistenceCount = 0
        var publicEndpointRefreshCount = 0

        override func persistPreActivityMetadata(tags: [String]) async {
            metadataPersistenceCount += 1
        }

        override func refreshPublicPaykitEndpoints(
            forceRefreshBolt11: Bool,
            includeOnchain: Bool,
            includeLightning: Bool
        ) async throws -> (onchainAddress: String, bolt11: String) {
            publicEndpointRefreshCount += 1
            throw PublicPaykitError.walletNotReady
        }
    }
}
