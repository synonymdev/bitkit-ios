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

    func testStagedCloseKeepsItsClaimsInTransferOnceOneSweepLands() {
        // A 1,000-sat estimate: a 600-sat sweep that paid the wallet 580, and a 400-sat claim still in Lightning.
        let sweeps = [broadcastSweep(channel: channelId, txid: "landed-txid")]
        var counted = Set<String>()

        let before = BalanceManager.closeTransferInTransfer(
            channelId: channelId, estimateSats: 1000, channelClaimsSats: 400,
            pendingSweeps: sweeps, earlierTxids: [], outputs: [], countedSweepTxids: &counted
        )
        let after = BalanceManager.closeTransferInTransfer(
            channelId: channelId, estimateSats: 1000, channelClaimsSats: 400,
            pendingSweeps: sweeps, earlierTxids: [], outputs: [output(txid: "landed-txid", sats: 580)], countedSweepTxids: &counted
        )

        XCTAssertEqual(before.onchainToSubtract, 0)
        XCTAssertEqual(before.pendingAmount, 1000)
        XCTAssertEqual(after.onchainToSubtract, 580)
        XCTAssertEqual(after.pendingAmount, 980)
    }

    func testSweepsTheWalletDoesNotHoldYetStayInTransfer() {
        let sweeps = [
            broadcastSweep(channel: channelId, txid: "landed-txid"),
            .pendingBroadcast(channelId: channelId, amountSatoshis: 300),
            broadcastSweep(channel: channelId, txid: "unsynced-txid"),
        ]
        var counted = Set<String>()

        let amounts = BalanceManager.closeTransferInTransfer(
            channelId: channelId, estimateSats: 2000, channelClaimsSats: 0,
            pendingSweeps: sweeps, earlierTxids: [], outputs: [output(txid: "landed-txid", sats: 480)], countedSweepTxids: &counted
        )

        XCTAssertEqual(amounts.onchainToSubtract, 480)
        XCTAssertEqual(amounts.pendingAmount, 480 + 300 + 500)
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
