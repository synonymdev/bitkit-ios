@testable import Bitkit
import XCTest

/// A savings payment of the exit's funding, marked before it goes out, while a stop may have lost its txid.
final class SparkExitSavingsSendTests: XCTestCase {
    private func started(earlierAttemptId: String? = nil, atHeight: UInt32? = nil) -> SparkExitRecord {
        var record = SparkExitFixtures.record()
        record.savingsSendStarted = .init(address: record.funding[0].address, atHeight: atHeight, earlierAttemptId: earlierAttemptId)
        return record
    }

    private func attempt(_ status: OnchainSendAttempt.Status, address: String = "bcrt1qfunding", txid: String? = "sent") -> OnchainSendAttempt {
        OnchainSendAttempt(
            id: UUID(), walletId: "wallet", requestId: nil, orderId: nil, address: address, amountSats: 9000, isMaxAmount: false,
            status: status, txid: txid
        )
    }

    /// An unsaved payment holds the ask, the cancel and the reminder until the own-payment wait forgets it.
    func testAnUnsavedSavingsPaymentHoldsTheAskUntilItsWaitEnds() {
        var record = started()
        record.savingsRefusal = SparkExitRecord.SavingsRefusal(sats: 20000, feeSats: 650)
        XCTAssertTrue(record.isSavingsSendUnsaved)
        XCTAssertTrue(record.isAwaitingOwnPayment)
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: []), .paid(txid: nil))
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: nil), .paid(txid: nil))
        XCTAssertFalse(SparkExitManager.canCancel(record, fundingSeenSats: 0))
        XCTAssertNil(SparkExitManager.savingsRefusal(record, fundingState: nil, hasSavingsSend: false), "offered savings again")
        let reminders = SparkExitMath.reminders(record, tip: 1000, now: Date(), network: .regtest)
        XCTAssertFalse(reminders.contains { $0.isFunding })

        let looked = record.withSavingsSendLooked(tip: 1000)
        XCTAssertEqual(looked.savingsSendStarted?.atHeight, 1000)
        XCTAssertEqual(looked.withSavingsSendLooked(tip: 1143), looked)
        let expired = looked.withSavingsSendLooked(tip: 1000 + SparkExitDriver.ownPaymentTimeoutBlocks)
        XCTAssertNil(expired.savingsSendStarted)
        guard case .ask = SparkExitMath.fundingState(expired, utxos: []) else {
            return XCTFail("the ask did not come back: \(String(describing: SparkExitMath.fundingState(expired, utxos: [])))")
        }
        XCTAssertTrue(SparkExitManager.canCancel(expired, fundingSeenSats: 0))
    }

    /// The journal keeps a payment that went out as the exit's, and forgets a started one that never did.
    func testAStartedSavingsPaymentIsKeptOrForgottenByTheJournal() throws {
        let earlier = attempt(.accepted, address: "bcrt1qelsewhere", txid: "earlier")
        let record = started(earlierAttemptId: earlier.id.uuidString)

        for status in [OnchainSendAttempt.Status.accepted, .pending, .unknown] {
            let kept = try XCTUnwrap(SparkExitManager.keepingSavingsSend(record, attempt: attempt(status)), "\(status)")
            XCTAssertEqual(kept.fundingPaymentTxid, "sent", "\(status)")
            XCTAssertNil(kept.savingsSendStarted, "\(status)")
        }
        XCTAssertNil(SparkExitManager.keepingSavingsSend(record, attempt: attempt(.pending, txid: nil)), "admitted, not sent yet")
        XCTAssertNil(SparkExitManager.keepingSavingsSend(record, attempt: nil), "an empty journal proves nothing on its own")
        XCTAssertNil(SparkExitManager.keepingSavingsSend(record, attempt: attempt(.accepted, address: "bcrt1qother")))

        let notAdmitted = try XCTUnwrap(SparkExitManager.keepingSavingsSend(record, attempt: earlier))
        XCTAssertNil(notAdmitted.savingsSendStarted)
        XCTAssertNil(notAdmitted.fundingPaymentTxid)
        let refused = try XCTUnwrap(SparkExitManager.keepingSavingsSend(record, attempt: attempt(.rejected)))
        XCTAssertNil(refused.savingsSendStarted)
        XCTAssertNil(refused.fundingPaymentTxid)
    }

    /// After a restart, a started payment the journal never sent frees the ask only once the exit's wallet owns the
    /// journal and its address shows nothing, in a block or the mempool.
    @MainActor func testAStartedPaymentTheJournalNeverSentIsForgottenOnlyOverAnUnusedAddressOfTheExitsWallet() async throws {
        let isUnusedForgotten = try await isForgotten(walletIndex: 9990, journalWallet: 9990)
        XCTAssertTrue(isUnusedForgotten)
        let isUsedForgotten = try await isForgotten(walletIndex: 9991, journalWallet: 9991, isUsed: true)
        XCTAssertFalse(isUsedForgotten, "a payment the journal no longer holds may have gone out")
        let isOtherWalletForgotten = try await isForgotten(walletIndex: 9992, journalWallet: 0)
        XCTAssertFalse(isOtherWalletForgotten, "another wallet's journal says nothing of this payment")
        let isUnreadForgotten = try await isForgotten(walletIndex: 9993, journalWallet: 9993, isUnreadable: true)
        XCTAssertFalse(isUnreadForgotten, "an unread address proves nothing")
    }

    /// Whether the exit of `walletIndex`, loaded over an empty journal of `journalWallet`, forgets its started payment.
    @MainActor private func isForgotten(
        walletIndex: Int,
        journalWallet: Int,
        isUsed: Bool = false,
        isUnreadable: Bool = false
    ) async throws -> Bool {
        let store = SparkExitStore(walletIndex: walletIndex)
        defer {
            try? store.deleteWithCopies()
            try? SparkExitEarlierAddressStore(walletIndex: walletIndex).delete()
            try? SparkExitLostLeafStore(walletIndex: walletIndex).delete()
        }
        let record = started()
        try store.save(record)
        let chain = FakeSparkExitChain()
        chain.usedAddresses = isUsed ? [record.funding[0].address] : []
        chain.isAddressReadUnreadable = isUnreadable
        let exit = SparkExitManager(
            walletIndex: walletIndex,
            chain: chain,
            attempts: OnchainSendAttemptService(store: MemoryAttemptStore()),
            currentWalletIndex: { journalWallet }
        )
        exit.load(walletIndex: walletIndex)
        await exit.keepSavingsSendLocked()
        return try exit.record?.savingsSendStarted == nil && store.load()?.savingsSendStarted == nil
    }

    /// Only a payment refused before it went out, or blocked, ends the hold at once; any other failure is settled from
    /// the journal.
    func testOnlyAPaymentThatSentNothingEndsTheHoldAtOnce() {
        XCTAssertTrue(SparkExitManager.sentNothing(OnchainSendAttemptError.preDispatch(URLError(.timedOut))))
        XCTAssertTrue(SparkExitManager.sentNothing(OnchainSendAttemptError.blocked(nil)))
        XCTAssertTrue(SparkExitManager.sentNothing(OnchainSendAttemptError.duplicate))
        XCTAssertFalse(SparkExitManager.sentNothing(OnchainSendAttemptError.outcomeNotSaved))
        XCTAssertFalse(SparkExitManager.sentNothing(URLError(.timedOut)))
    }
}
