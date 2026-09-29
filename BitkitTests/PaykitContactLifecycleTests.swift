@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class PaykitContactLifecycleTests: XCTestCase {
    func testDeletionBlocksEveryKnownReceiverBeforeRemovingContact() async throws {
        for failWithdrawal in [false, true] {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            sdk.failWithdrawal = failWithdrawal
            let service = PaykitSdkService(sdkFactory: { sdk })
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            XCTAssertNil(sdk.record)
            XCTAssertEqual(sdk.events, ["clear:bitkit/wallet", "clear:bitkit/server", "block:bitkit/server", "block:bitkit/wallet", "remove"])
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
        }
    }

    func testActiveSubscriptionPreventsDeletionUntilItEnds() async throws {
        let fixedEndTimestamp = "2100-02-01T00:00:00Z"
        let cases: [(role: PaymentRequestLocalRole, endsAt: String?)] = [
            (.payer, nil),
            (.payer, fixedEndTimestamp),
            (.payee, nil),
        ]
        for testCase in cases {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            let terms = try PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: "btc"),
                paymentReference: PaymentReference(text: "subscription"), proposalExpiresAt: nil,
                recurrence: PaymentRequestRecurrence(every: 1, unit: "month", startsAt: "2026-01-01T00:00:00Z",
                                                     anchor: "2026-01-01T00:00:00Z", endsAt: testCase.endsAt),
                acceptedPaymentEndpointIdentifiers: ["lightning:bolt11"], metadata: PrivateJsonObject(text: "{}")
            )
            sdk.requests = [PaymentRequestRecord(
                counterparty: sdk.publicKey, counterpartyReceiverPath: PaykitReceiverPath.server,
                paymentRequestId: "550e8400-e29b-41d4-a716-446655440000", localRole: testCase.role, state: .activeRecurring,
                proposalStreamItemId: nil, proposalOutboundMessageId: nil, proposalOutboundStatus: nil,
                proposalEventId: nil, terms: terms, acceptedEventId: nil, acceptedOutboundStatus: nil,
                rejectedEventId: nil, rejectedOutboundStatus: nil, canceledEventId: nil, canceledOutboundStatus: nil,
                paymentProofs: [], lastStreamItemId: nil, lastOutboundMessageId: nil, lastOutboundStatus: nil,
                lastEventAt: nil, invalidReason: nil
            )]
            let service = PaykitSdkService(sdkFactory: { sdk })
            do {
                _ = try await service.removeContact(publicKey: sdk.publicKey)
                XCTFail("Expected active subscription to prevent deletion")
            } catch let PubkyServiceError.activeSubscription(endsAt) {
                XCTAssertEqual(endsAt, testCase.endsAt.flatMap(PaykitPaymentRequest.parseDate))
            }
            XCTAssertNotNil(sdk.record)
            XCTAssertTrue(sdk.events.isEmpty)
            if testCase.endsAt != nil {
                sdk.requests[0].terms?.recurrence?.endsAt = "2000-02-01T00:00:00Z"
            } else {
                sdk.requests[0].state = .canceled
            }
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            XCTAssertNil(sdk.record)
        }
    }

    func testFailedBlockKeepsContactAvailableForDeletionRetry() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.failBlock = true
        let service = PaykitSdkService(sdkFactory: { sdk })
        do {
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            XCTFail("Expected the failed block to prevent deletion")
        } catch {}
        XCTAssertNotNil(sdk.record)
        XCTAssertFalse(sdk.events.contains("remove"))
    }

    func testOnlyExplicitReaddRestoresAllPrivateConnections() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.removeContact(publicKey: sdk.publicKey)
        do {
            _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Updated")
            XCTFail("Background refresh must not recreate a deleted contact")
        } catch {}
        XCTAssertNil(sdk.record)
        XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
        _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Readded", restorePrivateConnection: true)
        XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .notLinked })
        XCTAssertEqual(sdk.record?.label, "Readded")
    }

    func testFailedPrivateConnectionRestoreCanBeRetriedWithoutASavedContact() async throws {
        let failures: [(peerLookup: Bool, unblockPath: String?, saveContact: Bool)] = [
            (true, nil, false),
            (false, PaykitReceiverPath.server, false),
            (false, nil, true),
        ]
        for failure in failures {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            let service = PaykitSdkService(sdkFactory: { sdk })
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            sdk.failLinkedPeers = failure.peerLookup
            sdk.failUnblockPath = failure.unblockPath
            sdk.failSaveContact = failure.saveContact
            do {
                _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Contact", restorePrivateConnection: true)
                XCTFail("Expected restoration to fail")
            } catch {}
            XCTAssertNil(sdk.record)
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
            sdk.failLinkedPeers = false
            sdk.failUnblockPath = nil
            sdk.failSaveContact = false
            _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Contact", restorePrivateConnection: true)
            XCTAssertNotNil(sdk.record)
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .notLinked })
        }
    }

    func testBlockedPeerCleanupDoesNotAttemptNetworkDelivery() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.removeContact(publicKey: sdk.publicKey)
        let report = try await service.clearPrivatePaymentList(to: sdk.publicKey, receiverPath: PaykitReceiverPath.server)
        XCTAssertNil(report)
    }
}

