@testable import Bitkit
import LDKNode
import XCTest

final class BalanceManagerSweepTests: XCTestCase {
    private let channelId = "closed-channel"

    private func output(txid: String, vout: UInt32 = 0, sats: UInt64 = 389) -> SpendableUtxo {
        SpendableUtxo(outpoint: OutPoint(txid: txid, vout: vout), valueSats: sats)
    }

    private func broadcastSweep(channel: String, txid: String) -> PendingSweepBalance {
        .broadcastAwaitingConfirmation(channelId: channel, latestBroadcastHeight: 800_000, latestSpendingTxid: txid, amountSatoshis: 500)
    }

    private func held(_ sweeps: [PendingSweepBalance], _ outputs: [SpendableUtxo]) -> [UInt64] {
        BalanceManager.heldSweeps(channelId: channelId, pendingSweeps: sweeps, outputs: outputs).map(\.sats)
    }

    func testHeldSweepCountsWhatItPaidTheWallet() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "sweep-txid")]

        XCTAssertEqual(held(sweeps, [output(txid: "sweep-txid"), output(txid: "other", sats: 10000)]), [389])
    }

    func testConfirmedSweepInTheWalletIsHeld() {
        let confirmed = PendingSweepBalance.awaitingThresholdConfirmations(
            channelId: channelId,
            latestSpendingTxid: "SWEEP-TXID",
            confirmationHash: "hash",
            confirmationHeight: 800_001,
            amountSatoshis: 500
        )

        XCTAssertEqual(held([confirmed], [output(txid: "sweep-txid")]), [389])
    }

    func testSweepWithoutAWalletOutputIsNotHeld() {
        // Not yet synced, evicted from the mempool, or already spent: the wallet holds no output of the sweep.
        let sweeps = [broadcastSweep(channel: channelId, txid: "sweep-txid")]

        XCTAssertEqual(held(sweeps, []), [])
        XCTAssertEqual(held(sweeps, [output(txid: "other")]), [])
    }

    func testAnotherChannelsSweepOrAnUnbroadcastSweepIsNotHeld() {
        let outputs = [output(txid: "sweep-txid")]

        XCTAssertEqual(held([broadcastSweep(channel: "other-channel", txid: "sweep-txid")], outputs), [])
        XCTAssertEqual(held([.pendingBroadcast(channelId: channelId, amountSatoshis: 500)], outputs), [])
    }

    func testBatchedSweepIsHeldOnceByEachOfItsChannels() {
        let sweeps = [
            broadcastSweep(channel: channelId, txid: "batch-txid"),
            broadcastSweep(channel: channelId, txid: "batch-txid"),
            broadcastSweep(channel: "other-channel", txid: "batch-txid"),
        ]
        let outputs = [output(txid: "batch-txid")]

        XCTAssertEqual(held(sweeps, outputs), [389])
        XCTAssertEqual(
            BalanceManager.heldSweeps(channelId: "other-channel", pendingSweeps: sweeps, outputs: outputs).map(\.txid),
            ["batch-txid"]
        )
    }

    func testEarlierSweepStillInTheWalletIsHeldAfterLdkRegeneratesIt() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "regenerated-txid")]
        let outputs = [output(txid: "earlier-txid")]

        XCTAssertEqual(held(sweeps, outputs), [])
        XCTAssertEqual(
            BalanceManager.heldSweeps(channelId: channelId, pendingSweeps: sweeps, earlierTxids: ["earlier-txid"], outputs: outputs)
                .map(\.sats),
            [389]
        )
    }
}
