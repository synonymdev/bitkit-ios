@testable import Bitkit
import LDKNode
import XCTest

final class LightningServiceConfigTests: XCTestCase {
    private struct BuildAttemptEnded: Error {}

    func testReconcileBeforeSyncContinuesAfterAnAccountFailure() async throws {
        try await LightningService.reconcileBeforeSync { throw BuildAttemptEnded() }
    }

    func testReconcileBeforeSyncStopsWhenCancelled() async {
        do {
            try await LightningService.reconcileBeforeSync { throw CancellationError() }
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBuildRetriesWithoutPaykitServerAccountsWhenTheNodeRejectsOne() {
        var config = LightningService.nodeConfig(walletIndex: 0)
        config.onchainWalletAccounts = [OnchainWalletAccountConfig(addressType: .nativeSegwit, accountIndex: 1, xpub: "xpub-1")]
        var attempts: [[OnchainWalletAccountConfig]] = []

        XCTAssertThrowsError(try LightningService.buildAcceptingPaykitServerAccounts(config: config) { config in
            attempts.append(config.onchainWalletAccounts)
            if !config.onchainWalletAccounts.isEmpty {
                throw BuildError.InvalidSeedBytes(message: "xpub mismatch")
            }
            throw BuildAttemptEnded()
        }) {
            XCTAssertTrue($0 is BuildAttemptEnded)
        }

        XCTAssertEqual(attempts.map(\.count), [1, 0])
    }

    func testBuildDoesNotRetryWithoutPaykitServerAccounts() {
        var config = LightningService.nodeConfig(walletIndex: 0)
        config.onchainWalletAccounts = []
        var attempts = 0

        XCTAssertThrowsError(try LightningService.buildAcceptingPaykitServerAccounts(config: config) { _ in
            attempts += 1
            throw BuildError.InvalidSeedBytes(message: "bad seed")
        })

        XCTAssertEqual(attempts, 1)
    }

    func testBuildDoesNotRetryOnOtherBuildErrors() {
        var config = LightningService.nodeConfig(walletIndex: 0)
        config.onchainWalletAccounts = [OnchainWalletAccountConfig(addressType: .nativeSegwit, accountIndex: 1, xpub: "xpub-1")]
        var attempts = 0

        XCTAssertThrowsError(try LightningService.buildAcceptingPaykitServerAccounts(config: config) { _ in
            attempts += 1
            throw BuildError.WalletSetupFailed(message: "wallet")
        })

        XCTAssertEqual(attempts, 1)
    }

    func testNodeConfigTrustsNoPeer() {
        let config = LightningService.nodeConfig(walletIndex: 0)

        XCTAssertTrue(config.trustedPeers0conf.isEmpty)
        XCTAssertEqual(config.anchorChannelsConfig?.trustedPeersNoReserve, [])
        XCTAssertEqual(config.anchorChannelsConfig?.perChannelReserveSats, 1)
    }

    func testIdlePeersAreStoredPeersWithNoChannelAndNoClaimableBalance() {
        let channel = ChannelDetails.mock()
        let peers = [
            peer("idle"),
            peer(channel.counterpartyNodeId),
            peer("withClaim"),
            peer("notStored", isPersisted: false),
        ]
        let claims: [LightningBalance] = [
            .claimableAwaitingConfirmations(
                channelId: "closed",
                counterpartyNodeId: "withClaim",
                amountSatoshis: 1000,
                confirmationHeight: 100,
                source: .holderForceClosed
            ),
        ]

        let idle = LightningService.idlePeerIds(peers: peers, channels: [channel], lightningBalances: claims, pendingSweeps: [])

        XCTAssertEqual(idle, ["idle"])
    }

    func testNoPeerIsIdleWhileAClosedChannelAwaitsItsSweep() {
        let sweeps: [PendingSweepBalance] = [.pendingBroadcast(channelId: "closed", amountSatoshis: 1000)]

        let idle = LightningService.idlePeerIds(peers: [peer("idle")], channels: [], lightningBalances: [], pendingSweeps: sweeps)

        XCTAssertTrue(idle.isEmpty)
    }

    private func peer(_ nodeId: String, isPersisted: Bool = true) -> PeerDetails {
        PeerDetails(nodeId: nodeId, address: "127.0.0.1:9735", isPersisted: isPersisted, isConnected: true)
    }
}
