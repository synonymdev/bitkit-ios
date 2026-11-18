@testable import Bitkit
import LDKNode
import XCTest

final class BalanceManagerSweepTests: XCTestCase {
    private let channelId = "closed-channel"

    private func onchainPayment(txid: String) -> LDKNode.PaymentDetails {
        LDKNode.PaymentDetails(
            id: txid,
            kind: .onchain(txid: txid, status: .unconfirmed),
            amountMsat: 389_000,
            feePaidMsat: nil,
            direction: .inbound,
            status: .pending,
            latestUpdateTimestamp: 0
        )
    }

    private func broadcastSweep(channel: String, txid: String) -> PendingSweepBalance {
        .broadcastAwaitingConfirmation(channelId: channel, latestBroadcastHeight: 800_000, latestSpendingTxid: txid, amountSatoshis: 500)
    }

    private func held(_ sweeps: [PendingSweepBalance], _ payments: [LDKNode.PaymentDetails]) -> [UInt64] {
        BalanceManager.heldSweeps(channelId: channelId, pendingSweeps: sweeps, payments: payments).map(\.sats)
    }

    func testHeldSweepCountsWhatItPaidTheWallet() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "sweep-txid")]

        XCTAssertEqual(held(sweeps, [onchainPayment(txid: "sweep-txid")]), [389])
    }

    func testConfirmedSweepInTheWalletIsHeld() {
        let confirmed = PendingSweepBalance.awaitingThresholdConfirmations(
            channelId: channelId,
            latestSpendingTxid: "SWEEP-TXID",
            confirmationHash: "hash",
            confirmationHeight: 800_001,
            amountSatoshis: 500
        )

        XCTAssertEqual(held([confirmed], [onchainPayment(txid: "sweep-txid")]), [389])
    }

    func testSweepNotYetInTheWalletIsNotHeld() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "sweep-txid")]

        XCTAssertEqual(held(sweeps, []), [])
        XCTAssertEqual(held(sweeps, [onchainPayment(txid: "other")]), [])
    }

    func testAnotherChannelsSweepOrAnUnbroadcastSweepIsNotHeld() {
        let payments = [onchainPayment(txid: "sweep-txid")]

        XCTAssertEqual(held([broadcastSweep(channel: "other-channel", txid: "sweep-txid")], payments), [])
        XCTAssertEqual(held([.pendingBroadcast(channelId: channelId, amountSatoshis: 500)], payments), [])
    }

    func testBatchedSweepIsHeldByEachOfItsChannels() {
        let sweeps = [
            broadcastSweep(channel: channelId, txid: "batch-txid"),
            broadcastSweep(channel: "other-channel", txid: "batch-txid"),
        ]
        let payments = [onchainPayment(txid: "batch-txid")]

        XCTAssertEqual(held(sweeps, payments), [389])
        XCTAssertEqual(
            BalanceManager.heldSweeps(channelId: "other-channel", pendingSweeps: sweeps, payments: payments).map(\.txid),
            ["batch-txid"]
        )
    }
}
