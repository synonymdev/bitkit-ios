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

    private func transfer(
        _ channel: String,
        _ amountSats: UInt64,
        _ heldSweeps: [(txid: String, sats: UInt64)],
        saved: [String: Bitkit.SweepShare] = [:]
    ) -> BalanceManager.HeldTransfer {
        BalanceManager.HeldTransfer(channelId: channel, amountSats: amountSats, heldSweeps: heldSweeps, savedShares: saved)
    }

    func testHeldSweepTakesAtMostTheTransferAmountOutOfSavings() {
        // A peer force close records only its first claim; an HTLC claim can pay the wallet more than that.
        let held = transfer(channelId, 1000, [("sweep-txid", 4000)])

        XCTAssertEqual(deduction([held], [broadcastSweep(channel: channelId, txid: "sweep-txid")]), 1000)
    }

    func testEarlierBatchedSweepTakesTheShareSavedWithIt() {
        // LDK reports only the replacement; the batch paid 10,000 of 100,000 sats for this channel, the rest for a
        // channel whose activity already synced.
        let sweeps = [broadcastSweep(channel: channelId, txid: "regenerated-txid")]
        let held = transfer(
            channelId,
            60000,
            [("earlier-txid", 100_000)],
            saved: ["earlier-txid": .init(channelSats: 10000, totalSats: 100_000)]
        )

        XCTAssertEqual(deduction([held], sweeps), 10000)
    }

    func testEarlierBatchedSweepOfTwoChannelsInTransferComesOutOnce() {
        let sweeps = [
            broadcastSweep(channel: channelId, txid: "regenerated-txid"),
            broadcastSweep(channel: "other-channel", txid: "regenerated-txid"),
        ]
        let first = transfer(channelId, 540, [("earlier-txid", 810)], saved: ["earlier-txid": .init(channelSats: 600, totalSats: 900)])
        let second = transfer(
            "other-channel",
            270,
            [("earlier-txid", 810)],
            saved: ["earlier-txid": .init(channelSats: 300, totalSats: 900)]
        )

        XCTAssertEqual(deduction([first, second], sweeps), 810)
    }

    func testBatchedAndSeparateSweepBothHeldComeOutWhateverTheOrder() {
        // A batch paid 10,000 sats for A and 50,000 for B; a separate sweep paid 50,000 for A alone.
        let shares: [String: Bitkit.SweepShare] = [
            "a-batch": .init(channelSats: 10000, totalSats: 60000),
            "a-separate": .init(channelSats: 50000, totalSats: 50000),
        ]
        let channelA = transfer("a", 60000, [("a-batch", 60000), ("a-separate", 50000)], saved: shares)
        let channelB = transfer("b", 60000, [("a-batch", 60000)], saved: ["a-batch": .init(channelSats: 50000, totalSats: 60000)])

        XCTAssertEqual(deduction([channelA, channelB], []), 110_000)
        XCTAssertEqual(deduction([channelB, channelA], []), 110_000)
    }

    func testSweepWithNoKnownShareComesOutOfNothing() {
        XCTAssertEqual(deduction([transfer(channelId, 1000, [("unknown-txid", 810)])], []), 0)
    }

    func testSharesAreTakenFromWhatLdkReportsForEachChannel() {
        let sweeps = [
            broadcastSweep(channel: channelId, txid: "BATCH-TXID"),
            broadcastSweep(channel: "other-channel", txid: "batch-txid"),
            .pendingBroadcast(channelId: channelId, amountSatoshis: 700),
        ]

        XCTAssertEqual(
            BalanceManager.sweepShares(channelId: channelId, pendingSweeps: sweeps),
            ["batch-txid": .init(channelSats: 500, totalSats: 1000)]
        )
    }

    func testTransferSavedBeforeSweepSharesDecodes() throws {
        let json = #"[{"id":"old","type":"FORCE_CLOSE","amountSats":1000,"channelId":"c","isSettled":false,"createdAt":1}]"#
        let transfers = try JSONDecoder().decode([Bitkit.Transfer].self, from: Data(json.utf8))

        XCTAssertNil(transfers.first?.sweepShares)
    }

    func testAddingSweepSharesKeepsTheStoredTransfer() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BalanceManagerSweepTests"))
        defaults.removePersistentDomain(forName: "BalanceManagerSweepTests")
        let storage = TransferStorage(defaults: defaults)
        try storage.insert(Transfer(id: "t", type: .forceClose, amountSats: 1000, channelId: channelId, createdAt: 1))
        try storage.markSettled(id: "t", settledAt: 2)

        try storage.addSweepShares(id: "t", shares: ["SWEEP-A": SweepShare(channelSats: 500, totalSats: 500)])
        try storage.addSweepShares(id: "t", shares: ["sweep-b": SweepShare(channelSats: 300, totalSats: 900)])

        let stored = try XCTUnwrap(storage.getById("t"))
        XCTAssertTrue(stored.isSettled)
        XCTAssertEqual(
            stored.sweepShares,
            ["sweep-a": SweepShare(channelSats: 500, totalSats: 500), "sweep-b": SweepShare(channelSats: 300, totalSats: 900)]
        )
        defaults.removePersistentDomain(forName: "BalanceManagerSweepTests")
    }
}
