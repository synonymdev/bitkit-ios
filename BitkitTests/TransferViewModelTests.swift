import BitkitCore
import XCTest

@testable import Bitkit

final class TransferViewModelTests: XCTestCase {
    @MainActor
    func testDisplayOrderPrefersUiStateOrder() {
        let viewModel = TransferViewModel()
        let baseOrder = makeOrder(id: "base", clientBalanceSat: 100_000, lspBalanceSat: 50000)
        let updatedOrder = makeOrder(id: "updated", clientBalanceSat: 150_000, lspBalanceSat: 75000)

        let fallback = viewModel.displayOrder(for: baseOrder)
        XCTAssertEqual(fallback.id, baseOrder.id)
        XCTAssertEqual(fallback.clientBalanceSat, baseOrder.clientBalanceSat)

        viewModel.uiState.order = updatedOrder
        let result = viewModel.displayOrder(for: baseOrder)
        XCTAssertEqual(result.id, updatedOrder.id)
        XCTAssertEqual(result.clientBalanceSat, updatedOrder.clientBalanceSat)
    }

    private func makeOrder(id: String, clientBalanceSat: UInt64, lspBalanceSat: UInt64) -> IBtOrder {
        IBtOrder(
            id: id,
            state: .created,
            state2: .created,
            feeSat: 1000,
            networkFeeSat: 2483,
            serviceFeeSat: 1520,
            lspBalanceSat: lspBalanceSat,
            clientBalanceSat: clientBalanceSat,
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
