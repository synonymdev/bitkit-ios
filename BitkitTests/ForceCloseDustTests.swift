@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class ForceCloseDustTests: XCTestCase {
    private let channelId = "dust-channel"

    func testDustSweepIsUnsweepable() {
        let sweeps: [PendingSweepBalance] = [
            .broadcastAwaitingConfirmation(
                channelId: channelId,
                latestBroadcastHeight: 800_000,
                latestSpendingTxid: "rejected-sweep-txid",
                amountSatoshis: 388
            ),
        ]

        XCTAssertTrue(TransferService.isDustOnlySweep(channelId: channelId, pendingSweeps: sweeps))
    }

    func testSweepsAddingUpToASweepableAmountAreNotDust() {
        let sweeps: [PendingSweepBalance] = [
            .pendingBroadcast(channelId: channelId, amountSatoshis: 400),
            .pendingBroadcast(channelId: channelId, amountSatoshis: 64),
            .pendingBroadcast(channelId: "other-channel", amountSatoshis: 1),
        ]

        XCTAssertFalse(TransferService.isDustOnlySweep(channelId: channelId, pendingSweeps: sweeps))
    }

    func testDustThresholdIsInclusive() {
        let atLimit: [PendingSweepBalance] = [
            .pendingBroadcast(channelId: channelId, amountSatoshis: TransferService.maxUnsweepableSats),
        ]
        let aboveLimit: [PendingSweepBalance] = [
            .pendingBroadcast(channelId: channelId, amountSatoshis: TransferService.maxUnsweepableSats + 1),
        ]

        XCTAssertTrue(TransferService.isDustOnlySweep(channelId: channelId, pendingSweeps: atLimit))
        XCTAssertFalse(TransferService.isDustOnlySweep(channelId: channelId, pendingSweeps: aboveLimit))
    }

    func testClosedChannelBalanceIsOurBalanceNotCapacity() {
        let closed = ClosedChannelDetails(
            channelId: channelId,
            counterpartyNodeId: "nodeId",
            fundingTxoTxid: "txid",
            fundingTxoIndex: 0,
            channelValueSats: 20000,
            closedAt: 0,
            outboundCapacityMsat: 0,
            inboundCapacityMsat: 0,
            counterpartyUnspendablePunishmentReserve: 0,
            unspendablePunishmentReserve: 388,
            forwardingFeeProportionalMillionths: 0,
            forwardingFeeBaseMsat: 0,
            channelName: "",
            channelClosureReason: "counterpartyForceClosed"
        )

        XCTAssertEqual(closed.balanceOnCloseSats, 388)
    }
}
