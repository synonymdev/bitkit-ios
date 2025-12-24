import BitkitCore
import XCTest

@testable import Bitkit

final class ChannelDetailsViewModelTests: XCTestCase {
    @MainActor
    func testPendingOrdersFiltersByPaidIdsAndState() {
        let createdPaid = makeOrder(id: "createdPaid", state2: .created)
        let paidPaid = makeOrder(id: "paidPaid", state2: .paid)
        let createdUnpaid = makeOrder(id: "createdUnpaid", state2: .created)
        let executedPaid = makeOrder(id: "executedPaid", state2: .executed)
        let expiredPaid = makeOrder(id: "expiredPaid", state2: .expired)

        let orders = [createdPaid, paidPaid, createdUnpaid, executedPaid, expiredPaid]
        let paidOrderIds: Set<String> = ["createdPaid", "paidPaid", "executedPaid", "expiredPaid"]

        let result = ChannelDetailsViewModel.pendingOrders(
            orders: orders,
            paidOrderIds: paidOrderIds
        )

        let ids = Set(result.map(\.id))
        XCTAssertEqual(ids, ["createdPaid", "paidPaid"])
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
