@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class PaykitContactLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let savedSecret = try Keychain.load(key: .pubkySecretKey)
        let savedReference = AdoptedPubkyReference.current
        addTeardownBlock {
            AdoptedPubkyReference.current = savedReference
            if let savedSecret {
                try Keychain.upsert(key: .pubkySecretKey, data: savedSecret)
            } else {
                try Keychain.delete(key: .pubkySecretKey)
            }
        }
        AdoptedPubkyReference.current = nil
        try Keychain.delete(key: .pubkySecretKey)
    }

    func testDeletionBlocksPeerBeforeRemovingContact() async throws {
        for failWithdrawal in [false, true] {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            sdk.failWithdrawal = failWithdrawal
            let service = PaykitSdkService(sdkFactory: { sdk })
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            XCTAssertNil(sdk.record)
            XCTAssertEqual(sdk.events, ["clear", "block", "remove"])
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
        }
    }

    func testActiveSubscriptionPreventsDeletionUntilItEnds() async throws {
        let fixedEndTimestamp = "2100-02-01T00:00:00Z"
        let cases: [(role: PaymentRequestLocalRole, endsAt: String?, appId: String)] = [
            (.payer, nil, "bitkit"),
            (.payer, fixedEndTimestamp, "bitkit"),
            (.payee, nil, "bitkit"),
            (.payer, nil, "paykit-server"),
            (.payee, nil, "paykit-server"),
        ]
        for testCase in cases {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            let terms = try PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: "btc"),
                paymentReference: PaymentReference(text: "subscription"), proposalExpiresAt: nil,
                recurrence: PaymentRequestRecurrence(every: 1, unit: "month", startsAt: "2026-01-01T00:00:00Z",
                                                     anchor: "2026-01-01T00:00:00Z", endsAt: testCase.endsAt),
                acceptedPaymentEndpointIdentifiers: ["btc-lightning-bolt11"], paymentEndpoints: nil, requiredAppId: testCase.appId,
                conversion: nil, paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            )
            sdk.requests = [PaymentRequestRecord(
                counterparty: sdk.publicKey,
                paymentRequestId: "550e8400-e29b-41d4-a716-446655440000", localRole: testCase.role, state: .activeRecurring,
                proposalStreamItemId: nil, proposalOutboundMessageId: nil, proposalOutboundStatus: nil,
                proposalEventId: nil, proposalAppId: testCase.appId,
                payerAppId: testCase.role == .payer ? testCase.appId : nil, executionClaimAppId: nil,
                terms: terms, acceptedEventId: nil, acceptedOutboundStatus: nil,
                rejectedEventId: nil, rejectedOutboundStatus: nil, canceledEventId: nil, canceledOutboundStatus: nil,
                conversionQuotes: [],
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

    func testDeletionDateRequiresEveryActiveSubscriptionToHaveValidEnd() async throws {
        let fixedEndTimestamp = "2099-02-01T00:00:00Z"
        let laterEndTimestamp = "2100-02-01T00:00:00Z"

        func subscription(publicKey: String, endsAt: String?) throws -> PaymentRequestRecord {
            let terms = try PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: "btc"),
                paymentReference: PaymentReference(text: "subscription"), proposalExpiresAt: nil,
                recurrence: PaymentRequestRecurrence(every: 1, unit: "month", startsAt: "2026-01-01T00:00:00Z",
                                                     anchor: "2026-01-01T00:00:00Z", endsAt: endsAt),
                acceptedPaymentEndpointIdentifiers: ["btc-lightning-bolt11"], paymentEndpoints: nil, requiredAppId: "paykit-server",
                conversion: nil, paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            )
            return PaymentRequestRecord(
                counterparty: publicKey,
                paymentRequestId: UUID().uuidString, localRole: .payer, state: .activeRecurring,
                proposalStreamItemId: nil, proposalOutboundMessageId: nil, proposalOutboundStatus: nil,
                proposalEventId: nil, proposalAppId: "paykit-server", payerAppId: "paykit-server", executionClaimAppId: nil,
                terms: terms, acceptedEventId: nil, acceptedOutboundStatus: nil,
                rejectedEventId: nil, rejectedOutboundStatus: nil, canceledEventId: nil, canceledOutboundStatus: nil,
                conversionQuotes: [], paymentProofs: [], lastStreamItemId: nil, lastOutboundMessageId: nil,
                lastOutboundStatus: nil, lastEventAt: nil, invalidReason: nil
            )
        }

        let cases: [(endsAt: [String?], malformedIndex: Int?, expectedEnd: String?)] = [
            ([fixedEndTimestamp, nil], nil, nil),
            ([fixedEndTimestamp, fixedEndTimestamp], 1, nil),
            ([fixedEndTimestamp, laterEndTimestamp], nil, laterEndTimestamp),
        ]

        for testCase in cases {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            sdk.requests = try testCase.endsAt.map { try subscription(publicKey: sdk.publicKey, endsAt: $0) }
            if let malformedIndex = testCase.malformedIndex {
                sdk.requests[malformedIndex].terms?.recurrence?.endsAt = "not-a-date"
            }
            let service = PaykitSdkService(sdkFactory: { sdk })

            do {
                _ = try await service.removeContact(publicKey: sdk.publicKey)
                XCTFail("Expected active subscriptions to prevent deletion")
            } catch let PubkyServiceError.activeSubscription(endsAt) {
                XCTAssertEqual(endsAt, testCase.expectedEnd.flatMap(PaykitPaymentRequest.parseDate))
            }
            XCTAssertNotNil(sdk.record)
            XCTAssertTrue(sdk.events.isEmpty)
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

    func testOnlyExplicitReaddRestoresPrivateConnection() async throws {
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
        let failures: [(peerLookup: Bool, unblock: Bool, saveContact: Bool)] = [
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ]
        for failure in failures {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            let service = PaykitSdkService(sdkFactory: { sdk })
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            sdk.failLinkedPeers = failure.peerLookup
            sdk.failUnblock = failure.unblock
            sdk.failSaveContact = failure.saveContact
            do {
                _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Contact", restorePrivateConnection: true)
                XCTFail("Expected restoration to fail")
            } catch {}
            XCTAssertNil(sdk.record)
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
            sdk.failLinkedPeers = false
            sdk.failUnblock = false
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
        let eventsBeforeCleanup = sdk.events
        let report = try await service.clearPrivatePaymentLists(to: [sdk.publicKey])
        XCTAssertNil(report)
        XCTAssertEqual(sdk.events, eventsBeforeCleanup)
    }

    func testDisabledPrivateCapabilityDoesNotQueueWithdrawal() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.capabilities.privatePayments = false
        let service = PaykitSdkService(sdkFactory: { sdk })

        let report = try await service.clearPrivatePaymentLists(to: [sdk.publicKey])

        XCTAssertNil(report)
        XCTAssertTrue(sdk.events.isEmpty)
        XCTAssertFalse(sdk.capabilities.privatePayments)
    }

    func testCleanupPendingDoesNotEnablePrivateCapability() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.capabilities.privatePayments = false
        let service = PaykitSdkService(sdkFactory: { sdk })

        try await service.syncPaykitApp(privatePaymentsEnabled: false)

        XCTAssertFalse(sdk.capabilities.privatePayments)
    }

    func testWithdrawalBatchesPreflightAndDelegatesRepeatedEmptyLists() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let other = "pubky5rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        var blocked = try XCTUnwrap(sdk.peers.first)
        blocked.counterparty = "pubky6rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        blocked.state = .blocked
        sdk.peers.append(blocked)
        let service = PaykitSdkService(sdkFactory: { sdk })
        let empty = try await service.clearPrivatePaymentLists(to: [])
        XCTAssertNil(empty)
        XCTAssertEqual(sdk.peerReads, 0)

        for client in [service, service, PaykitSdkService(sdkFactory: { sdk })] {
            let report = try await client.clearPrivatePaymentLists(to: [sdk.publicKey, other, blocked.counterparty])
            XCTAssertEqual(report?.cleared.map(\.counterparty), [sdk.publicKey, other])
        }

        XCTAssertEqual(sdk.peerReads, 3)
        XCTAssertEqual(sdk.identityReads, 3)
        XCTAssertEqual(sdk.registryReads, 3)
        XCTAssertEqual(sdk.withdrawals.count, 3)
        XCTAssertTrue(sdk.withdrawals.allSatisfy { updates in
            updates.map(\.counterparty) == [sdk.publicKey, other] && updates.allSatisfy(\.reservations.isEmpty)
        })
    }

    func testWithdrawalRecoversPeerBeforeQueueingAndRetainsRecoveryFailure() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        var healthy = sdk.peers[0]
        healthy.counterparty = "pubky5rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        sdk.peers.append(healthy)
        sdk.peers[0].state = .recoveryRequired
        sdk.failRecovery = true
        let service = PaykitSdkService(sdkFactory: { sdk })
        let keys = [sdk.publicKey, healthy.counterparty]

        let failed = try await service.clearPrivatePaymentLists(to: keys)
        XCTAssertEqual(failed?.failedToQueue.map(\.counterparty), [sdk.publicKey])
        XCTAssertEqual(failed?.cleared.map(\.counterparty), [healthy.counterparty])
        XCTAssertEqual(sdk.peers[0].state, .recoveryRequired)

        sdk.failRecovery = false
        let report = try await service.clearPrivatePaymentLists(to: keys)
        XCTAssertEqual(sdk.peers[0].state, .linking)
        XCTAssertEqual(report?.cleared.map(\.counterparty), keys)
        XCTAssertTrue(report?.failedToQueue.isEmpty == true)
        XCTAssertTrue(try XCTUnwrap(sdk.withdrawals.first?.first).reservations.isEmpty)
    }
}

