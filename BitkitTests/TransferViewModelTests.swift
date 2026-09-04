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

    // MARK: - calculateSpendingLimits affordability (bitkit-android #1179)

    /// Production LSP: the service fee grows with the client balance, so `available - fee` sits above
    /// the balance that fee priced. These are the quotes from the reported failure, where the order
    /// came to 265,727 against 265,726 available.
    @MainActor
    func testSpendingMaxIsAffordableWhenTheServiceFeeRisesWithTheClientBalance() async throws {
        let viewModel = TransferViewModel()
        let available: UInt64 = 265_726
        let quotes: [UInt64: UInt64] = [available: 4165, 261_561: 4128]
        var feeCalls: [UInt64] = []

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: available,
            lspMaxClientBalance: nil,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { clientBalance, _ in
                feeCalls.append(clientBalance)
                return try (XCTUnwrap(quotes[clientBalance]), 0)
            }
        )

        XCTAssertEqual(result.max, 261_561)
        // The order the user can build at this max must stay within what they can actually pay.
        XCTAssertLessThanOrEqual(result.max + (quotes[result.max] ?? 0), available)
        // The old derivation: `available - fee(261_561)`, a balance that quote never priced.
        XCTAssertNotEqual(result.max, available - 4128)
        // Already affordable, so the common path costs no extra round trip.
        XCTAssertEqual(feeCalls.count, 2)
    }

    /// Staging/regtest LSP: it charges the LSP side harder than the client side, so the second quote
    /// is dearer than the first and no ordering assumption holds. Capping alone would not fix this.
    @MainActor
    func testSpendingMaxIsAffordableWhenTheServiceFeeFallsWithTheClientBalance() async throws {
        let viewModel = TransferViewModel()
        let available: UInt64 = 266_478
        let quotes: [UInt64: UInt64] = [available: 1798, 264_680: 1800, 264_678: 1801, 264_677: 1801]
        var feeCalls: [UInt64] = []

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: available,
            lspMaxClientBalance: nil,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { clientBalance, _ in
                feeCalls.append(clientBalance)
                return try (XCTUnwrap(quotes[clientBalance]), 0)
            }
        )

        XCTAssertEqual(result.max, 264_677)
        // The settled max funds its own order rather than merely undercutting the first quote.
        XCTAssertLessThanOrEqual(result.max + (quotes[result.max] ?? 0), available)
        XCTAssertEqual(feeCalls, [available, 264_680, 264_678, 264_677])
    }

    /// Order creation recomputes the LSP balance from the chosen amount, so a re-quote priced against
    /// an earlier balance would verify an order that is never created.
    @MainActor
    func testSpendingMaxRequotePricesTheSplitTheOrderWillUse() async throws {
        let viewModel = TransferViewModel()
        let available: UInt64 = 266_478
        let maxChannel: UInt64 = 1_403_872
        let quotes: [UInt64: UInt64] = [available: 1798, 264_680: 1800, 264_678: 1801, 264_677: 1801]
        var feeCalls: [(clientBalance: UInt64, lspBalance: UInt64)] = []

        _ = try await viewModel.calculateSpendingLimits(
            onchainAvailable: available,
            lspMaxClientBalance: nil,
            transferValues: { clientBalance in
                // Each client balance gets its own LSP side, mirroring maxChannelSize - clientBalance.
                TransferValues(
                    defaultLspBalance: maxChannel - clientBalance,
                    minLspBalance: 50000,
                    maxLspBalance: maxChannel - clientBalance,
                    maxClientBalance: Self.optionMaxClientBalance
                )
            },
            estimateOrderFee: { clientBalance, lspBalance in
                feeCalls.append((clientBalance, lspBalance))
                return try (XCTUnwrap(quotes[clientBalance]), 0)
            }
        )

        XCTAssertEqual(feeCalls.count, 4)
        for call in feeCalls {
            XCTAssertEqual(call.lspBalance, maxChannel - call.clientBalance, "quote for \(call.clientBalance) priced the wrong split")
        }
    }

    @MainActor
    func testSpendingMaxKeepsTheLastCandidateWhenTheRequoteFails() async throws {
        let viewModel = TransferViewModel()
        let available: UInt64 = 266_478
        let quotes: [UInt64: UInt64] = [available: 1798, 264_680: 1800]

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: available,
            lspMaxClientBalance: nil,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { clientBalance, _ in
                guard let fee = quotes[clientBalance] else { throw AppError(message: "lsp unreachable", debugMessage: nil) }
                return (fee, 0)
            }
        )

        // The step-down candidate is still published rather than the unaffordable quoted balance.
        XCTAssertEqual(result.max, 264_678)
    }

    @MainActor
    func testSpendingMaxFallsBackWhenTheRoundsAreExhausted() async throws {
        let viewModel = TransferViewModel()
        let available: UInt64 = 266_478
        // The fee rises as fast as the balance steps down, so no candidate ever becomes affordable.
        let quotes: [UInt64: UInt64] = [available: 1800, 264_678: 2000, 264_478: 2200, 264_278: 2400]
        var feeCalls: [UInt64] = []

        let result = try await viewModel.calculateSpendingLimits(
            onchainAvailable: available,
            lspMaxClientBalance: nil,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { clientBalance, _ in
                feeCalls.append(clientBalance)
                return try (XCTUnwrap(quotes[clientBalance]), 0)
            }
        )

        // The exhausted loop advertises availableAmount minus the last quote, not the last candidate.
        XCTAssertEqual(result.max, available - 2400)
        XCTAssertEqual(feeCalls.count, 4)
    }

    // MARK: - Advanced receiving capacity (bitkit-android #1180)

    @MainActor
    func testAdvancedCapacityKeepsTheLspMaxWhenTheBudgetCoversIt() async {
        let viewModel = TransferViewModel()
        var quoteCount = 0

        let settled = await viewModel.settleAdvancedLspBalance(
            clientBalance: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            minLspBalance: 50000,
            maxLspBalance: 400_000,
            estimateOrderFee: { _, lspBalance in
                quoteCount += 1
                return (Self.capacityPricedFee(lspBalance), 0)
            }
        )

        XCTAssertEqual(settled, 400_000)
        XCTAssertEqual(quoteCount, 1)
    }

    @MainActor
    func testAdvancedCapacitySettlesBelowTheLspMaxWhenTheFeeOutgrowsTheBudget() async throws {
        let viewModel = TransferViewModel()
        var quotedCapacities: [UInt64] = []

        let resolved = await viewModel.settleAdvancedLspBalance(
            clientBalance: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            minLspBalance: 50000,
            maxLspBalance: 2_000_000,
            estimateOrderFee: { _, lspBalance in
                quotedCapacities.append(lspBalance)
                return (Self.capacityPricedFee(lspBalance), 0)
            }
        )
        let settled = try XCTUnwrap(resolved)

        // The fee is 1_000 + 1% of the capacity, and the budget leaves 10_000 over the client balance.
        XCTAssertEqual(settled, 900_000)
        XCTAssertLessThanOrEqual(Self.capacityPricedFee(settled), Self.advancedHeadroom)
        XCTAssertTrue(quotedCapacities.contains(settled), "the offered max must itself have been priced")
    }

    @MainActor
    func testAdvancedCapacityIsNilWhenEvenTheMinimumIsUnaffordable() async {
        let viewModel = TransferViewModel()

        let settled = await viewModel.settleAdvancedLspBalance(
            clientBalance: Self.advancedClientBalance,
            budget: Self.advancedClientBalance + 500,
            minLspBalance: 50000,
            maxLspBalance: 2_000_000,
            estimateOrderFee: { _, lspBalance in (Self.capacityPricedFee(lspBalance), 0) }
        )

        // Rejection is left to the confirm step rather than offering a range with nothing valid in it.
        XCTAssertNil(settled)
    }

    @MainActor
    func testAdvancedCapacityAdvertisesTheLspMaxWhenTheQuoteIsUnavailable() async {
        let viewModel = TransferViewModel()

        let settled = await viewModel.settleAdvancedLspBalance(
            clientBalance: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            minLspBalance: 50000,
            maxLspBalance: 2_000_000,
            estimateOrderFee: { _, _ in throw AppError(message: "lsp unreachable", debugMessage: nil) }
        )

        XCTAssertEqual(settled, 2_000_000)
    }

    @MainActor
    func testAdvancedCapacityStopsAtTheLastAffordableCapacityWhenARequoteFails() async {
        let viewModel = TransferViewModel()

        let settled = await viewModel.settleAdvancedLspBalance(
            clientBalance: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            minLspBalance: 50000,
            maxLspBalance: 2_000_000,
            estimateOrderFee: { _, lspBalance in
                // Only the two bracketing quotes succeed; every interpolated candidate fails.
                guard lspBalance == 50000 || lspBalance == 2_000_000 else {
                    throw AppError(message: "lsp unreachable", debugMessage: nil)
                }
                return (Self.capacityPricedFee(lspBalance), 0)
            }
        )

        XCTAssertEqual(settled, 50000)
    }

    /// A concave fee curve makes the interpolation overshoot, so the candidate becomes the new
    /// ceiling instead of being advertised. Whatever comes back must still be affordable.
    @MainActor
    func testAdvancedCapacityNeverAdvertisesAnOverBudgetCandidate() async throws {
        let viewModel = TransferViewModel()
        // Steep to 200k, then near-flat — the linear guess between the two ends underestimates the fee.
        let fee: (UInt64) -> UInt64 = { 1000 + min($0, 200_000) / 20 + $0.saturatingSub(200_000) / 1000 }
        var quotedCapacities: [UInt64] = []

        let resolved = await viewModel.settleAdvancedLspBalance(
            clientBalance: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            minLspBalance: 50000,
            maxLspBalance: 1_000_000,
            estimateOrderFee: { _, lspBalance in
                quotedCapacities.append(lspBalance)
                return (fee(lspBalance), 0)
            }
        )
        let settled = try XCTUnwrap(resolved)

        XCTAssertLessThanOrEqual(fee(settled), Self.advancedHeadroom)
        XCTAssertLessThan(settled, 1_000_000)
        // Candidates that priced over the headroom were rejected, not returned.
        XCTAssertTrue(quotedCapacities.contains { fee($0) > Self.advancedHeadroom && $0 != 1_000_000 })
    }

    @MainActor
    func testUpdateAdvancedTransferValuesSettlesTheMaxAndClearsTheFlag() async {
        let viewModel = TransferViewModel()
        let values = TransferValues(
            defaultLspBalance: 1_500_000,
            minLspBalance: 50000,
            maxLspBalance: 2_000_000,
            maxClientBalance: Self.optionMaxClientBalance
        )

        await viewModel.updateAdvancedTransferValues(
            clientBalanceSat: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            transferValues: { _ in values },
            estimateOrderFee: { _, lspBalance in (Self.capacityPricedFee(lspBalance), 0) }
        )

        XCTAssertEqual(viewModel.transferValues.maxLspBalance, 900_000)
        // Default must not hand back a capacity the settled max just excluded.
        XCTAssertEqual(viewModel.transferValues.defaultLspBalance, 900_000)
        XCTAssertFalse(viewModel.isSettlingAdvancedCapacity)
    }

    @MainActor
    func testUpdateAdvancedTransferValuesLeavesAnAffordableMaxUntouched() async {
        let viewModel = TransferViewModel()
        let values = TransferValues(
            defaultLspBalance: 100_000,
            minLspBalance: 50000,
            maxLspBalance: 400_000,
            maxClientBalance: Self.optionMaxClientBalance
        )

        await viewModel.updateAdvancedTransferValues(
            clientBalanceSat: Self.advancedClientBalance,
            budget: Self.advancedBudget,
            transferValues: { _ in values },
            estimateOrderFee: { _, lspBalance in (Self.capacityPricedFee(lspBalance), 0) }
        )

        XCTAssertEqual(viewModel.transferValues.maxLspBalance, 400_000)
        XCTAssertEqual(viewModel.transferValues.defaultLspBalance, 100_000)
    }

    // MARK: - Funding guards

    @MainActor
    func testCanFundOrderRejectsAnAmountOverTheBudget() async {
        let viewModel = TransferViewModel()

        let canFund = await viewModel.canFundOrder(
            clientBalance: 260_000,
            budget: 265_000,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { _, _ in (6000, 0) } // 260_000 + 6_000 is over the budget
        )

        XCTAssertFalse(canFund)
    }

    @MainActor
    func testCanFundOrderAcceptsAnAmountThatFitsTheBudget() async {
        let viewModel = TransferViewModel()

        let canFund = await viewModel.canFundOrder(
            clientBalance: 260_000,
            budget: 265_000,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { _, _ in (1000, 0) }
        )

        XCTAssertTrue(canFund)
    }

    @MainActor
    func testCanFundOrderDoesNotBlockWhenTheBudgetIsUnknown() async {
        let viewModel = TransferViewModel()

        let canFund = await viewModel.canFundOrder(
            clientBalance: 260_000,
            budget: nil,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { _, _ in (6000, 0) }
        )

        // An unreadable balance must not block the flow; confirm stays the authority.
        XCTAssertTrue(canFund)
    }

    @MainActor
    func testCanFundOrderDoesNotBlockWhenTheQuoteFails() async {
        let viewModel = TransferViewModel()

        let canFund = await viewModel.canFundOrder(
            clientBalance: 260_000,
            budget: 265_000,
            transferValues: { _ in Self.values(maxClientBalance: Self.optionMaxClientBalance) },
            estimateOrderFee: { _, _ in throw AppError(message: "lsp unreachable", debugMessage: nil) }
        )

        // A quote the LSP will not give must not block the user; confirm stays the authority.
        XCTAssertTrue(canFund)
    }

    @MainActor
    func testCanFundAdvancedOrderRejectsACapacityOverTheBudget() async {
        let viewModel = TransferViewModel()

        let canFund = await viewModel.canFundAdvancedOrder(
            clientBalance: 260_000,
            receivingAmount: 900_000,
            budget: 265_000,
            estimateOrderFee: { _, _ in (6000, 0) }
        )

        XCTAssertFalse(canFund)
    }

    @MainActor
    func testCanFundAdvancedOrderDoesNotBlockWhenTheBudgetIsUnknownOrUnquoted() async {
        let viewModel = TransferViewModel()

        let unsizedBudget = await viewModel.canFundAdvancedOrder(
            clientBalance: 260_000,
            receivingAmount: 900_000,
            budget: nil,
            estimateOrderFee: { _, _ in (6000, 0) }
        )
        let failedQuote = await viewModel.canFundAdvancedOrder(
            clientBalance: 260_000,
            receivingAmount: 900_000,
            budget: 265_000,
            estimateOrderFee: { _, _ in throw AppError(message: "lsp unreachable", debugMessage: nil) }
        )

        XCTAssertTrue(unsizedBudget)
        XCTAssertTrue(failedQuote)
    }

    @MainActor
    func testHwFundingBudgetIsNilWithoutDeviceCapabilities() async {
        let viewModel = TransferViewModel()

        // No hardware capabilities injected, so the funding guards degrade to non-blocking.
        let budget = await viewModel.hwFundingBudget(walletId: "wallet-1")

        XCTAssertNil(budget)
    }

    private static let advancedClientBalance: UInt64 = 100_000
    private static let advancedBudget: UInt64 = 110_000
    private static let advancedHeadroom: UInt64 = advancedBudget - advancedClientBalance

    /// Prices an order at a flat 1_000 plus 1% of the receiving capacity, as the LSP charges both sides.
    private static func capacityPricedFee(_ lspBalance: UInt64) -> UInt64 {
        1000 + lspBalance / 100
    }

    private static func values(maxClientBalance: UInt64) -> TransferValues {
        TransferValues(
            defaultLspBalance: lspBalance,
            minLspBalance: lspBalance,
            maxLspBalance: 0,
            maxClientBalance: maxClientBalance
        )
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
