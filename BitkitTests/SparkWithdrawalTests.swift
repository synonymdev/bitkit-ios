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

    @MainActor
    func testTheFeeTimeoutEndsTheWaitWhileTheSdkCallIgnoresCancellation() async {
        let transfer = TransferViewModel()
        transfer.sparkFeeTimeout = 0.05
        // Like the Breez bridge, this call doesn't observe task cancellation.
        transfer.priceSparkWithdrawal = { _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume(returning: 2190) }
            }
        }
        let start = Date()

        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)

        XCTAssertFalse(transfer.isPricingSparkWithdrawal)
        XCTAssertNil(transfer.sparkWithdrawFeeSats)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    @MainActor
    func testASparkBalanceTooSmallToMoveLeavesTheChannelsToMoveByDefault() async {
        let transfer = TransferViewModel()
        transfer.beginSavingsTransfer()
        transfer.priceSparkWithdrawal = { _ in 1250 }
        transfer.loadSparkWithdrawFee(balanceSats: 1000, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)

        let selection = transfer.savingsSelection(readyChannelIds: ["channel"], sparkSats: 1000)

        XCTAssertEqual(selection, SavingsSelection(channelIds: ["channel"], withdrawsSpark: false))
        XCTAssertTrue(transfer.isSparkWithdrawalPriced(withdrawsSpark: selection.withdrawsSpark), "Spark held the channels back")
    }

    @MainActor
    func testABalanceThatLeavesDustAfterItsFeeIsTooSmallToMove() async {
        let transfer = TransferViewModel()
        transfer.priceSparkWithdrawal = { _ in 1093 }

        transfer.loadSparkWithdrawFee(balanceSats: 1093 + UInt64(Env.dustLimit) - 1, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)

        XCTAssertTrue(transfer.isSparkWithdrawTooSmall)
        XCTAssertNil(transfer.sparkWithdrawFeeSats)
        XCTAssertFalse(transfer.isSparkWithdrawalPriced(withdrawsSpark: true))

        transfer.loadSparkWithdrawFee(balanceSats: 1093 + UInt64(Env.dustLimit), savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)

        XCTAssertFalse(transfer.isSparkWithdrawTooSmall)
        XCTAssertEqual(transfer.sparkWithdrawFeeSats, 1093)
    }

    @MainActor
    func testCloseInsteadWaitsForTheSparkFee() {
        let transfer = TransferViewModel()

        let committed = transfer.onTransferToSavingsConfirm(channels: [], withdrawsSpark: true, mode: .close)

        XCTAssertFalse(committed, "A Spark withdrawal was committed with no fee shown")
        XCTAssertFalse(transfer.hasChannelsToClose)
    }

    @MainActor
    func testNoSecondCommitWhileTheSwipeRepricesTheSparkFee() async throws {
        let transfer = TransferViewModel()
        transfer.priceSparkWithdrawal = { _ in 2190 }
        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)
        let gate = PriceGate()
        transfer.priceSparkWithdrawal = { _ in
            await gate.wait()
            return 2190
        }

        let recheck = Task { try await transfer.recheckSparkWithdrawFee() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let committedDuringRecheck = transfer.onTransferToSavingsConfirm(channels: [], withdrawsSpark: true, mode: .close)
        await gate.open()
        try await recheck.value

        XCTAssertFalse(committedDuringRecheck, "Close instead committed while the swipe was repricing")
        XCTAssertTrue(transfer.onTransferToSavingsConfirm(channels: [], withdrawsSpark: true))
    }

    @MainActor
    func testTheSwipeResetsWhenSparksBalanceChangesDuringItsRecheck() async throws {
        let transfer = TransferViewModel()
        transfer.priceSparkWithdrawal = { _ in 2190 }
        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)
        let recheckGate = PriceGate()
        transfer.priceSparkWithdrawal = { _ in
            await recheckGate.wait()
            return 2190
        }

        let swipe = Task { try await transfer.confirmSavingsSwipe(channels: [], withdrawsSpark: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let repriceGate = PriceGate()
        transfer.priceSparkWithdrawal = { _ in
            await repriceGate.wait()
            return 2300
        }
        // A receive lands during the recheck, so the confirm screen prices the new balance.
        transfer.loadSparkWithdrawFee(balanceSats: 120_000, savingsAddress: "bcrt1q-savings")
        await recheckGate.open()

        do {
            try await swipe.value
            XCTFail("The swipe committed while Spark's new balance was being priced")
        } catch {
            XCTAssertTrue(error is SavingsCommitRefused, "Unexpected error: \(error)")
        }
        await repriceGate.open()
        await waitUntilPriced(transfer)
        XCTAssertEqual(transfer.sparkWithdrawFeeSats, 2300)
    }

    @MainActor
    func testTheSwipeWithdrawsSparkAtTheFeeItConfirmedWhenSparkIsPricedAgainBeforeTheWithdrawal() async throws {
        let transfer = await pricedTransfer()
        try await transfer.confirmSavingsSwipe(channels: [], withdrawsSpark: true)

        let withdrawnFeeSats = try await repriceAndWithdraw(transfer)

        XCTAssertEqual(withdrawnFeeSats, 1470, "Spark withdrew at a fee priced after the swipe")
    }

    @MainActor
    func testCloseInsteadWithdrawsSparkAtTheFeeShownWhenSparkIsPricedAgainBeforeTheWithdrawal() async throws {
        let transfer = await pricedTransfer()
        XCTAssertTrue(transfer.onTransferToSavingsConfirm(channels: [], withdrawsSpark: true, mode: .close))

        let withdrawnFeeSats = try await repriceAndWithdraw(transfer)

        XCTAssertEqual(withdrawnFeeSats, 1470, "Spark withdrew at a fee priced after close instead")
    }

    @MainActor
    private func pricedTransfer() async -> TransferViewModel {
        let transfer = TransferViewModel()
        transfer.priceSparkWithdrawal = { _ in 1470 }
        transfer.loadSparkWithdrawFee(balanceSats: 40000, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)
        return transfer
    }

    /// A receive lands during the transition, so the confirm screen prices Spark's new balance, then the transfer runs.
    @MainActor
    private func repriceAndWithdraw(_ transfer: TransferViewModel) async throws -> UInt64? {
        transfer.priceSparkWithdrawal = { _ in 1620 }
        transfer.loadSparkWithdrawFee(balanceSats: 52000, savingsAddress: "bcrt1q-savings")
        await waitUntilPriced(transfer)
        let withdrawn = WithdrawnFee()
        transfer.sparkBalanceSats = { 52000 }
        transfer.withdrawSpark = { _, feeSats in withdrawn.feeSats = feeSats }
        _ = try await transfer.closeSelectedChannels()
        return withdrawn.feeSats
    }

    // MARK: - Failed withdrawal

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

private actor PriceGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class WithdrawnFee {
    var feeSats: UInt64?
}
