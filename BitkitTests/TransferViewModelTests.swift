@testable import Bitkit
import BitkitCore
import XCTest

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

    // MARK: - calculateSpendingLimits (Transfer → Spending max)

    @MainActor
    func testSpendingLimitsCapsAtLspMaxClientBalanceWhenOnchainExceedsIt() async throws {
        let viewModel = TransferViewModel()
        var feeCallBalances: [UInt64] = []
        // The liquidity calc reports no receiving room (maxLspBalance = 0) because the client
        // balance saturates the channel — the regression this guards against.
        let values = TransferValues(
            defaultLspBalance: Self.lspBalance,
            minLspBalance: Self.lspBalance,
            maxLspBalance: 0,
            maxClientBalance: Self.optionMaxClientBalance
        )

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: Self.onChainBalance,
            lspMaxClientBalance: Self.lspMaxClientBalance,
            transferValues: { _ in values },
            estimateOrderFee: { clientBalance, _ in
                feeCallBalances.append(clientBalance)
                return (Self.networkFee, Self.serviceFee)
            }
        )

        XCTAssertEqual(result.max, Self.optionMaxClientBalance)
        XCTAssertEqual(result.available, result.max)
        // The order fee must be estimated against the clamped client balance, not the full balance.
        XCTAssertEqual(feeCallBalances.last, Self.lspMaxClientBalance)
    }

    @MainActor
    func testSpendingLimitsUsesFullBalanceWhenLspInfoUnavailable() async throws {
        let viewModel = TransferViewModel()
        var feeCallBalances: [UInt64] = []
        let values = TransferValues(
            defaultLspBalance: Self.lspBalance,
            minLspBalance: Self.lspBalance,
            maxLspBalance: 0,
            maxClientBalance: Self.optionMaxClientBalance
        )

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: Self.onChainBalance,
            lspMaxClientBalance: nil,
            transferValues: { _ in values },
            estimateOrderFee: { clientBalance, _ in
                feeCallBalances.append(clientBalance)
                return (Self.networkFee, Self.serviceFee)
            }
        )

        XCTAssertEqual(result.max, Self.optionMaxClientBalance)
        // Without an LSP cap the order fee is estimated against the balance after the LSP fee.
        XCTAssertEqual(feeCallBalances.last, Self.onChainBalance - Self.lspFee)
    }

    @MainActor
    func testSpendingLimitsIsZeroWhenLiquidityReportsZeroClientBalance() async throws {
        let viewModel = TransferViewModel()
        let values = TransferValues(
            defaultLspBalance: Self.lspBalance,
            minLspBalance: Self.lspBalance,
            maxLspBalance: 0,
            maxClientBalance: 0
        )

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: Self.onChainBalance,
            lspMaxClientBalance: Self.lspMaxClientBalance,
            transferValues: { _ in values },
            estimateOrderFee: { _, _ in (Self.networkFee, Self.serviceFee) }
        )

        XCTAssertEqual(result.max, 0)
        XCTAssertEqual(result.available, 0)
    }

    private static let onChainBalance: UInt64 = 10_000_000
    private static let lspMaxClientBalance: UInt64 = 1_766_193
    private static let optionMaxClientBalance: UInt64 = 1_687_598
    private static let lspBalance: UInt64 = 252_368
    private static let networkFee: UInt64 = 2112
    private static let serviceFee: UInt64 = 286
    private static let lspFee: UInt64 = 2398 // networkFee + serviceFee

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
