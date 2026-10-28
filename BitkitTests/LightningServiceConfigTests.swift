@testable import Bitkit
import LDKNode
import XCTest

final class LightningServiceConfigTests: XCTestCase {
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