private final class ContactLifecycleSdk: PaykitSdk, @unchecked Sendable {
    let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    var events: [String] = []
    var requests: [PaymentRequestRecord] = []
    var failWithdrawal = false
    var failBlock = false
    var failLinkedPeers = false
    var failUnblock = false
    var failSaveContact = false
    var failRecovery = false
    var peerReads = 0
    var identityReads = 0
    var registryReads = 0
    var withdrawals = [[PrivatePaymentListReservationUpdateInput]]()
    var capabilities = PaykitAppCapabilities(privatePayments: true, paymentRequests: true, receipts: false, outgoingPayments: true)
    lazy var record: ContactRecord? = ContactRecord(
        publicKey: publicKey, label: "Contact", profile: nil,
        profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
        publicContactMarkerStatus: .notPublished,
        publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
    )
    lazy var peers: [LinkedPeerRecord] = [
        LinkedPeerRecord(counterparty: publicKey, state: .linked,
                         lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
                         localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
                         remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil),
    ]

    override func paykitAppRegistry(publicKey _: String) async throws -> PaykitAppRegistry? {
        registryReads += 1
        return registry
    }

    private var registry: PaykitAppRegistry {
        PaykitAppRegistry(keyGeneration: 1, noisePublicKey: nil,
                          apps: [PaykitApp(appId: "bitkit", displayName: "Bitkit", capabilities: capabilities)],
                          defaultAppId: nil, defaultAppsByEndpoint: [:])
    }

