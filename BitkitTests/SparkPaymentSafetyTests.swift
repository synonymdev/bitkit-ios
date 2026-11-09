@testable import Bitkit
import BreezSdkSpark
import LDKNode
import XCTest

@MainActor
final class SparkPaymentSafetyTests: XCTestCase {
    private struct RefreshFailed: Error {}

    // MARK: - Start

    func testAStartWhileConnectedDoesNotRewriteEveryActivity() async throws {
        var upserts: [String: Int] = [:]
        var synced = false
        let sync = { ["a", "b"].forEach { upserts[$0, default: 0] += 1 } }

        for _ in 0 ..< 2 {
            synced = try await SparkManager.startConnected(activitiesSynced: synced, refresh: {}, syncActivities: sync)
        }

        XCTAssertEqual(upserts, ["a": 1, "b": 1])
    }

    func testAStartWhoseRefreshFailedLeavesTheActivitySyncToTheNext() async throws {
        var syncs = 0
        var synced = false

        do {
            synced = try await SparkManager.startConnected(
                activitiesSynced: synced,
                refresh: { throw RefreshFailed() },
                syncActivities: { syncs += 1 }
            )
            XCTFail("Expected the refresh to fail")
        } catch {}
        synced = try await SparkManager.startConnected(activitiesSynced: synced, refresh: {}, syncActivities: { syncs += 1 })

        XCTAssertTrue(synced)
        XCTAssertEqual(syncs, 1)
    }

    // MARK: - Settled payment events

    func testSettledPaymentIsRecordedAndEmittedEvenWhenTheRefreshFails() async {
        var steps: [String] = []

        await SparkManager.handleSettledPayment(
            lightningPayment(type: .send, status: .completed),
            record: { _ in steps.append("record") },
            emit: { event in
                if case .paymentSuccessful = event {
                    steps.append("emit")
                }
            },
            refresh: {
                steps.append("refresh")
                throw RefreshFailed()
            }
        )

        XCTAssertEqual(steps, ["record", "emit", "refresh"])
    }

    func testReceivedPaymentEmitsItsNodeEvent() {
        let event = SparkManager.nodeEvent(for: lightningPayment(type: .receive, status: .completed))

        guard case let .paymentReceived(_, paymentHash, amountMsat, _) = event else {
            return XCTFail("Expected a receive, got \(String(describing: event))")
        }
        XCTAssertEqual(paymentHash, "hash")
        XCTAssertEqual(amountMsat, 1_000_000)
    }

    // MARK: - Withdrawal

    func testSentWithdrawalSucceedsWhenTheRefreshAfterItFails() async throws {
        var refreshed = false

        try await SparkManager.settleWithdrawal(status: .pending) {
            refreshed = true
            throw RefreshFailed()
        }

        XCTAssertTrue(refreshed)
    }

    func testWithdrawalSparkReportsFailedFails() async {
        do {
            try await SparkManager.settleWithdrawal(status: .failed) {}
            XCTFail("Expected Spark's failed status to fail the withdrawal")
        } catch {}
    }

    func testWithdrawalFeeAboveTheShownFeeIsRefused() throws {
        XCTAssertNoThrow(try SparkManager.checkWithdrawalFee(2190, shownFeeSats: 2190))
        XCTAssertNoThrow(try SparkManager.checkWithdrawalFee(2000, shownFeeSats: 2190))
        XCTAssertThrowsError(try SparkManager.checkWithdrawalFee(2191, shownFeeSats: 2190)) { error in
            XCTAssertEqual(error as? SparkWithdrawalFeeIncreased, SparkWithdrawalFeeIncreased(feeSats: 2191, shownFeeSats: 2190))
        }
    }

    func testSwipeWaitsForTheSparkWithdrawalFee() {
        let transfer = TransferViewModel()

        XCTAssertFalse(transfer.isSparkWithdrawalPriced(withdrawsSpark: true))
        XCTAssertTrue(transfer.isSparkWithdrawalPriced(withdrawsSpark: false))

        transfer.sparkWithdrawFeeSats = 2190

        XCTAssertTrue(transfer.isSparkWithdrawalPriced(withdrawsSpark: true))
    }

