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
