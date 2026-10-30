@testable import Bitkit
import LDKNode
import XCTest

final class ArkadeManagerTests: XCTestCase {
    func testMarksADepositBoardedOnceItsBoardingSettles() {
        let history = [
            entry(boardingTxid: "boarded", type: ArkadeHistoryEntry.received, amount: 35000, settled: true),
            entry(boardingTxid: "waiting", type: ArkadeHistoryEntry.received, amount: 15000, settled: false),
            entry(arkTxid: "lightning", type: ArkadeHistoryEntry.received, amount: 1000, settled: true),
        ]

        let deposits = ArkadeManager.deposits(history)

        XCTAssertEqual(deposits, [
            ArkadeDeposit(txid: "waiting", amountSats: 15000, isClaimed: false),
            ArkadeDeposit(txid: "boarded", amountSats: 35000, isClaimed: true),
        ])
    }

    func testDepositStageFollowsConfirmationAndBoarding() {
        XCTAssertEqual(ArkadeDepositStage(deposit: nil), .looking)
        XCTAssertEqual(ArkadeDepositStage(deposit: ArkadeDeposit(txid: "a", amountSats: 1, isClaimed: false, confirmations: 0)), .looking)
        XCTAssertEqual(ArkadeDepositStage(deposit: ArkadeDeposit(txid: "a", amountSats: 1, isClaimed: false, confirmations: 1)), .boarding)
        XCTAssertEqual(ArkadeDepositStage(deposit: ArkadeDeposit(txid: "a", amountSats: 1, isClaimed: true)), .boarded)
    }

    func testListsOffboardsAsWithdrawals() {
        let history = [
            entry(commitmentTxid: "offboard", type: ArkadeHistoryEntry.sent, amount: 4917, settled: true),
            entry(commitmentTxid: "batch", arkTxid: "payment", type: ArkadeHistoryEntry.sent, amount: 100, settled: true),
        ]

        XCTAssertEqual(ArkadeManager.withdrawals(history), [ArkadeWithdrawal(txid: "offboard", amountSats: 4917, feeSats: 0)])
    }

    func testRecordsOnlyReceivesNoSwapOrBoardingCovers() {
        let entries = [
            entry(arkTxid: "offline", type: ArkadeHistoryEntry.received, amount: 2100, settled: true),
            entry(arkTxid: "swap-claim", type: ArkadeHistoryEntry.received, amount: 990, settled: true),
            entry(boardingTxid: "deposit", type: ArkadeHistoryEntry.received, amount: 5000, settled: true),
            entry(arkTxid: "sent", type: ArkadeHistoryEntry.sent, amount: 300, settled: true),
        ]

        let receives = ArkadeManager.offlineReceives(entries, swapClaims: [990])

        XCTAssertEqual(receives.map(\.arkTxid), ["offline"])
    }

    func testNextExpiryIsTheSoonestUnsweptOutputInSeconds() {
        let vtxos = [
            ArkadeVtxo(txid: "a", batchExpiry: 1_800_000_000_000, isSwept: false),
            ArkadeVtxo(txid: "b", batchExpiry: 1_700_000_000, isSwept: true),
            ArkadeVtxo(txid: "c", batchExpiry: 1_750_000_000, isSwept: nil),
        ]

        XCTAssertEqual(ArkadeManager.nextExpiry(vtxos), 1_750_000_000)
        XCTAssertNil(ArkadeManager.nextExpiry([]))
    }

    func testRaisesAClaimedReceiveAsAReceivedPayment() {
        let swap = ArkadeSwap(id: "s", direction: "receive", outcome: "claimed", takeSat: 990, feeSat: 10, paymentHash: "aa")

        guard case let .paymentReceived(_, paymentHash, amountMsat, _) = ArkadeManager.nodeEvent(for: swap) else {
            return XCTFail("Expected a received payment")
        }
        XCTAssertEqual(paymentHash, "aa")
        XCTAssertEqual(amountMsat, 990_000)
        XCTAssertNil(ArkadeManager.nodeEvent(for: ArkadeSwap(direction: "receive", outcome: "pending", paymentHash: "aa")))
    }

    func testRaisesAPaidSendWithItsFeeAndAFailedOne() {
        let paid = ArkadeSwap(direction: "send", outcome: "paid", takeSat: 1000, feeSat: 7, paymentHash: "bb")
        guard case let .paymentSuccessful(_, paymentHash, _, feePaidMsat) = ArkadeManager.nodeEvent(for: paid) else {
            return XCTFail("Expected a successful payment")
        }
        XCTAssertEqual(paymentHash, "bb")
        XCTAssertEqual(feePaidMsat, 7000)

        let refunded = ArkadeSwap(direction: "send", outcome: "refunded", paymentHash: "cc")
        guard case .paymentFailed = ArkadeManager.nodeEvent(for: refunded) else { return XCTFail("Expected a failed payment") }
    }

    func testRecordsASendAtOnceButAReceiveOnlyOnceClaimed() throws {
        let pendingSend = ArkadeSwap(direction: "send", outcome: "funded", takeSat: 1000, feeSat: 7, bolt11: "lnbc1", paymentHash: "dd")
        let details = try XCTUnwrap(ArkadeManager.paymentDetails(for: pendingSend))
        XCTAssertEqual(details.status, .pending)
        XCTAssertEqual(details.direction, .outbound)
        XCTAssertEqual(details.amountMsat, 1_000_000)

        XCTAssertNil(ArkadeManager.paymentDetails(for: ArkadeSwap(direction: "receive", outcome: "pending", paymentHash: "ee")))
        XCTAssertEqual(
            ArkadeManager.railPayment(ArkadeSwap(direction: "receive", outcome: "claimed", paymentHash: "FF")),
            Bitkit.ChannelFreeRailPayment(paymentHash: "ff", direction: .inbound, status: .succeeded, preimage: nil)
        )
    }

    func testRefusesToPayAnInvoiceWithoutAnAmount() async {
        do {
            _ = try await ArkadeManager.shared.estimateRoutingFees(bolt11: "not-an-invoice", amountSats: 100)
            XCTFail("Expected an amountless invoice to be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "AmountlessInvoice")
        }
    }

    private func entry(
        boardingTxid: String? = nil,
        commitmentTxid: String? = nil,
        arkTxid: String? = nil,
        type: String,
        amount: Int64,
        settled: Bool
    ) -> ArkadeHistoryEntry {
        ArkadeHistoryEntry(
            boardingTxid: boardingTxid,
            commitmentTxid: commitmentTxid,
            arkTxid: arkTxid,
            type: type,
            amount: amount,
            settled: settled,
            createdAt: 1_700_000_000_000
        )
    }
}