    func testRecheckShowsTheHigherFeeAndAsksAgain() async throws {
        let transfer = TransferViewModel()
        let fee = FeeQuotes([2190, 2500])
        transfer.priceSparkWithdrawal = { _ in await fee.next() }
        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        for _ in 0 ..< 100 where transfer.isPricingSparkWithdrawal {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(transfer.sparkWithdrawFeeSats, 2190)

        do {
            try await transfer.recheckSparkWithdrawFee()
            XCTFail("Expected the higher fee to ask for another swipe")
        } catch let increase as SparkWithdrawalFeeIncreased {
            XCTAssertEqual(increase.shownFeeSats, 2190)
        }
        XCTAssertEqual(transfer.sparkWithdrawFeeSats, 2500)
    }

    func testWithdrawalSendsWithTheShownFeeAsItsCap() async throws {
        let transfer = TransferViewModel()
        transfer.priceSparkWithdrawal = { _ in 2190 }
        transfer.sparkBalanceSats = { 99901 }
        var sent: (String, UInt64)?
        transfer.withdrawSpark = { sent = ($0, $1) }
        transfer.loadSparkWithdrawFee(balanceSats: 99901, savingsAddress: "bcrt1q-savings")
        for _ in 0 ..< 100 where transfer.isPricingSparkWithdrawal {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        transfer.onTransferToSavingsConfirm(channels: [], withdrawsSpark: true)

        _ = try await transfer.closeSelectedChannels()

        XCTAssertEqual(sent?.0, "bcrt1q-savings")
        XCTAssertEqual(sent?.1, 2190)
    }

    // MARK: - Transfer to spending minimum

    func testTransferMustStayClaimableAtTheClaimFeeCap() {
        let fees = SparkClaimFees(instantMaxSats: 500, laterSats: 300)
        let quote = { (deposit: UInt64) in
            SparkTransferQuote(address: "bcrt1q-spark", satsPerVbyte: 2, networkFeeSats: 200, depositSats: deposit, claimFees: fees)
        }

        XCTAssertFalse(quote(400).coversClaimFee, "Above the later fee but not the cap a mature claim may cost")
        XCTAssertFalse(quote(500).coversClaimFee)
        XCTAssertTrue(quote(501).coversClaimFee)
    }

    // MARK: - Error copy

    func testSdkErrorsShowAppCopy() {
        XCTAssertEqual(
            SparkErrorCopy.message(for: SdkError.InsufficientFunds(tokenIdentifier: nil), fallback: "fallback"),
            t("other__pay_insufficient_spending_description")
        )
        XCTAssertEqual(SparkErrorCopy.message(for: SdkError.SparkError("raw sdk text"), fallback: "fallback"), "fallback")
        XCTAssertEqual(
            ChannelFreeRailSendRefused(reason: "copy", underlying: SdkError.SparkError("raw sdk text")).errorDescription,
            "copy"
        )
    }

    func testSentQuoteMustStayWithinTheFeeLimit() {
        XCTAssertNoThrow(try SparkManager.checkSendFee(10, maxFeeSats: 10))
        XCTAssertNoThrow(try SparkManager.checkSendFee(500, maxFeeSats: nil))
        XCTAssertThrowsError(try SparkManager.checkSendFee(11, maxFeeSats: 10)) { error in
            XCTAssertTrue(error is Bitkit.ChannelFreeRailSendRefused)
        }
    }

    func testAFreshQuoteThatRaisesTheTotalNeedsAnotherSwipe() {
        func quote(networkFee: UInt64, instantClaimFee: UInt64) -> SparkTransferQuote {
            SparkTransferQuote(
                address: "bcrt1q-spark", satsPerVbyte: 2, networkFeeSats: networkFee, depositSats: 100_000,
                claimFees: SparkClaimFees(instantMaxSats: instantClaimFee, laterSats: 198)
            )
        }
        let approved = quote(networkFee: 200, instantClaimFee: 1190)

        // A lower claim fee doesn't offset the higher network fee that leaves savings.
        XCTAssertEqual(quote(networkFee: 400, instantClaimFee: 893).increase(over: approved, speed: .instant), 200)
        // A higher claim fee leaves less for spending.
        XCTAssertEqual(quote(networkFee: 200, instantClaimFee: 1290).increase(over: approved, speed: .instant), 100)
        // A lower network fee doesn't offset a higher claim fee that leaves less for spending.
        XCTAssertEqual(quote(networkFee: 150, instantClaimFee: 1240).increase(over: approved, speed: .instant), 50)
        XCTAssertEqual(quote(networkFee: 150, instantClaimFee: 1190).increase(over: approved, speed: .instant), 0)
        XCTAssertEqual(approved.increase(over: approved, speed: .instant), 0)
    }

    func testHardwareTransferBelowTheClaimFeeNamesTheMinimum() {
        let quote = SparkTransferQuote(
            address: "bcrt1q-spark", satsPerVbyte: 20, networkFeeSats: 300, depositSats: 1000,
            claimFees: SparkClaimFees(instantMaxSats: 2178, laterSats: 1980)
        )

        XCTAssertFalse(quote.coversClaimFee)
        XCTAssertTrue(quote.belowClaimFeeMessage.contains(CurrencyFormatter.formatSats(2179)))
    }

    func testSendMustFitTheQuotedFee() {
        XCTAssertTrue(SparkManager.fitsBalance(amountSats: 9000, feeSats: 572, balanceSats: 9572))
        XCTAssertFalse(SparkManager.fitsBalance(amountSats: 9001, feeSats: 572, balanceSats: 9572))
        XCTAssertFalse(SparkManager.fitsBalance(amountSats: UInt64.max, feeSats: 1, balanceSats: UInt64.max))
    }

    func testChainFundingNeedsSparkToReadBitkitsChain() {
        XCTAssertTrue(SparkManager.readsBitkitChain(network: .bitcoin, chainServiceUrl: nil))
        XCTAssertFalse(SparkManager.readsBitkitChain(network: .regtest, chainServiceUrl: nil), "Spark's regtest never sees the deposit")
        XCTAssertTrue(SparkManager.readsBitkitChain(network: .regtest, chainServiceUrl: "http://127.0.0.1:3002"))
    }

    func testASendSparkFailedWhileTheAppWasClosedIsReleasedAtTheNextSync() {
        let payments = [
            lightningPayment(type: .send, status: .failed, hash: "failed"),
            lightningPayment(type: .send, status: .failed, hash: "retried"),
            lightningPayment(type: .send, status: .pending, hash: "retried"),
            lightningPayment(type: .receive, status: .failed, hash: "received"),
            lightningPayment(type: .send, status: .completed, hash: "paid"),
        ]

        XCTAssertEqual(SparkManager.failedSendHashes(payments), ["failed"])
    }

    private func lightningPayment(type: PaymentType, status: BreezSdkSpark.PaymentStatus, hash: String = "hash") -> Payment {
        Payment(
            id: "id",
            paymentType: type,
            status: status,
            amount: 1000,
            fees: 2,
            timestamp: 1,
            method: .lightning,
            details: .lightning(
                description: nil,
                invoice: "lnbcrt1",
                destinationPubkey: "pubkey",
                htlcDetails: SparkHtlcDetails(paymentHash: hash, preimage: "preimage", expiryTime: 0, status: .preimageShared),
                lnurlPayInfo: nil,
                lnurlWithdrawInfo: nil,
                lnurlReceiveMetadata: nil,
                conversionInfo: nil
            ),
            conversionDetails: nil
        )
    }
}

private actor FeeQuotes {
    private var fees: [UInt64]

    init(_ fees: [UInt64]) {
        self.fees = fees
    }

    func next() -> UInt64 {
        fees.count > 1 ? fees.removeFirst() : fees[0]
    }
}
