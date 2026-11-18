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

    func testWalletHoldingTheSweepStopsTheTransferCounting() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "sweep-txid")]

        XCTAssertTrue(BalanceManager.walletHoldsSweep(channelId: channelId, pendingSweeps: sweeps, payments: [onchainPayment(txid: "sweep-txid")]))
    }

    func testConfirmedSweepInTheWalletStopsTheTransferCounting() {
        let confirmed = PendingSweepBalance.awaitingThresholdConfirmations(
            channelId: channelId,
            latestSpendingTxid: "SWEEP-TXID",
            confirmationHash: "hash",
            confirmationHeight: 800_001,
            amountSatoshis: 500
        )

        XCTAssertTrue(BalanceManager.walletHoldsSweep(
            channelId: channelId,
            pendingSweeps: [confirmed],
            payments: [onchainPayment(txid: "sweep-txid")]
        ))
    }

    func testSweepNotYetInTheWalletKeepsTheTransferCounting() {
        let sweeps = [broadcastSweep(channel: channelId, txid: "sweep-txid")]

        XCTAssertFalse(BalanceManager.walletHoldsSweep(channelId: channelId, pendingSweeps: sweeps, payments: []))
        XCTAssertFalse(BalanceManager.walletHoldsSweep(channelId: channelId, pendingSweeps: sweeps, payments: [onchainPayment(txid: "other")]))
    }

    func testAnotherChannelsSweepOrAnUnbroadcastSweepDoesNotCount() {
        let payments = [onchainPayment(txid: "sweep-txid")]

        XCTAssertFalse(BalanceManager.walletHoldsSweep(
            channelId: channelId,
            pendingSweeps: [broadcastSweep(channel: "other-channel", txid: "sweep-txid")],
            payments: payments
        ))
        XCTAssertFalse(BalanceManager.walletHoldsSweep(
            channelId: channelId,
            pendingSweeps: [.pendingBroadcast(channelId: channelId, amountSatoshis: 500)],
            payments: payments
        ))
    }
}
