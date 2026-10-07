@testable import Bitkit
import BitkitCore
import Combine
import Paykit
import XCTest

private enum PaykitPaymentStateBackupTestError: Error {
    case restoreFailed
}

final class PaykitPaymentStateBackupTests: XCTestCase {
    private let identity = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    private struct LegacyState: Codable {
        let subscriptionsByIdentity: [String: LegacySubscriptionState]
    }

    private struct LegacySubscriptionState: Codable {
        let acceptedAt: [PaykitSubscription.ID: Date]
        let presentedProposalIds: Set<PaykitSubscription.ID>
        let dismissedPaymentIds: Set<PaykitPaymentRequest.ID>
    }

    override func tearDownWithError() throws {
        try Keychain.delete(key: .paykitSubscriptionState)
        try Keychain.delete(key: .paykitPendingPaymentProofs)
        try Keychain.delete(key: .paykitPendingBackupRestore)
        try Keychain.delete(key: .paykitAcceptedPaymentRequests)
        try Keychain.delete(key: .paykitUsdtPayments)
    }

    func testWalletEnvelopePreservesCoreRecoveryData() throws {
        let fixture = #"{"version":1,"createdAt":1,"transfers":[],"usdtWallet":"{\"identity\":\"42161:wallet\",\"transfers\":[]}"}"#
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: Data(fixture.utf8))
        XCTAssertEqual(decoded.usdtWallet, #"{"identity":"42161:wallet","transfers":[]}"#)
        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONDecoder().decode(WalletBackupV1.self, from: encoded).usdtWallet, decoded.usdtWallet)
        let withoutUsdt = #"{"version":1,"createdAt":1,"transfers":[]}"#
        XCTAssertNil(try JSONDecoder().decode(WalletBackupV1.self, from: Data(withoutUsdt.utf8)).usdtWallet)
    }

    @MainActor
    func testRestoredUsdtAttemptsProtectPendingPaymentsAndOnlySatisfiedReceiptsCount() throws {
        let counterparty = "pubky" + String(repeating: "y", count: 52)
        let ids = (0 ..< 4).map { PaykitPaymentRequest.ID(paymentRequestId: "request-\($0)", counterparty: counterparty) }
        let proof = PaykitUsdtPaymentService.Proof(UsdtPaymentProof(chainId: "42161", transactionHash: "transaction",
                                                                    receiptLogIndex: "0", signature: "signature"))
        let attempts = ids.enumerated().map { index, id in
            PaykitUsdtPaymentService.Attempt(quoteId: "quote-\(index)", wallet: "wallet", identity: identity, contact: counterparty,
                                             requestId: id, binding: nil, billingPeriod: nil, proof: index == 2 ? proof : nil,
                                             proofQueued: false, paymentStarted: index == 1)
        }
        let receipts = ids.enumerated().map { index, id in
            PaykitUsdtPaymentService.Receipt(wallet: "wallet", identity: identity, requestId: id, paymentId: "payment-\(index)",
                                             proofEventId: "proof-\(index)", verified: index != 1, transferId: "transfer-\(index)",
                                             amount: PaykitAmount(asset: .usdt, atomic: 5_000_000), receivedAt: Date(),
                                             underpaid: index == 2, afterExpiry: index == 3)
        }
        let service = PaykitUsdtPaymentService()
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: attempts.map(PaykitUsdtStateBackup.Attempt.init),
                                                        receipts: receipts.map(PaykitUsdtStateBackup.Receipt.init)))
        let protection = try service.paymentProtection(identity: identity)
        XCTAssertEqual(protection.inFlight, [ids[1], ids[2]])
        XCTAssertEqual(protection.completed, [ids[2]: .usdt])
        XCTAssertEqual(receipts.filter(\.satisfied).map(\.requestId), [ids[0]])
        XCTAssertTrue(try service.satisfiedProofs(identity: identity).isEmpty, "Restored receipts require the active wallet before use")
        XCTAssertTrue(try service.paymentProtection(identity: counterparty).inFlight.isEmpty)
        XCTAssertTrue(try service.satisfiedProofs(identity: counterparty).isEmpty)
    }

    func testWalletBackupWritesWaitForEarlierUploadAndRecoverAfterFailure() async throws {
        let writer = WalletBackupWriter()
        let entered = expectation(description: "upload started")
        let gate = AsyncStream<Void>.makeStream()
        let events = BackupWriteEvents()
        let first = Task {
            try await writer.write {
                entered.fulfill()
                for await _ in gate.stream {
                    break
                }
                await events.append(1)
                throw PaykitPaymentStateBackupTestError.restoreFailed
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await writer.write { await events.append(2) } }
        gate.continuation.yield(())
        gate.continuation.finish()
        do { try await first.value; XCTFail("Upload should fail") } catch {}
        try await second.value
        let recorded = await events.values
        XCTAssertEqual(recorded, [1, 2])
    }

    func testPaymentStateBackupRoundTrip() async throws {
        let id = PaykitSubscription.ID(paymentRequestId: "subscription", counterparty: identity)
        let period = try XCTUnwrap(PaykitBillingPeriod(sdkPeriod: BillingPeriod(
            startsAt: "2026-09-24T10:00:00.100Z", endsAt: "2026-09-25T10:00:00.100Z"
        )))
        let startedAt = period.startsAt
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: id.paymentRequestId,
            counterparty: id.counterparty,
            billingPeriodStartsAt: startedAt
        )
        let subscriptions = PaykitSubscriptionState(
            acceptedAt: [id: PaykitPreciseInstant(date: startedAt)],
            presentedProposalIds: [id]
        )
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: requestId,
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: "bitcoin-onchain",
            kind: .onchain,
            billingPeriod: period,
            paymentStarted: true,
            paymentIdentifier: "transaction-id",
            proofData: "transaction-id",
            conversionQuoteId: "quote",
            onchainAddress: "test-address",
            onchainAmountSats: 1000,
            onchainWalletId: "trezor:android",
            onchainMatchingTransactionIdsBeforeAttempt: ["previous-transaction"]
        )
        let acceptedId = PaykitPaymentRequest.ID(paymentRequestId: "one-time", counterparty: identity)
        let acceptanceStore = PaykitPaymentRequestIdStore(key: .paykitAcceptedPaymentRequests)
        try acceptanceStore.save([acceptedId], identity: identity)
        let backup = try PaykitPaymentStateBackup(
            subscriptions: [identity: .init(subscriptions)],
            pendingProofs: [.init(proof)],
            acceptedOneTimeRequests: acceptanceStore.backupSnapshot()
        )
        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: data)
        XCTAssertEqual(decoded.pendingProofs.first?.requestId.billingPeriodStartsAt, "2026-09-24T10:00:00.100Z")
        try PaykitSubscriptionStateStore().restoreBackup(decoded.subscriptions)
        try await PaykitPaymentProofService.shared.restoreBackup(decoded.pendingProofs)
        try Keychain.delete(key: .paykitAcceptedPaymentRequests)
        try Keychain.delete(key: .paykitUsdtPayments)
        try acceptanceStore.restoreBackup(XCTUnwrap(decoded.acceptedOneTimeRequests))
        XCTAssertEqual(try acceptanceStore.load(identity: identity), [acceptedId])

        XCTAssertEqual(try PaykitSubscriptionStateStore().load(identity: identity), subscriptions)
        let loaded = try await PaykitPaymentProofStore().load()
        XCTAssertEqual(loaded, [proof])
        let restoredBackup = try await PaykitPaymentProofService.shared.backupSnapshot()
        XCTAssertEqual(restoredBackup.first?.onchainWalletId, "trezor:android")
    }

    func testUsdtBackupPreservesSharedWireFormat() throws {
        let fixture = """
        {
          "attempts": [
            {
              "quoteId": "operation",
              "wallet": "wallet",
              "identity": "alice",
              "contact": "bob",
              "requestId": {
                "paymentRequestId": "request",
                "counterparty": "bob",
                "billingPeriodStartsAt": "2026-10-01T00:00:00.125Z"
              },
              "binding": {
                "payer": "alice",
                "payee": "bob",
                "paymentAppId": "bitkit",
                "paymentRequestId": "request",
                "paymentReference": "invoice",
                "paymentEndpointIdentifier": "usdt-arbitrum-address",
                "periodStartsAt": "2026-10-01T00:00:00.125Z",
                "periodEndsAt": "2026-11-01T00:00:00.125Z",
                "conversionQuoteId": "quote"
              },
              "billingPeriod": {
                "startsAt": "2026-10-01T00:00:00.125Z",
                "endsAt": "2026-11-01T00:00:00.125Z"
              },
              "proof": null,
              "proofQueued": false,
              "paymentStarted": true
            }
          ],
          "receipts": [
            {
              "wallet": "wallet",
              "identity": "alice",
              "requestId": {
                "paymentRequestId": "request",
                "counterparty": "bob",
                "billingPeriodStartsAt": "2026-10-01T00:00:00.125Z"
              },
              "paymentId": "42161:transaction:2",
              "proofEventId": "proof",
              "verified": true,
              "transferId": "transfer",
              "amountAtomic": 50000,
              "receivedAtMillis": 1790812801000,
              "underpaid": false,
              "afterExpiry": false
            }
          ]
        }
        """
        let backup = try JSONDecoder().decode(PaykitUsdtStateBackup.self, from: Data(fixture.utf8))
        let attempt = try XCTUnwrap(backup.attempts.first).restored()
        let receipt = try XCTUnwrap(backup.receipts.first).restored()
        XCTAssertTrue(attempt.paymentStarted)
        XCTAssertEqual(attempt.binding?.paymentAppId, "bitkit")
        XCTAssertEqual(attempt.binding?.conversionQuoteId, "quote")
        XCTAssertEqual(attempt.billingPeriod?.sdkValue.startsAt, "2026-10-01T00:00:00.125Z")
        XCTAssertEqual(receipt.amount.atomic, 50000)
        XCTAssertEqual(receipt.requestId, attempt.requestId)
        let encoded = try JSONEncoder().encode(PaykitUsdtStateBackup(attempts: [.init(attempt)], receipts: [.init(receipt)]))
        let restored = try JSONDecoder().decode(PaykitUsdtStateBackup.self, from: encoded)
        XCTAssertEqual(try restored.attempts.first?.restored(), attempt)
        XCTAssertEqual(try restored.receipts.first?.restored(), receipt)
    }

    @MainActor
    func testUsdtRestorePreservesStartedPaymentsWhenSnapshotsOverlap() throws {
        let service = PaykitUsdtPaymentService()
        let started = PaykitUsdtPaymentService.Attempt(quoteId: "operation", wallet: "wallet", identity: "alice", contact: "bob",
                                                       requestId: nil, binding: nil, billingPeriod: nil, proofQueued: true,
                                                       paymentStarted: true)
        var unstarted = started
        unstarted.paymentStarted = false
        let older = PaykitUsdtStateBackup(attempts: [.init(unstarted)], receipts: [])
        try service.restoreBackup(older)
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(started)], receipts: []))
        try service.restoreBackup(older)
        let restored = try XCTUnwrap(service.backupSnapshot().attempts.first).restored()
        XCTAssertTrue(restored.paymentStarted)
        XCTAssertFalse(restored.proofQueued)
    }

    func testUnreadablePaymentStateIsPreserved() async throws {
        let data = Data("not-json".utf8)
        try Keychain.upsert(key: .paykitSubscriptionState, data: data)
        try Keychain.upsert(key: .paykitPendingPaymentProofs, data: data)

        XCTAssertThrowsError(try PaykitSubscriptionStateStore().backupSnapshot())
        XCTAssertThrowsError(try PaykitSubscriptionStateStore().save(PaykitSubscriptionState(), identity: identity))
        do {
            _ = try await PaykitPaymentProofStore().load()
            XCTFail("Unreadable proof state must fail")
        } catch is Swift.DecodingError {}
        XCTAssertEqual(try Keychain.load(key: .paykitSubscriptionState), data)
        XCTAssertEqual(try Keychain.load(key: .paykitPendingPaymentProofs), data)
    }

    func testSubscriptionChangesNotifyBackup() throws {
        var changes = 0
        let observation = PaykitSubscriptionStateStore.walletBackupDataChangedPublisher.sink { changes += 1 }
        defer { observation.cancel() }
        try PaykitSubscriptionStateStore().save(PaykitSubscriptionState(), identity: identity)
        XCTAssertEqual(changes, 1)
    }

    func testPendingWalletRestoreMarkerIsDetectedBeforeAndAfterPayloadDownload() throws {
        try Keychain.delete(key: .paykitPendingBackupRestore)
        XCTAssertFalse(BackupService.shared.hasPendingWalletRestore())

        try Keychain.upsert(key: .paykitPendingBackupRestore, data: Data())
        XCTAssertTrue(BackupService.shared.hasPendingWalletRestore())

        try Keychain.upsert(key: .paykitPendingBackupRestore, data: Data("wallet-backup".utf8))
        XCTAssertTrue(BackupService.shared.hasPendingWalletRestore())
    }

    func testWalletBackupRestoreGateBlocksStartUntilRestoreCompletion() {
        XCTAssertTrue(WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: true,
            hasPendingRestore: false,
            isRestoreCompletionStart: false
        ))
        XCTAssertFalse(WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: true,
            hasPendingRestore: false,
            isRestoreCompletionStart: true
        ))
        XCTAssertTrue(WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: true,
            hasPendingRestore: true,
            isRestoreCompletionStart: true
        ))
    }

    func testWalletBackupRestoreGateRetainsFailuresAndReplaysPayloadUntilCompletion() async throws {
        var storedPayload: Data?
        let gate = WalletBackupRestoreGate(
            load: { storedPayload },
            store: { storedPayload = $0 },
            clear: { storedPayload = nil }
        )
        let walletBackup = Data("wallet-backup".utf8)
        var downloadCount = 0

        do {
            _ = try await gate.performRestore { retainedPayload in
                XCTAssertNil(retainedPayload)
                downloadCount += 1
                throw PaykitPaymentStateBackupTestError.restoreFailed
            }
            XCTFail("Expected the download failure to preserve the placeholder")
        } catch PaykitPaymentStateBackupTestError.restoreFailed {}
        XCTAssertEqual(storedPayload, Data())
        XCTAssertThrowsError(try gate.requireReplacementBackupAllowed())

        do {
            _ = try await gate.performRestore { retainedPayload in
                XCTAssertNil(retainedPayload)
                downloadCount += 1
                try gate.retain(walletBackup)
                throw PaykitPaymentStateBackupTestError.restoreFailed
            }
            XCTFail("Expected the apply failure to preserve the downloaded payload")
        } catch PaykitPaymentStateBackupTestError.restoreFailed {}
        XCTAssertEqual(storedPayload, walletBackup)
        XCTAssertThrowsError(try gate.requireReplacementBackupAllowed())

        let didRestore = try await gate.performRestore { retainedPayload in
            XCTAssertEqual(retainedPayload, walletBackup)
            XCTAssertEqual(downloadCount, 2)
            return true
        }

        XCTAssertTrue(didRestore)
        XCTAssertNil(storedPayload)
        XCTAssertNoThrow(try gate.requireReplacementBackupAllowed())
    }

    func testWalletBackupRestoreGateClearsPlaceholderWhenNoWalletPayloadExists() async throws {
        var storedPayload: Data?
        let gate = WalletBackupRestoreGate(
            load: { storedPayload },
            store: { storedPayload = $0 },
            clear: { storedPayload = nil }
        )

        let didRestore = try await gate.performRestore { retainedPayload in
            XCTAssertNil(retainedPayload)
            XCTAssertEqual(storedPayload, Data())
            return false
        }

        XCTAssertFalse(didRestore)
        XCTAssertNil(storedPayload)
        XCTAssertNoThrow(try gate.requireReplacementBackupAllowed())
    }

    func testOnlyWalletRestoreFailuresAreFatal() {
        XCTAssertTrue(BackupRestoreFailurePolicy.isFatal(.wallet))

        for category in BackupCategory.allCases where category != .wallet {
            XCTAssertFalse(BackupRestoreFailurePolicy.isFatal(category))
        }
    }

    func testAndroidPaymentStatePreservesPreciseAcceptanceBillingBoundaries() throws {
        let data = Data("""
        {
          "subscriptions": {
            "\(identity)": {
              "acceptances": [
                {"id":{"paymentRequestId":"millisecond","counterparty":"bob"},"acceptedAt":"2026-09-24T10:00:00.123Z"},
                {"id":{"paymentRequestId":"nanosecond","counterparty":"bob"},"acceptedAt":"2026-09-24T10:00:00.123456789Z"}
              ],
              "presentedProposalIds": []
            }
          },
          "pendingProofs": [{
            "identity": "\(identity)",
            "requestId": {"paymentRequestId":"request","counterparty":"bob","billingPeriodStartsAt":"2026-09-24T10:00:00.100Z"},
            "paymentAppId": "bitkit",
            "paymentEndpointIdentifier": "bitcoin-onchain",
            "kind": "bitcoin-onchain-txid",
            "paymentStarted": true,
            "billingPeriod": {"startsAt":"2026-09-24T10:00:00.100Z","endsAt":"2026-09-25T10:00:00.100Z"},
            "onchainWalletId": "trezor:android",
            "onchainMatchingTransactionIdsBeforeAttempt": []
          }]
        }
        """.utf8)
        let backup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: data)
        let store = PaykitSubscriptionStateStore()
        try store.restoreBackup(backup.subscriptions)
        let persistedBackup = try PaykitPaymentStateBackup(
            subscriptions: store.backupSnapshot(),
            pendingProofs: backup.pendingProofs
        )
        let roundTrippedBackup = try JSONDecoder().decode(
            PaykitPaymentStateBackup.self,
            from: JSONEncoder().encode(persistedBackup)
        )
        try store.restoreBackup(roundTrippedBackup.subscriptions)

        let restoredAcceptedAt = try store.load(identity: identity).acceptedAt
        let millisecondId = PaykitSubscription.ID(
            paymentRequestId: "millisecond",
            counterparty: "bob"
        )
        let nanosecondId = PaykitSubscription.ID(
            paymentRequestId: "nanosecond",
            counterparty: "bob"
        )
        XCTAssertEqual(restoredAcceptedAt[millisecondId]?.timestamp, "2026-09-24T10:00:00.123Z")
        XCTAssertEqual(restoredAcceptedAt[nanosecondId]?.timestamp, "2026-09-24T10:00:00.123456789Z")

        let through = try XCTUnwrap(PaykitPreciseInstant(timestamp: "2026-09-24T10:00:01Z")?.date)
        let boundaryCases: [(PaykitSubscription.ID, String, Int)] = [
            (millisecondId, "122999950", 1),
            (millisecondId, "123", 1),
            (millisecondId, "123000050", 2),
            (nanosecondId, "123456788", 1),
            (nanosecondId, "123456789", 1),
            (nanosecondId, "123456790", 2),
        ]
        for (id, boundaryFraction, expectedCount) in boundaryCases {
            let recurrence = try XCTUnwrap(PaykitSubscriptionRecurrence(PaymentRequestRecurrence(
                every: 1,
                unit: "day",
                startsAt: "2026-09-23T10:00:00.\(boundaryFraction)Z",
                anchor: "2026-09-23T10:00:00.\(boundaryFraction)Z",
                endsAt: nil
            )))
            let acceptedAt = try XCTUnwrap(restoredAcceptedAt[id])
            XCTAssertEqual(
                recurrence.periods(through: through, acceptedAt: acceptedAt).count,
                expectedCount,
                "Unexpected billing eligibility for \(id.paymentRequestId) at .\(boundaryFraction)Z"
            )
        }

        let proof = try XCTUnwrap(backup.pendingProofs.first).restored()
        XCTAssertTrue(proof.paymentStarted)
        XCTAssertEqual(proof.requestId.billingPeriodStartsAt, proof.billingPeriod?.startsAt)
        XCTAssertEqual(proof.onchainWalletId, "trezor:android")
        XCTAssertEqual(PaykitPaymentStateBackup.Proof(proof).onchainWalletId, "trezor:android")

        let millisecondData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: ".123Z", with: ".100Z").utf8)
        let millisecondBackup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: millisecondData)
        XCTAssertEqual(try millisecondBackup.subscriptions[identity]?.restored().acceptedAt.count, 2)

        let malformedData = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "2026-09-24T10:00:00.123Z", with: "not-a-timestamp").utf8)
        let malformedBackup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: malformedData)
        XCTAssertThrowsError(try malformedBackup.subscriptions[identity]?.restored())
    }

    func testLegacyStoredAcceptanceDateDecodesAndMigratesToPreciseTimestamp() throws {
        let id = PaykitSubscription.ID(
            paymentRequestId: "subscription",
            counterparty: identity
        )
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        let legacyState = LegacyState(subscriptionsByIdentity: [
            identity: LegacySubscriptionState(
                acceptedAt: [id: acceptedAt],
                presentedProposalIds: [id],
                dismissedPaymentIds: []
            ),
        ])
        try Keychain.upsert(key: .paykitSubscriptionState, data: JSONEncoder().encode(legacyState))

        let store = PaykitSubscriptionStateStore()
        let restored = try store.load(identity: identity)
        XCTAssertEqual(restored.acceptedAt[id]?.timestamp, "2026-09-24T10:00:00Z")

        try store.save(restored, identity: identity)
        let migratedData = try XCTUnwrap(Keychain.load(key: .paykitSubscriptionState))
        XCTAssertTrue(String(decoding: migratedData, as: UTF8.self).contains("2026-09-24T10:00:00Z"))
    }
}

private actor BackupWriteEvents {
    private(set) var values: [Int] = []
    func append(_ value: Int) {
        values.append(value)
    }
}