private final class ContactLifecycleSdk: PaykitSdk, @unchecked Sendable {
    let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    var events: [String] = []
    var requests: [PaymentRequestRecord] = []
    var failWithdrawal = false
    var failBlock = false
    var failLinkedPeers = false
    var failUnblockPath: String?
    var failSaveContact = false
    lazy var record: ContactRecord? = ContactRecord(
        publicKey: publicKey, receiverPaths: [PaykitReceiverPath.wallet], label: "Contact", profile: nil,
        profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
        publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
        publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
    )
    lazy var peers: [LinkedPeerRecord] = [PaykitReceiverPath.wallet, PaykitReceiverPath.server].map {
        LinkedPeerRecord(counterparty: publicKey, counterpartyReceiverPath: $0, state: .linked,
                         lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
                         localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
                         remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil)
    }

    override func backupStateRevision() async throws -> String {
        "revision"
    }

    override func paymentRequests() async throws -> [PaymentRequestRecord] {
        requests
    }

    override func contactRecord(publicKey: String) async throws -> ContactRecord? {
        record
    }

    override func linkedPeers() async throws -> [LinkedPeerRecord] {
        if failLinkedPeers { throw PubkyServiceError.profileNotFound }
        return peers
    }

    override func clearPrivatePaymentListAndProcessOutbound(
        counterparty: String,
        counterpartyReceiverPath: String
    ) async throws -> PrivatePaymentListDeliveryReport {
        events.append("clear:\(counterpartyReceiverPath)")
        if failWithdrawal { throw PubkyServiceError.sessionNotActive }
        return PrivatePaymentListDeliveryReport(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
    }

    override func blockPeer(counterparty: String, counterpartyReceiverPath: String) async throws -> LinkedPeerRecord {
        if failBlock { throw PubkyServiceError.profileNotFound }
        events.append("block:\(counterpartyReceiverPath)")
        let index = try XCTUnwrap(peers.firstIndex { $0.counterpartyReceiverPath == counterpartyReceiverPath })
        peers[index].state = .blocked
        return peers[index]
    }

    override func unblockPeer(counterparty: String, counterpartyReceiverPath: String) async throws -> LinkedPeerRecord {
        if failUnblockPath == counterpartyReceiverPath { throw PubkyServiceError.profileNotFound }
        let index = try XCTUnwrap(peers.firstIndex { $0.counterpartyReceiverPath == counterpartyReceiverPath })
        peers[index].state = .notLinked
        return peers[index]
    }

    override func removeContact(publicKey: String) async throws -> ContactRecord? {
        events.append("remove")
        defer { record = nil }
        return record
    }

    override func saveContact(update: ContactUpdate) async throws -> ContactRecord {
        if failSaveContact {
            throw PubkyServiceError.profileNotFound
        }
        let saved = ContactRecord(
            publicKey: update.publicKey, receiverPaths: update.receiverPaths, label: update.label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
        record = saved
        return saved
    }
}
