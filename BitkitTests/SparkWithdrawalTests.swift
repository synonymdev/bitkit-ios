@testable import Bitkit
import XCTest

final class SparkWithdrawalTests: XCTestCase {
    // MARK: - Quote reuse

    func testQuoteHoldsForTheSameAddressAndBalanceUntilShortlyBeforeItExpires() {
        let quote = SparkWithdrawalQuote(address: "bcrt1q-savings", balanceSats: 99901, expiresAt: 1000)

        XCTAssertTrue(quote.holds(address: "bcrt1q-savings", balanceSats: 99901, now: 900))
        XCTAssertFalse(quote.holds(address: "bcrt1q-savings", balanceSats: 99901, now: 1000 - SparkWithdrawalQuote.expiryMarginSecs))
        XCTAssertFalse(quote.holds(address: "bcrt1q-other", balanceSats: 99901, now: 900))
        XCTAssertFalse(quote.holds(address: "bcrt1q-savings", balanceSats: 100_000, now: 900))
    }

    func testEstimateNeverHolds() {
        let estimate = SparkWithdrawalQuote(address: "bcrt1q-savings", balanceSats: 99901, expiresAt: 0)

        XCTAssertFalse(estimate.holds(address: "bcrt1q-savings", balanceSats: 99901, now: 0))
    }

    // MARK: - Fee pricing

    @MainActor
    func testPricesTheFeeOncePerBalanceToOneAddress() async {
        let transfer = TransferViewModel()
        let calls = PriceCalls()
        transfer.priceSparkWithdrawal = { address in
            await calls.record(address)
            return 2190
        }

        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-first")
        await waitUntilPriced(transfer)
        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-second")
        await waitUntilPriced(transfer)

        XCTAssertEqual(transfer.sparkWithdrawFeeSats, 2190)
        let addresses = await calls.addresses
        XCTAssertEqual(addresses, ["bcrt1q-first"])

        transfer.loadSparkWithdrawFee(balanceSats: 50000, savingsAddress: "bcrt1q-second")
        await waitUntilPriced(transfer)

        let repriced = await calls.addresses
        XCTAssertEqual(repriced, ["bcrt1q-first", "bcrt1q-first"])
    }

    @MainActor
    func testGivesUpOnASlowQuoteAndPricesAgainNextTime() async {
        let transfer = TransferViewModel()
        transfer.sparkFeeTimeout = 0.1
        transfer.priceSparkWithdrawal = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return 2190
        }

        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        XCTAssertTrue(transfer.isPricingSparkWithdrawal)
        await waitUntilPriced(transfer)

        XCTAssertNil(transfer.sparkWithdrawFeeSats)

        transfer.priceSparkWithdrawal = { _ in 2190 }
        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)

        XCTAssertEqual(transfer.sparkWithdrawFeeSats, 2190)
    }

    // MARK: - Failed withdrawal

    func testFailedSparkWithdrawalIsShownAndNamesWhetherChannelsMoved() {
        XCTAssertEqual(
            SavingsTransferOutcome.resolve(sparkFailed: true, movedChannels: true, channelsFailedToClose: false),
            .sparkFailed(channelsMoved: true)
        )
        XCTAssertEqual(
            SavingsTransferOutcome.resolve(sparkFailed: true, movedChannels: false, channelsFailedToClose: false),
            .sparkFailed(channelsMoved: false)
        )
        XCTAssertEqual(
            SavingsTransferOutcome.resolve(sparkFailed: false, movedChannels: true, channelsFailedToClose: false),
            .success
        )
        XCTAssertEqual(
            SavingsTransferOutcome.resolve(sparkFailed: true, movedChannels: true, channelsFailedToClose: true),
            .channelsInterrupted
        )
    }

    // MARK: - Withdrawal receipt

    func testWithdrawalReceiptIsMatchedByItsTxid() {
        let listed = [SparkWithdrawal(txid: "listed", amountSats: 97711, feeSats: 2190)]

        XCTAssertTrue(SparkManager.isWithdrawal(txid: "sent", sent: ["sent"], withdrawals: []))
        XCTAssertTrue(SparkManager.isWithdrawal(txid: "listed", sent: [], withdrawals: listed))
        XCTAssertFalse(SparkManager.isWithdrawal(txid: "payment", sent: ["sent"], withdrawals: listed))
    }

    @MainActor
    private func waitUntilPriced(_ transfer: TransferViewModel) async {
        for _ in 0 ..< 100 where transfer.isPricingSparkWithdrawal {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private actor PriceCalls {
    private(set) var addresses: [String] = []

    func record(_ address: String) {
        addresses.append(address)
    }
}
