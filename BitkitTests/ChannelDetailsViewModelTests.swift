@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class ChannelDetailsViewModelTests: XCTestCase {
    @MainActor
    func testPendingOrdersFiltersByPaidIdsAndState() {
        let createdPaid = makeOrder(id: "createdPaid", state2: .created)
        let paidPaid = makeOrder(id: "paidPaid", state2: .paid)
        let createdUnpaid = makeOrder(id: "createdUnpaid", state2: .created)
        let executedPaid = makeOrder(id: "executedPaid", state2: .executed)
        let expiredPaid = makeOrder(id: "expiredPaid", state2: .expired)

        let orders = [createdPaid, paidPaid, createdUnpaid, executedPaid, expiredPaid]
        let paidOrderIds: Set = ["createdPaid", "paidPaid", "executedPaid", "expiredPaid"]

        let result = ChannelDetailsViewModel.pendingOrders(
            orders: orders,
            paidOrderIds: paidOrderIds
        )

        let ids = Set(result.map(\.id))
        XCTAssertEqual(ids, ["createdPaid", "paidPaid"])
    }

    @MainActor
    func testDisplayShortChannelIdUsesOpenChannelScid() {
        let vm = ChannelDetailsViewModel.shared
        vm.foundChannel = ChannelDetails.mock(shortChannelId: 854_845_001_888_432_128)
        vm.linkedOrder = nil
        defer { resetDisplayState(vm) }

        XCTAssertEqual(vm.displayShortChannelId, "777477x916x0")
    }

    @MainActor
    func testDisplayShortChannelIdFallsBackToLinkedOrderForClosedChannel() {
        let vm = ChannelDetailsViewModel.shared
        vm.foundChannel = makeClosedChannel(fundingTxoTxid: "commitmenttxid")
        var channel = IBtChannel.mock()
        channel.shortChannelId = "854845001888432128"
        vm.linkedOrder = IBtOrder.mock(channel: channel)
        defer { resetDisplayState(vm) }

        XCTAssertEqual(vm.displayShortChannelId, "777477x916x0")
    }

    @MainActor
    func testDisplayChannelPointPrefersLinkedOrderFundingTx() {
        let vm = ChannelDetailsViewModel.shared
        // Reproduce the reported bug: the stored funding txid is actually the commitment tx.
        vm.foundChannel = makeClosedChannel(fundingTxoTxid: "commitmenttxid")
        var channel = IBtChannel.mock()
        channel.fundingTx = FundingTx(id: "fundingtxid", vout: 2)
        vm.linkedOrder = IBtOrder.mock(channel: channel)
        defer { resetDisplayState(vm) }

        XCTAssertEqual(vm.displayChannelPoint, "fundingtxid:2")
    }

    @MainActor
    func testDisplayFundingTxidPrefersLinkedOrderAndMatchesChannelPoint() {
        let vm = ChannelDetailsViewModel.shared
        vm.foundChannel = makeClosedChannel(fundingTxoTxid: "commitmenttxid")
        var channel = IBtChannel.mock()
        channel.fundingTx = FundingTx(id: "fundingtxid", vout: 2)
        vm.linkedOrder = IBtOrder.mock(channel: channel)
        defer { resetDisplayState(vm) }

        XCTAssertEqual(vm.displayFundingTxid, "fundingtxid")
        XCTAssertEqual(vm.displayChannelPoint, "fundingtxid:2")
    }

    @MainActor
    func testDisplayValuesAreNilWhenUnavailable() {
        let vm = ChannelDetailsViewModel.shared
        vm.foundChannel = makeClosedChannel(fundingTxoTxid: "")
        vm.linkedOrder = nil
        defer { resetDisplayState(vm) }

        XCTAssertNil(vm.displayShortChannelId)
        XCTAssertNil(vm.displayChannelPoint)
        XCTAssertNil(vm.displayFundingTxid)
    }

    @MainActor
    private func resetDisplayState(_ vm: ChannelDetailsViewModel) {
        vm.foundChannel = nil
        vm.linkedOrder = nil
    }

    private func makeClosedChannel(fundingTxoTxid: String) -> ClosedChannelDetails {
        ClosedChannelDetails(
            channelId: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            counterpartyNodeId: "03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad",
            fundingTxoTxid: fundingTxoTxid,
            fundingTxoIndex: 0,
            channelValueSats: 100_000,
            closedAt: 0,
            outboundCapacityMsat: 0,
            inboundCapacityMsat: 0,
            counterpartyUnspendablePunishmentReserve: 0,
            unspendablePunishmentReserve: 0,
            forwardingFeeProportionalMillionths: 0,
            forwardingFeeBaseMsat: 0,
            channelName: "",
            channelClosureReason: "commitmentTxConfirmed"
        )
    }

    private func makeOrder(id: String, state2: BtOrderState2) -> IBtOrder {
        IBtOrder(
            id: id,
            state: .created,
            state2: state2,
            feeSat: 1000,
            networkFeeSat: 2483,
            serviceFeeSat: 1520,
            lspBalanceSat: 50000,
            clientBalanceSat: 85967,
            zeroConf: false,
            zeroReserve: false,
            clientNodeId: "node123",
            channelExpiryWeeks: 52,
            channelExpiresAt: "2025-03-14T10:30:00Z",
            orderExpiresAt: "2024-03-21T15:45:00Z",
            channel: nil,
            lspNode: .init(alias: "", pubkey: "", connectionStrings: [], readonly: nil),
            lnurl: nil,
            payment: IBtPayment(
                state: .created,
                state2: .created,
                paidSat: 0,
                bolt11Invoice: IBtBolt11Invoice(
                    request: "lnbc...",
                    state: .pending,
                    expiresAt: "2024-03-21T15:45:00Z",
                    updatedAt: "2024-03-14T08:20:00Z"
                ),
                onchain: IBtOnchainTransactions(
                    address: "bc1q...",
                    confirmedSat: 0,
                    requiredConfirmations: 3,
                    transactions: []
                ),
                isManuallyPaid: nil,
                manualRefunds: nil
            ),
            couponCode: nil,
            source: nil,
            discount: nil,
            updatedAt: "2024-03-14T08:20:00Z",
            createdAt: "2024-03-14T08:15:00Z"
        )
    }
}
