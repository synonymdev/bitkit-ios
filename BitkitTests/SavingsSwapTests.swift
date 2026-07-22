import BitkitCore
import XCTest

@testable import Bitkit

final class SavingsSwapTests: XCTestCase {
    // MARK: - Quote math

    func testQuoteBuildsFeeBreakdown() {
        let quote = SavingsSwapQuote.build(amountSat: 148_500, limits: limits())

        XCTAssertEqual(quote.amountSat, 148_500)
        XCTAssertEqual(quote.networkFeeSat, 300)
        // 0.5% of 148_500 = 742.5, rounded to 743
        XCTAssertEqual(quote.swapFeeSat, 743)
        XCTAssertEqual(quote.receiveSat, 148_500 - 743 - 300)
    }

    func testQuoteClampsReceiveAtZeroWhenFeesExceedAmount() {
        let quote = SavingsSwapQuote.build(amountSat: 100, limits: limits(minerFeesSat: 500))

        XCTAssertEqual(quote.receiveSat, 0)
    }

    // MARK: - Network support

    func testSwapsAreUnsupportedOffMainnet() {
        // Unit tests run on regtest, where Boltz resolves to a local backend no build can reach.
        XCTAssertEqual(Env.network, .regtest)
        XCTAssertFalse(Env.isSwapSupported)
        XCTAssertFalse(BoltzService.shared.isSwapSupported)
    }

    func testSwapsStayDisabledWithoutTheDevFlag() {
        withSavingsSwapDevFlag(false) {
            XCTAssertFalse(BoltzService.shared.isSwapEnabled)
        }
    }

    func testDevFlagAloneDoesNotEnableSwapsOffMainnet() {
        withSavingsSwapDevFlag(true) {
            XCTAssertFalse(BoltzService.shared.isSwapEnabled)
        }
    }

    // MARK: - Transfer mode

    @MainActor
    func testTransferToSavingsFallsBackToCloseWithoutAQuote() async {
        let transfer = TransferViewModel()
        // Swaps are unsupported here, so no quote can be published and the swipe must still commit.
        await transfer.loadSavingsSwapQuote(requestedSat: 100_000, spendableSats: 100_000)
        XCTAssertNil(transfer.savingsSwapState.quote)

        transfer.onTransferToSavingsConfirm(channels: [])

        XCTAssertEqual(transfer.savingsTransferMode, .close)
    }

    @MainActor
    func testTransferToSavingsSwapsWithAQuoteAndClosesWhenTheUserOptsOut() {
        let transfer = TransferViewModel()
        transfer.savingsSwapState = SavingsSwapState(
            quote: SavingsSwapQuote.build(amountSat: 100_000, limits: limits()),
            minSat: 25000,
            maxSat: 100_000
        )

        transfer.onTransferToSavingsConfirm(channels: [])
        XCTAssertEqual(transfer.savingsTransferMode, .swap)

        transfer.onTransferToSavingsConfirm(channels: [], mode: .close)
        XCTAssertEqual(transfer.savingsTransferMode, .close)
    }

    // MARK: - Claim gating

    func testIsClaimableWhileReverseSwapIsUnclaimedAndNotTerminal() {
        XCTAssertTrue(swap(status: .transactionMempool).isClaimable)
        XCTAssertTrue(swap(status: .transactionConfirmed).isClaimable)
        XCTAssertTrue(swap(status: .transactionClaimPending).isClaimable)
        XCTAssertTrue(swap(status: .invoicePending).isClaimable)

        // A stalled updates stream leaves the swap at swapCreated locally even once Boltz has
        // locked up on-chain, so the claim must stay reachable: this is the recovery case.
        XCTAssertTrue(swap(status: .swapCreated).isClaimable)
    }

    func testIsClaimableFalseForTerminalAlreadyClaimedAndSubmarineSwaps() {
        XCTAssertFalse(swap(status: .swapExpired).isClaimable)
        XCTAssertFalse(swap(status: .transactionFailed).isClaimable)
        XCTAssertFalse(swap(status: .transactionLockupFailed).isClaimable)
        XCTAssertFalse(swap(status: .transactionRefunded).isClaimable)
        XCTAssertFalse(swap(status: .transactionClaimed).isClaimable)
        XCTAssertFalse(swap(status: .invoiceSettled).isClaimable)
        XCTAssertFalse(swap(status: .invoiceExpired).isClaimable)
        XCTAssertFalse(swap(status: .invoiceFailedToPay).isClaimable)
        XCTAssertFalse(swap(status: .transactionConfirmed, claimTxId: "txid1").isClaimable)
        XCTAssertFalse(swap(swapType: .submarine, status: .transactionConfirmed).isClaimable)
    }

    // MARK: - Fixtures

    private func withSavingsSwapDevFlag(_ enabled: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.bool(forKey: BoltzService.savingsSwapEnabledKey)
        defaults.set(enabled, forKey: BoltzService.savingsSwapEnabledKey)
        defer { defaults.set(previous, forKey: BoltzService.savingsSwapEnabledKey) }
        body()
    }

    private func limits(
        minimalSat: UInt64 = 25000,
        maximalSat: UInt64 = 1_000_000,
        feePercentage: Double = 0.5,
        minerFeesSat: UInt64 = 300
    ) -> BoltzPairInfo {
        BoltzPairInfo(
            hash: "hash",
            rate: 1.0,
            minimalSat: minimalSat,
            maximalSat: maximalSat,
            feePercentage: feePercentage,
            minerFeesSat: minerFeesSat
        )
    }

    private func swap(
        swapType: BoltzSwapType = .reverse,
        status: BoltzSwapStatus = .transactionConfirmed,
        claimTxId: String? = nil
    ) -> BoltzSwap {
        BoltzSwap(
            id: "swap1",
            swapType: swapType,
            status: status,
            network: .regtest,
            swapIndex: 0,
            amountSat: 100_000,
            onchainAmountSat: 99000,
            invoice: nil,
            lockupAddress: nil,
            onchainAddress: nil,
            timeoutBlockHeight: 800,
            createdAt: 0,
            claimTxId: claimTxId,
            refundTxId: nil
        )
    }
}
