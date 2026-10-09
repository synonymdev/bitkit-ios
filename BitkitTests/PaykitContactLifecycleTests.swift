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
            let skipped = try await service.removeContacts(publicKeys: [sdk.publicKey])
            XCTAssertTrue(skipped.isEmpty)
            XCTAssertNotNil(sdk.record)
            XCTAssertTrue(sdk.events.isEmpty)
            if testCase.endsAt != nil {
                sdk.requests[0].terms?.recurrence?.endsAt = "2000-02-01T00:00:00Z"
            } else {
                sdk.requests[0].state = .canceled
            }
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            XCTAssertNil(sdk.record)
            _ = try await sdk.saveContact(update: ContactUpdate(publicKey: sdk.publicKey, label: "Contact"))
            let removed = try await service.removeContacts(publicKeys: [sdk.publicKey])
            XCTAssertEqual(removed.map(\.publicKey), [sdk.publicKey])
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
        var unselectedPeer = try XCTUnwrap(sdk.peers.first)
        unselectedPeer.counterparty = "pubky" + String(repeating: "z", count: 52)
        sdk.peers.append(unselectedPeer)
        _ = try await service.saveContacts(updates: [ContactUpdate(publicKey: sdk.publicKey, label: "Readded")])
        XCTAssertEqual(sdk.peers.first?.state, .notLinked)
        XCTAssertEqual(sdk.peers.last?.state, .blocked)
        XCTAssertEqual(sdk.record?.label, "Readded")
    }

    func testFailedPrivateConnectionRestoreCanBeRetriedWithoutASavedContact() async throws {
        for bulk in [false, true] {
            let sdk = ContactLifecycleSdk(noPointer: .init())
            let service = PaykitSdkService(sdkFactory: { sdk })
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            sdk.restoreError = PubkyServiceError.profileNotFound
            sdk.events.removeAll()
            let save = {
                if bulk {
                    _ = try await service.saveContacts(updates: [ContactUpdate(publicKey: sdk.publicKey, label: "Contact")])
                } else {
                    _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Contact", restorePrivateConnection: true)
                }
            }
            do {
                try await save()
                XCTFail("Expected restoration to fail")
            } catch {}
            XCTAssertNil(sdk.record)
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
            XCTAssertEqual(sdk.events, ["save-and-unblock"])
            sdk.restoreError = nil
            try await save()
            XCTAssertNotNil(sdk.record)
            XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .notLinked })
            XCTAssertEqual(sdk.events, ["save-and-unblock", "save-and-unblock"])
        }
    }

    func testLabelUpdateDoesNotUnblockAnExistingContact() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.peers[0].state = .blocked
        let service = PaykitSdkService(sdkFactory: { sdk })

        let saved = try await service.saveContact(publicKey: sdk.publicKey, label: "Updated")

        XCTAssertEqual(saved.label, "Updated")
        XCTAssertEqual(sdk.peers[0].state, .blocked)
        XCTAssertEqual(sdk.events, ["save"])
        XCTAssertEqual(sdk.contactReads, 1)
        XCTAssertEqual(sdk.peerReads, 0)
        XCTAssertTrue(sdk.restoredBatches.isEmpty)
    }

    func testExplicitReaddUsesAtomicSaveWithoutContactOrPeerPreflight() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.record = nil
        sdk.peers[0].state = .blocked
        let service = PaykitSdkService(sdkFactory: { sdk })

        let saved = try await service.saveContact(publicKey: sdk.publicKey, label: "Readded", restorePrivateConnection: true)

        XCTAssertEqual(saved.publicKey, sdk.publicKey)
        XCTAssertEqual(saved.label, "Readded")
        XCTAssertEqual(sdk.peers[0].state, .notLinked)
        XCTAssertEqual(sdk.events, ["save-and-unblock"])
        XCTAssertEqual(sdk.restoredBatches.map { $0.map(\.publicKey) }, [[sdk.publicKey]])
        XCTAssertEqual(sdk.contactReads, 0)
        XCTAssertEqual(sdk.peerReads, 0)
    }

    func testBulkReaddForwardsOneAtomicSaveWithoutPreflight() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let updates = [
            ContactUpdate(publicKey: sdk.publicKey, label: "Alice"),
            ContactUpdate(publicKey: "pubky5rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg", label: "Bob"),
        ]
        let service = PaykitSdkService(sdkFactory: { sdk })

        let saved = try await service.saveContacts(updates: updates)

        XCTAssertEqual(saved.map(\.publicKey), updates.map(\.publicKey))
        XCTAssertEqual(saved.map(\.label), updates.map(\.label))
        XCTAssertEqual(sdk.restoredBatches.map { $0.map(\.publicKey) }, [updates.map(\.publicKey)])
        XCTAssertEqual(sdk.events, ["save-and-unblock"])
        XCTAssertEqual(sdk.contactReads, 0)
        XCTAssertEqual(sdk.peerReads, 0)
    }

    func testEmptyImportDoesNotAccessSdk() async throws {
        let service = PaykitSdkService(sdkFactory: {
            XCTFail("An empty import must not access the SDK")
            return ContactLifecycleSdk(noPointer: .init())
        })

        let saved = try await service.saveContacts(updates: [])

        XCTAssertTrue(saved.isEmpty)
    }

    func testImportCancelledAfterAtomicCommitDoesNotPublishOrReblockContacts() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.record = nil
        sdk.peers[0].state = .blocked
        sdk.cancelAfterRestore = true
        let service = PaykitSdkService(sdkFactory: { sdk })
        let manager = ContactsManager()
        let contact = Bitkit.PubkyContact(
            publicKey: sdk.publicKey,
            profile: Bitkit.PubkyProfile(publicKey: sdk.publicKey, name: "Readded", bio: "", imageUrl: nil, links: [], status: nil)
        )

        let importTask = Task {
            try await manager.importContacts(contacts: [contact]) { updates, identity in
                _ = try await service.saveContacts(updates: updates, expectedIdentity: identity)
            }
        }
        do {
            try await importTask.value
            XCTFail("Expected cancellation to discard the import result")
        } catch is CancellationError {}

        XCTAssertTrue(manager.contacts.isEmpty)
        XCTAssertEqual(sdk.record?.label, "Readded")
        XCTAssertEqual(sdk.peers[0].state, .notLinked)
        XCTAssertEqual(sdk.events, ["save-and-unblock"])
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

    func testWithdrawalRechecksContactSnapshotAfterSdkPreflight() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        let inspected = expectation(description: "Withdrawal preflight is pending")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        sdk.beforeLinkedPeers = {
            inspected.fulfill()
            for await _ in resume {}
        }
        var current = true
        let withdrawal = Task {
            try await service.clearPrivatePaymentLists(to: [sdk.publicKey], isSessionCurrent: { current })
        }
        await fulfillment(of: [inspected], timeout: 2)
        current = false
        continuation.finish()
        do {
            _ = try await withdrawal.value
            XCTFail("Superseded contact cleanup must not queue withdrawal")
        } catch PubkyServiceError.sessionNotActive {}
        XCTAssertTrue(sdk.withdrawals.isEmpty)
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
    var failRecovery = false
    var restoreError: Error?
    var cancelAfterRestore = false
    var restoredBatches: [[ContactUpdate]] = []
    var contactReads = 0
    var peerReads = 0
    var identityReads = 0
    var registryReads = 0
    var beforeLinkedPeers: (() async -> Void)?
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

    override func observedBackupStateRevision() throws -> ObservedBackupStateRevision? {
        nil
    }

    override func stateRevision() throws -> String? {
        nil
    }

    override func paymentRequests() async throws -> [PaymentRequestRecord] {
        requests
    }

    override func contactRecord(publicKey: String) async throws -> ContactRecord? {
        contactReads += 1
        return record
    }

    override func linkedPeers() async throws -> [LinkedPeerRecord] {
        await beforeLinkedPeers?()
        peerReads += 1
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
        XCTFail("Explicit re-add must save and unblock atomically")
        let index = try XCTUnwrap(peers.firstIndex { PubkyPublicKeyFormat.matches($0.counterparty, counterparty) })
        peers[index].state = .notLinked
        return peers[index]
    }

    override func removeContact(publicKey: String) async throws -> ContactRecord? {
        events.append("remove")
        defer { record = nil }
        return record
    }

    override func removeContactsAndBlockPeers(publicKeys: [String]) async throws -> [ContactRecord] {
        guard publicKeys.contains(publicKey), let record else { return [] }
        events.append("block-and-remove")
        self.record = nil
        peers[0].state = .blocked
        return [record]
    }

    override func saveContact(update: ContactUpdate) async throws -> ContactRecord {
        events.append("save")
        let saved = Self.contactRecord(update: update)
        record = saved
        return saved
    }

    override func saveContactsAndUnblockPeers(updates: [ContactUpdate]) async throws -> [ContactRecord] {
        events.append("save-and-unblock")
        restoredBatches.append(updates)
        if let restoreError { throw restoreError }
        let saved = updates.map(Self.contactRecord)
        for index in peers.indices where peers[index].state == .blocked {
            if updates.contains(where: { PubkyPublicKeyFormat.matches($0.publicKey, peers[index].counterparty) }) {
                peers[index].state = .notLinked
            }
        }
        record = saved.last ?? record
        if cancelAfterRestore { withUnsafeCurrentTask { $0?.cancel() } }
        return saved
    }

    private static func contactRecord(update: ContactUpdate) -> ContactRecord {
        ContactRecord(
            publicKey: update.publicKey, label: update.label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
    }

    override func saveContacts(updates: [ContactUpdate]) async throws -> [ContactRecord] {
        XCTFail("Explicit re-add must save and unblock atomically")
        return updates.map(Self.contactRecord)
    }
}
