@testable import Bitkit
import BreezSdkSpark
import XCTest

final class SparkTransferActivityTests: XCTestCase {
    func testDepositsAndWithdrawalsAreTransfersButFailedOnesAndLightningAreNot() {
        let unclaimed = DepositInfo(
            txid: "pending-deposit", vout: 0, amountSats: 7500, isMature: true,
            refundTx: nil, refundTxId: nil, refundState: nil, claimError: nil, instantClaimStatus: nil, maxClaimFee: nil
        )
        let payments = [
            payment(id: "1", status: .completed, details: .deposit(txId: "claimed-deposit", vout: 0)),
            payment(id: "2", status: .completed, details: .withdraw(txId: "withdrawal", vout: 0, destinationAddress: "bcrt1qsavings")),
            payment(id: "3", status: .failed, details: .withdraw(txId: "failed-withdrawal", vout: 0, destinationAddress: "bcrt1qsavings")),
            payment(id: "4", status: .completed, details: nil),
        ]

        let txIds = SparkManager.transferTxIds(unclaimed: [unclaimed], payments: payments)

        XCTAssertEqual(txIds, ["pending-deposit", "claimed-deposit", "withdrawal"])
    }

    func testADepositClaimedEarlyIsListedOnlyAsClaimed() {
        let deposits = ["claimed-early", "pending-deposit"].map {
            DepositInfo(
                txid: $0, vout: 0, amountSats: 7500, isMature: true,
                refundTx: nil, refundTxId: nil, refundState: nil, claimError: nil, instantClaimStatus: nil, maxClaimFee: nil
            )
        }
        let claimed = [payment(id: "1", status: .completed, details: .deposit(txId: "claimed-early", vout: 0))]

        let unclaimed = SparkManager.unclaimedDeposits(deposits, claimed: claimed)

        XCTAssertEqual(unclaimed.map(\.txid), ["pending-deposit"], "A deposit claimed early still shows as in progress")
    }

    func testAClaimedDepositHidesOnlyItsOwnOutputOfTheTransaction() {
        let deposits = [0, 1].map {
            DepositInfo(
                txid: "batched", vout: $0, amountSats: 7500, isMature: true,
                refundTx: nil, refundTxId: nil, refundState: nil, claimError: nil, instantClaimStatus: nil, maxClaimFee: nil
            )
        }
        let claimed = [payment(id: "1", status: .completed, details: .deposit(txId: "batched", vout: 0))]

        let unclaimed = SparkManager.unclaimedDeposits(deposits, claimed: claimed)

        XCTAssertEqual(unclaimed.map(\.vout), [1], "Another output of a claimed deposit's transaction was hidden")
    }

    func testARecoveredReadBalanceNotifiesEvenWhenItEqualsTheShownOne() {
        let kept = SparkBalances(readSats: 0, keptSats: 9000, pendingSats: 0)
        let recovered = SparkBalances(readSats: 9000, keptSats: nil, pendingSats: 0)

        XCTAssertTrue(SparkManager.balancesChanged(from: kept, to: recovered), "Sendable stayed 0 after Spark read the balance again")
        XCTAssertFalse(SparkManager.balancesChanged(from: recovered, to: recovered))
        XCTAssertTrue(SparkManager.balancesChanged(from: recovered, to: SparkBalances(readSats: 9000, keptSats: nil, pendingSats: 1)))
    }

    func testAZeroReadAfterAFailedWithdrawalOrSyncKeepsTheLastKnownBalance() {
        XCTAssertEqual(
            SparkManager.keptBalanceSats(read: 0, lastShown: 9000, isStale: true, withdrewAll: false),
            9000,
            "The balance read 0 while stale"
        )
        XCTAssertNil(SparkManager.keptBalanceSats(read: 0, lastShown: 9000, isStale: false, withdrewAll: false))
        XCTAssertNil(SparkManager.keptBalanceSats(read: 4000, lastShown: 9000, isStale: true, withdrewAll: false))
        XCTAssertNil(SparkManager.keptBalanceSats(read: 0, lastShown: 0, isStale: true, withdrewAll: false))
    }

    func testAZeroReadAfterASuccessfulWithdrawalDropsTheLastShownBalance() {
        XCTAssertNil(
            SparkManager.keptBalanceSats(read: 0, lastShown: 9000, isStale: true, withdrewAll: true),
            "The withdrawn balance stayed shown while Spark's last sync had failed"
        )
    }

    func testASyncedZeroReadAfterAFailedWithdrawalClearsTheKeptBalance() {
        XCTAssertNil(
            SparkManager.withdrawalFailedAt(100, read: 0, lastSyncedAt: 101, syncFailed: false),
            "A sync after the failed withdrawal read 0 and the balance stayed kept"
        )
        XCTAssertEqual(SparkManager.withdrawalFailedAt(100, read: 0, lastSyncedAt: 40, syncFailed: false), 100)
        XCTAssertEqual(SparkManager.withdrawalFailedAt(100, read: 0, lastSyncedAt: 101, syncFailed: true), 100)
        XCTAssertEqual(SparkManager.withdrawalFailedAt(100, read: 0, lastSyncedAt: nil, syncFailed: false), 100)
        XCTAssertNil(SparkManager.withdrawalFailedAt(100, read: 4000, lastSyncedAt: nil, syncFailed: true))
    }

    func testListsWithdrawalsWithWhatSparkKept() {
        let payments = [
            payment(id: "1", status: .completed, details: .withdraw(txId: "withdrawal", vout: 0, destinationAddress: "bcrt1qsavings"), fees: 1470),
            payment(
                id: "2",
                status: .failed,
                details: .withdraw(txId: "failed-withdrawal", vout: 0, destinationAddress: "bcrt1qsavings"),
                fees: 1470
            ),
            payment(id: "3", status: .completed, details: .deposit(txId: "deposit", vout: 0)),
        ]

        let withdrawals = SparkManager.withdrawals(payments)

        XCTAssertEqual(withdrawals, [SparkWithdrawal(txid: "withdrawal", amountSats: 1000, feeSats: 1470)])
    }

    private func payment(id: String, status: PaymentStatus, details: PaymentDetails?, fees: U128 = 0) -> Payment {
        Payment(
            id: id,
            paymentType: .receive,
            status: status,
            amount: 1000,
            fees: fees,
            timestamp: 1,
            method: .deposit,
            details: details,
            conversionDetails: nil
        )
    }
}
