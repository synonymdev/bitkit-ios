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

    func testEarlierSweepSavedOnTheTransferIsHeldAfterLdkRegeneratesIt() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "regenerated-txid")]
        let outputs = [output(txid: "earlier-txid")]

        XCTAssertEqual(held(sweeps, outputs), [])
        XCTAssertEqual(
            BalanceManager.heldSweeps(channelId: channelId, pendingSweeps: sweeps, earlierTxids: ["earlier-txid"], outputs: outputs)
                .map(\.sats),
            [389]
        )
    }

    func testSharedSweepTakesOnlyThisChannelsPartOutOfSavings() {
        let sweeps: [PendingSweepBalance] = [
            .broadcastAwaitingConfirmation(
                channelId: channelId,
                latestBroadcastHeight: 800_000,
                latestSpendingTxid: "batch-txid",
                amountSatoshis: 600
            ),
            .broadcastAwaitingConfirmation(
                channelId: "other-channel",
                latestBroadcastHeight: 800_000,
                latestSpendingTxid: "batch-txid",
                amountSatoshis: 300
            ),
        ]

        XCTAssertEqual(BalanceManager.channelShareSats(channelId: channelId, sweep: ("batch-txid", 810), pendingSweeps: sweeps), 540)
        XCTAssertEqual(BalanceManager.channelShareSats(channelId: "other-channel", sweep: ("batch-txid", 810), pendingSweeps: sweeps), 270)
        XCTAssertNil(BalanceManager.channelShareSats(channelId: channelId, sweep: ("earlier-txid", 810), pendingSweeps: sweeps))
    }

    private func deduction(_ transfers: [BalanceManager.HeldTransfer], _ sweeps: [PendingSweepBalance]) -> UInt64 {
        BalanceManager.heldSweepsDeduction(transfers: transfers, pendingSweeps: sweeps)
    }

    func testHeldSweepTakesAtMostTheTransferAmountOutOfSavings() {
        // A peer force close records only its first claim; an HTLC claim can pay the wallet more than that.
        let transfer = BalanceManager.HeldTransfer(channelId: channelId, amountSats: 1000, heldSweeps: [("sweep-txid", 4000)])

        XCTAssertEqual(deduction([transfer], [broadcastSweep(channel: channelId, txid: "sweep-txid")]), 1000)
    }

    func testEarlierBatchedSweepTakesAtMostTheTransferAmountOutOfSavings() {
        // LDK reports only the replacement, so the earlier batched sweep's shares are unknown.
        let transfer = BalanceManager.HeldTransfer(channelId: channelId, amountSats: 540, heldSweeps: [("earlier-txid", 810)])

        XCTAssertEqual(deduction([transfer], [broadcastSweep(channel: channelId, txid: "regenerated-txid")]), 540)
    }

    func testEarlierBatchedSweepOfTwoChannelsInTransferComesOutOnce() {
        let sweeps = [
            broadcastSweep(channel: channelId, txid: "regenerated-txid"),
            broadcastSweep(channel: "other-channel", txid: "regenerated-txid"),
        ]
        let first = BalanceManager.HeldTransfer(channelId: channelId, amountSats: 540, heldSweeps: [("earlier-txid", 810)])
        let second = BalanceManager.HeldTransfer(channelId: "other-channel", amountSats: 270, heldSweeps: [("earlier-txid", 810)])
        let larger = BalanceManager.HeldTransfer(channelId: "other-channel", amountSats: 1000, heldSweeps: [("earlier-txid", 810)])

        XCTAssertEqual(deduction([first, second], sweeps), 810)
        XCTAssertEqual(deduction([first, larger], sweeps), 810)
    }

    func testTransferSavedBeforeSweepTxidsDecodes() throws {
        let json = #"[{"id":"old","type":"FORCE_CLOSE","amountSats":1000,"channelId":"c","isSettled":false,"createdAt":1}]"#
        let transfers = try JSONDecoder().decode([Bitkit.Transfer].self, from: Data(json.utf8))

        XCTAssertNil(transfers.first?.sweepTxids)
    }

    func testAddingSweepTxidsKeepsTheStoredTransfer() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BalanceManagerSweepTests"))
        defaults.removePersistentDomain(forName: "BalanceManagerSweepTests")
        let storage = TransferStorage(defaults: defaults)
        try storage.insert(Transfer(id: "t", type: .forceClose, amountSats: 1000, channelId: channelId, createdAt: 1))
        try storage.markSettled(id: "t", settledAt: 2)

        try storage.addSweepTxids(id: "t", txids: ["SWEEP-A"])
        try storage.addSweepTxids(id: "t", txids: ["sweep-b"])

        let stored = try XCTUnwrap(storage.getById("t"))
        XCTAssertTrue(stored.isSettled)
        XCTAssertEqual(stored.sweepTxids, ["sweep-a", "sweep-b"])
        defaults.removePersistentDomain(forName: "BalanceManagerSweepTests")
    }
}
