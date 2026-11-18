@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class ForceCloseDustTests: XCTestCase {
    private let channelId = "dust-channel"

    private func sweep(_ sats: UInt64, channel: String? = nil) -> PendingSweepBalance {
        .pendingBroadcast(channelId: channel ?? channelId, amountSatoshis: sats)
    }

    func testChangeBelowDustAfterTheFloorFeeIsUnsweepable() {
        let sweeps: [PendingSweepBalance] = [
            .broadcastAwaitingConfirmation(
                channelId: channelId,
                latestBroadcastHeight: 800_000,
                latestSpendingTxid: "rejected-sweep-txid",
                amountSatoshis: 388
            ),
        ]

        XCTAssertTrue(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .nativeSegwit))
        XCTAssertTrue(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .taproot))
    }

    func testDustDependsOnTheChangeAddressType() {
        // 500 sats leave a native SegWit or Taproot output but are below the legacy and nested SegWit dust limits
        let sweeps = [sweep(500)]

        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .nativeSegwit))
        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .taproot))
        XCTAssertTrue(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .nestedSegwit))
        XCTAssertTrue(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .legacy))
    }

    func testTaprootBoundIsOneLightestInputAtTheFeeFloor() {
        // 486 WU at 253 sat/kW is 122 sats, plus 330 sats of Taproot dust
        XCTAssertTrue(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: [sweep(451)], changeType: .taproot))
        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: [sweep(452)], changeType: .taproot))
    }

    func testSweepableCounterpartyCloseOutputKeepsWaiting() {
        // 410 sats leave 299 sats of native SegWit change at the floor, above its 294-sat dust limit
        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: [sweep(410)], changeType: .nativeSegwit))
    }

    func testDustBatchedWithAnotherChannelSweepIsSweepable() {
        let sweeps = [sweep(388), sweep(388, channel: "other-channel")]

        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: sweeps, changeType: .taproot))
    }

    func testNoUnconfirmedSweepIsNotUnsweepable() {
        let confirmed: PendingSweepBalance = .awaitingThresholdConfirmations(
            channelId: channelId,
            latestSpendingTxid: "sweep-txid",
            confirmationHash: "block-hash",
            confirmationHeight: 800_000,
            amountSatoshis: 388
        )

        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: [], changeType: .taproot))
        XCTAssertFalse(TransferService.isUnsweepable(channelId: channelId, pendingSweeps: [confirmed], changeType: .taproot))
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
