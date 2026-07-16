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

    // MARK: - Claim gating

    func testIsClaimableOnlyWhileReverseLockupIsOnchainAndUnclaimed() {
        XCTAssertTrue(swap(status: .transactionMempool).isClaimable)
        XCTAssertTrue(swap(status: .transactionConfirmed).isClaimable)
        XCTAssertTrue(swap(status: .transactionClaimPending).isClaimable)

        XCTAssertFalse(swap(status: .swapCreated).isClaimable)
        XCTAssertFalse(swap(status: .swapExpired).isClaimable)
        XCTAssertFalse(swap(status: .transactionFailed).isClaimable)
        XCTAssertFalse(swap(status: .transactionRefunded).isClaimable)
        XCTAssertFalse(swap(status: .invoiceSettled).isClaimable)
        XCTAssertFalse(swap(status: .transactionConfirmed, claimTxId: "txid1").isClaimable)
        XCTAssertFalse(swap(swapType: .submarine, status: .transactionConfirmed).isClaimable)
    }

    // MARK: - Fixtures

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