    override func identityStatus() async throws -> IdentityStatus? {
        identityReads += 1
        return IdentityStatus(publicKey: publicKey, capability: .privateLinkCapable)
    }

    override func publishPaykitApp(displayName _: String, capabilities: PaykitAppCapabilities) async throws -> PaykitAppRegistry {
        self.capabilities = capabilities
        return registry
    }

    override func backupStateRevision() async throws -> String {
        "revision"
    }

    override func stateRevision() throws -> String? {
        nil
    }

    override func paymentRequests() async throws -> [PaymentRequestRecord] {
        requests
    }

    override func contactRecord(publicKey: String) async throws -> ContactRecord? {
        record
    }

    override func linkedPeers() async throws -> [LinkedPeerRecord] {
        peerReads += 1
        if failLinkedPeers { throw PubkyServiceError.profileNotFound }
        return peers
    }

    override func ensureLinkWithPeer(counterparty: String, maxAdvanceSteps: UInt32) async throws -> LinkedPeerHandshakeReport {
        XCTAssertEqual(maxAdvanceSteps, 1)
        if failRecovery { throw PubkyServiceError.sessionNotActive }
        let index = try XCTUnwrap(peers.firstIndex { $0.counterparty == counterparty })
        XCTAssertEqual(peers[index].state, .recoveryRequired)
        peers[index].state = .linking
        return LinkedPeerHandshakeReport(counterparty: counterparty, state: .linking, generation: 1, handshakeRole: nil)
    }

    override func syncPrivatePaymentListsWithReservationsAndProcessOutbound(
        updates: [PrivatePaymentListReservationUpdateInput],
        clearUnlistedLinkedPeers: Bool
    ) async throws -> PrivatePaymentListDeliveryReport {
        XCTAssertFalse(clearUnlistedLinkedPeers)
        let failed = updates.filter { update in
            peers.contains { $0.counterparty == update.counterparty && $0.state == .recoveryRequired }
        }
        withdrawals.append(updates)
        return .init(
            queued: [],
            cleared: updates.filter { update in !failed.contains { $0.counterparty == update.counterparty } }
                .map { .init(counterparty: $0.counterparty, outboundMessageId: 1, error: nil) },
            failedToQueue: failed.map { .init(counterparty: $0.counterparty, outboundMessageId: nil, error: nil) },
            failedToDeliver: []
        )
    }

    override func clearPrivatePaymentListAndProcessOutbound(
        counterparty: String
    ) async throws -> PrivatePaymentListDeliveryReport {
        XCTAssertEqual(counterparty, publicKey)
        events.append("clear")
        if failWithdrawal { throw PubkyServiceError.sessionNotActive }
        return PrivatePaymentListDeliveryReport(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
    }

    override func blockPeer(counterparty: String) async throws -> LinkedPeerRecord {
        if failBlock { throw PubkyServiceError.profileNotFound }
        events.append("block")
        let index = try XCTUnwrap(peers.firstIndex { PubkyPublicKeyFormat.matches($0.counterparty, counterparty) })
        peers[index].state = .blocked
        return peers[index]
    }

    override func unblockPeer(counterparty: String) async throws -> LinkedPeerRecord {
        if failUnblock { throw PubkyServiceError.profileNotFound }
        let index = try XCTUnwrap(peers.firstIndex { PubkyPublicKeyFormat.matches($0.counterparty, counterparty) })
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
            publicKey: update.publicKey, label: update.label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
        record = saved
        return saved
    }
}
