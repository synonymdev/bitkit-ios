@testable import Bitkit
import Combine
import Paykit
import XCTest

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
    }

    func testPaymentStateBackupRoundTrip() async throws {
        let id = PaykitSubscription.ID(paymentRequestId: "subscription", counterparty: identity, counterpartyReceiverPath: "bitkit/server")
        let period = try XCTUnwrap(PaykitBillingPeriod(sdkPeriod: BillingPeriod(
            startsAt: "2026-09-24T10:00:00.100Z", endsAt: "2026-09-25T10:00:00.100Z"
        )))
        let startedAt = period.startsAt
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: id.paymentRequestId,
            counterparty: id.counterparty,
            counterpartyReceiverPath: id.counterpartyReceiverPath,
            billingPeriodStartsAt: startedAt
        )
        let subscriptions = PaykitSubscriptionState(
            acceptedAt: [id: PaykitPreciseInstant(date: startedAt)],
            presentedProposalIds: [id]
        )
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: requestId,
            paymentEndpointIdentifier: "bitcoin-onchain",
            kind: .onchain,
            billingPeriod: period,
            paymentStarted: true,
            paymentIdentifier: "transaction-id",
            proofData: "transaction-id",
            onchainAddress: "test-address",
            onchainAmountSats: 1000,
            onchainWalletId: "trezor:android",
            onchainMatchingTransactionIdsBeforeAttempt: ["previous-transaction"]
        )
        let backup = PaykitPaymentStateBackup(
            subscriptions: [identity: .init(subscriptions)],
            pendingProofs: [.init(proof)]
        )
        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: data)
        XCTAssertEqual(decoded.pendingProofs.first?.requestId.billingPeriodStartsAt, "2026-09-24T10:00:00.100Z")
        try PaykitSubscriptionStateStore().restoreBackup(decoded.subscriptions)
        try await PaykitPaymentProofService.shared.restoreBackup(decoded.pendingProofs)

        XCTAssertEqual(try PaykitSubscriptionStateStore().load(identity: identity), subscriptions)
        let loaded = try await PaykitPaymentProofStore().load()
        XCTAssertEqual(loaded, [proof])
        let restoredBackup = try await PaykitPaymentProofService.shared.backupSnapshot()
        XCTAssertEqual(restoredBackup.first?.onchainWalletId, "trezor:android")
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
        } catch is DecodingError {}
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

    func testOnlyWalletRestoreFailuresAreFatal() {
        XCTAssertTrue(BackupRestoreFailurePolicy.isFatal(.wallet))

        for category in BackupCategory.allCases where category != .wallet {
            XCTAssertFalse(BackupRestoreFailurePolicy.isFatal(category))
        }
    }

    func testAndroidPaymentStatePreservesPreciseAcceptanceBillingBoundaries() throws {
        let data = Data("""
        {"subscriptions":{"\(identity)":{"acceptances":[{"id":{"paymentRequestId":"millisecond","counterparty":"bob","counterpartyReceiverPath":"bitkit/server"},"acceptedAt":"2026-09-24T10:00:00.123Z"},{"id":{"paymentRequestId":"nanosecond","counterparty":"bob","counterpartyReceiverPath":"bitkit/server"},"acceptedAt":"2026-09-24T10:00:00.123456789Z"}],"presentedProposalIds":[]}},"pendingProofs":[{"identity":"\(identity)","requestId":{"paymentRequestId":"request","counterparty":"bob","counterpartyReceiverPath":"bitkit/server","billingPeriodStartsAt":"2026-09-24T10:00:00.100Z"},"paymentEndpointIdentifier":"bitcoin-onchain","kind":"bitcoin-onchain-txid","paymentStarted":true,"billingPeriod":{"startsAt":"2026-09-24T10:00:00.100Z","endsAt":"2026-09-25T10:00:00.100Z"},"onchainWalletId":"trezor:android","onchainMatchingTransactionIdsBeforeAttempt":[]}]}
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
            counterparty: "bob",
            counterpartyReceiverPath: "bitkit/server"
        )
        let nanosecondId = PaykitSubscription.ID(
            paymentRequestId: "nanosecond",
            counterparty: "bob",
            counterpartyReceiverPath: "bitkit/server"
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
            counterparty: identity,
            counterpartyReceiverPath: "bitkit/server"
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
