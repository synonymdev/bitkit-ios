@testable import Bitkit
import Combine
import Paykit
import XCTest

final class PaykitPaymentStateBackupTests: XCTestCase {
    private let identity = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    override func tearDownWithError() throws {
        try Keychain.delete(key: .paykitSubscriptionState)
        try Keychain.delete(key: .paykitPendingPaymentProofs)
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
        let subscriptions = PaykitSubscriptionState(acceptedAt: [id: startedAt], presentedProposalIds: [id])
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
        let restoredProofs = try decoded.pendingProofs.map { try $0.restored() }
        try await PaykitPaymentProofStore().save(restoredProofs)

        XCTAssertEqual(try PaykitSubscriptionStateStore().load(identity: identity), subscriptions)
        let loaded = try await PaykitPaymentProofStore().load()
        XCTAssertEqual(loaded, [proof])
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

    func testDecodeAndroidPaymentState() throws {
        let data = Data(#"""
        {"subscriptions":{"alice":{"acceptances":[{"id":{"paymentRequestId":"request","counterparty":"bob","counterpartyReceiverPath":"bitkit/server"},"acceptedAt":"2026-09-24T10:00:00.125Z"}],"presentedProposalIds":[]}},"pendingProofs":[{"identity":"alice","requestId":{"paymentRequestId":"request","counterparty":"bob","counterpartyReceiverPath":"bitkit/server","billingPeriodStartsAt":"2026-09-24T10:00:00.100Z"},"paymentEndpointIdentifier":"bitcoin-onchain","kind":"bitcoin-onchain-txid","paymentStarted":true,"billingPeriod":{"startsAt":"2026-09-24T10:00:00.100Z","endsAt":"2026-09-25T10:00:00.100Z"},"onchainMatchingTransactionIdsBeforeAttempt":[]}]}
        """#.utf8)
        let backup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: data)
        XCTAssertEqual(try backup.subscriptions["alice"]?.restored().acceptedAt.count, 1)
        let proof = try XCTUnwrap(backup.pendingProofs.first).restored()
        XCTAssertTrue(proof.paymentStarted)
        XCTAssertEqual(proof.requestId.billingPeriodStartsAt, proof.billingPeriod?.startsAt)
        let imprecise = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: ".125Z", with: ".100Z").utf8)
        let impreciseBackup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: imprecise)
        XCTAssertThrowsError(try impreciseBackup.subscriptions["alice"]?.restored())
    }
}
