@testable import Bitkit
import Foundation
import struct Paykit.ContactRecord
import struct Paykit.PaykitProfile
import struct Paykit.PrivatePaymentListDeliveryReport
import XCTest

@MainActor
final class ContactPaymentsServiceTests: XCTestCase {
    func testContactPaymentsRemainOffUntilDefaultPublicationCompletes() throws {
        try withIsolatedDefaults { defaults in
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testConfirmedContactPaymentsReflectBothPublicationModes() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))

            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))

            defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testLegacyPaymentOptionsAreAlwaysReenabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
            defaults.set(false, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)

            ContactPaymentsService.enableAllPaymentOptions(defaults: defaults)

            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.lightningPaymentOptionEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.onchainPaymentOptionEnabledKey))
        }
    }

    func testEnablingContactPaymentsPublishesPublicAndPrivateEndpoints() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            operations.onPreparePrivateEndpoints = {
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            }

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: ["contact-a", "contact-b"],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [true])
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertEqual(operations.privatePublications[0].contactPublicKeys, ["contact-a", "contact-b"])
            XCTAssertFalse(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.calls, ["public:true", "private:publish"])
            XCTAssertEqual(operations.privateRemovalCount, 0)
            XCTAssertEqual(operations.publicCleanupValues, [false])
            XCTAssertEqual(operations.privateCleanupValues, [false])
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.lightningPaymentOptionEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.onchainPaymentOptionEnabledKey))
        }
    }

    func testEnablingContactPaymentsWithoutPrivateCapabilityPublishesOnlyPublicEndpoints() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
            let operations = OperationsSpy()

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: false,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [true])
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertTrue(operations.privateCleanupValues.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testEnablingContactPaymentsDefersUnavailablePrivatePublication() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let service = PrivatePaykitService()
            let wallet = WalletViewModel()
            let contactPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
            let operations = OperationsSpy()
            operations.preparePrivateEndpoints = { contactPublicKeys, requireImmediatePublication, _ in
                await service.prepareSavedContacts(
                    contactPublicKeys,
                    wallet: wallet,
                    requireImmediatePublication: requireImmediatePublication
                )
            }

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: [contactPublicKey],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertEqual(operations.publicPublicationValues, [true])
            XCTAssertEqual(operations.privateRemovalCount, 0)
            let knownContacts = await service.knownSavedContactKeys
            XCTAssertEqual(knownContacts, [contactPublicKey])
        }
    }

    func testDisablingContactPaymentsRemovesBothEndpointTypes() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            let operations = OperationsSpy()

            try await ContactPaymentsService.setEnabled(
                false,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(defaults: defaults),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [false])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
            XCTAssertEqual(operations.publicCleanupValues, [true, false])
            XCTAssertEqual(operations.privateCleanupValues, [true, false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testSwitchingToPublicOnlyMarksExistingPrivateEndpointsForCleanup() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            let operations = OperationsSpy()
            operations.onSyncPublicEndpoints = { publish in
                XCTAssertTrue(publish)
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                XCTAssertEqual(operations.privateCleanupValues, [true])
            }

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: false,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.privateCleanupValues, [true])
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testFailedPrivateSetupWithdrawsPublicEndpointAndRestoresDisabledState() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
            let operations = OperationsSpy()
            operations.privatePublicationFailures = [1]

            do {
                try await ContactPaymentsService.setEnabled(
                    true,
                    contactPublicKeys: ["contact-a"],
                    canUsePrivatePayments: true,
                    operations: operations.makeOperations(),
                    defaults: defaults
                )
                XCTFail("Expected private endpoint publication to fail")
            } catch {
                XCTAssertEqual(error as? TestError, .operationFailed)
            }

            XCTAssertEqual(operations.publicPublicationValues, [true, false])
            XCTAssertTrue(operations.calls.contains("public:true"))
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertFalse(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.publicCleanupValues, [false, true])
            XCTAssertEqual(operations.privateCleanupValues, [false, false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
        }
    }

    func testFailedDisableKeepsContactPaymentsDisabledAndRetriesCleanup() async throws {
        for (privateFails, publicFails) in [(true, false), (false, true), (true, true)] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
                let operations = OperationsSpy()
                operations.privateRemovalFailures = privateFails ? [1] : []
                operations.publicPublicationFailures = publicFails ? [1] : []

                do {
                    try await ContactPaymentsService.setEnabled(
                        false,
                        contactPublicKeys: ["contact-a"],
                        canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults),
                        defaults: defaults
                    )
                    XCTFail("Expected endpoint cleanup to fail")
                } catch {
                    XCTAssertEqual(error as? TestError, .operationFailed)
                }

                XCTAssertEqual(operations.publicPublicationValues, [false])
                XCTAssertEqual(operations.privateRemovalCount, 1)
                XCTAssertTrue(operations.privatePublications.isEmpty)
                XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
                XCTAssertEqual(operations.publicCleanupValues, [true, publicFails])
                XCTAssertEqual(operations.privateCleanupValues, [true, privateFails])
                XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey), publicFails)
                XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey), privateFails)
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))

                try await ContactPaymentsService.setEnabled(
                    false,
                    contactPublicKeys: ["contact-a"],
                    canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults),
                    defaults: defaults
                )

                XCTAssertEqual(operations.publicPublicationValues, [false, false])
                XCTAssertEqual(operations.privateRemovalCount, 2)
                XCTAssertTrue(operations.privatePublications.isEmpty)
                XCTAssertEqual(operations.publicCleanupValues, [true, publicFails, true, false])
                XCTAssertEqual(operations.privateCleanupValues, [true, privateFails, true, false])
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            }
        }
    }

    func testForegroundReconciliationSkipsBothPhasesOfActiveDisable() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let privateRemovalStarted = expectation(description: "Private removal started")
            let publicRemovalStarted = expectation(description: "Public removal started")
            let (privateRemoval, finishPrivateRemoval) = AsyncStream<Void>.makeStream()
            let (publicRemoval, finishPublicRemoval) = AsyncStream<Void>.makeStream()
            defer {
                finishPrivateRemoval.finish()
                finishPublicRemoval.finish()
            }
            operations.onRemovePrivateEndpoints = {
                privateRemovalStarted.fulfill()
                for await _ in privateRemoval {}
            }
            operations.onSyncPublicEndpoints = { _ in
                publicRemovalStarted.fulfill()
                for await _ in publicRemoval {}
            }

            let disable = Task {
                try await ContactPaymentsService.setEnabled(
                    false, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [privateRemovalStarted], timeout: 2)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            await ContactPaymentsService.reconcilePendingEndpoints {
                XCTFail("Foreground cleanup must not restart private withdrawal")
            }

            finishPrivateRemoval.finish()
            await fulfillment(of: [publicRemovalStarted], timeout: 2)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            await ContactPaymentsService.reconcilePendingEndpoints {
                XCTFail("Foreground cleanup must not duplicate public withdrawal")
            }

            finishPublicRemoval.finish()
            try await disable.value
            XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            var reconciled = false
            await ContactPaymentsService.reconcilePendingEndpoints { reconciled = true }
            XCTAssertTrue(reconciled)
        }
    }

    func testEnablingWaitsForSuccessfulOrFailedDisable() async throws {
        for removalFails in [false, true] {
            try await withIsolatedDefaultsAsync { defaults in
                let operations = OperationsSpy()
                operations.privateRemovalFailures = removalFails ? [1] : []
                let removalStarted = expectation(description: "Withdrawal started")
                let enableRequested = expectation(description: "Enable requested during withdrawal")
                let (removal, finishRemoval) = AsyncStream<Void>.makeStream()
                defer { finishRemoval.finish() }
                operations.onRemovePrivateEndpoints = {
                    removalStarted.fulfill()
                    for await _ in removal {}
                }

                let disable = Task {
                    try await ContactPaymentsService.setEnabled(
                        false, contactPublicKeys: [], canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                }
                await fulfillment(of: [removalStarted], timeout: 2)
                let enable = Task {
                    enableRequested.fulfill()
                    try await ContactPaymentsService.setEnabled(
                        true, contactPublicKeys: ["contact-a"], canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                }
                await fulfillment(of: [enableRequested], timeout: 2)
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertEqual(operations.calls, ["private:remove"])

                finishRemoval.finish()
                switch await disable.result {
                case .success:
                    XCTAssertFalse(removalFails)
                case let .failure(error):
                    XCTAssertTrue(removalFails)
                    XCTAssertEqual(error as? TestError, .operationFailed)
                }
                try await enable.value
                XCTAssertEqual(operations.calls, ["private:remove", "public:false", "public:true", "private:publish"])
                XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            }
        }
    }

    func testForegroundReconciliationCoalescesAndSerializesSharingChanges() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let reconciliationStarted = expectation(description: "Reconciliation started")
            let enableRequested = expectation(description: "Enable requested during reconciliation")
            let (reconciliation, finishReconciliation) = AsyncStream<Void>.makeStream()
            defer { finishReconciliation.finish() }
            var reconciliations = 0
            let retry = Task {
                await ContactPaymentsService.reconcilePendingEndpoints {
                    reconciliations += 1
                    reconciliationStarted.fulfill()
                    for await _ in reconciliation {}
                }
            }
            await fulfillment(of: [reconciliationStarted], timeout: 2)
            await ContactPaymentsService.reconcilePendingEndpoints { reconciliations += 1 }
            let enable = Task {
                enableRequested.fulfill()
                try await ContactPaymentsService.setEnabled(
                    true, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [enableRequested], timeout: 2)
            XCTAssertEqual(reconciliations, 1)
            XCTAssertTrue(operations.calls.isEmpty)

            finishReconciliation.finish()
            await retry.value
            try await enable.value
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertEqual(operations.publicPublicationValues, [true])
        }
    }

    func testCancelledSharingChangeDoesNotPublishAfterReconciliation() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let reconciliationStarted = expectation(description: "Reconciliation started")
            let enableRequested = expectation(description: "Enable requested during reconciliation")
            let (reconciliation, finishReconciliation) = AsyncStream<Void>.makeStream()
            defer { finishReconciliation.finish() }
            let retry = Task {
                await ContactPaymentsService.reconcilePendingEndpoints {
                    reconciliationStarted.fulfill()
                    for await _ in reconciliation {}
                }
            }
            await fulfillment(of: [reconciliationStarted], timeout: 2)
            let enable = Task {
                enableRequested.fulfill()
                try await ContactPaymentsService.setEnabled(
                    true, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [enableRequested], timeout: 2)
            enable.cancel()
            finishReconciliation.finish()
            await retry.value
            switch await enable.result {
            case .success:
                XCTFail("Cancelled sharing change must not publish")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(operations.calls.isEmpty)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            var reconciled = false
            await ContactPaymentsService.reconcilePendingEndpoints { reconciled = true }
            XCTAssertTrue(reconciled)
        }
    }

    func testContactPaymentsChangeStopsWhenPubkySignsOutDuringTheContactsLoad() async throws {
        enum SignOut {
            case never, finished, running
        }
        let cases: [(name: String, signOut: SignOut, loadFails: Bool)] = [
            ("still signed in", .never, false),
            ("signed out", .finished, false),
            ("sign-out still running", .running, false),
            ("signed out, then the load failed", .finished, true),
        ]
        let ownerKey = try useLocalPubkySecretKey()
        let contactKey = "pubky" + String(repeating: "y", count: 52)
        let record = contactRecord(publicKey: contactKey)

        for testCase in cases {
            try await withIsolatedDefaultsAsync { defaults in
                let pubkyProfile = signedInProfile(ownerKey: ownerKey)
                XCTAssertTrue(pubkyProfile.hasLocalSecretKeyForCurrentProfile, testCase.name)
                let loadStarted = expectation(description: "\(testCase.name): contacts load started")
                let (loadGate, releaseLoad) = AsyncStream<Void>.makeStream()
                let loadFails = testCase.loadFails
                let contactsManager = ContactsManager(contactRecords: {
                    loadStarted.fulfill()
                    for await _ in loadGate {}
                    if loadFails {
                        throw PubkyServiceError.sessionNotActive
                    }
                    return [record]
                })
                let operations = OperationsSpy()
                let change = Task {
                    try await ContactPaymentsService.setEnabled(
                        true,
                        pubkyProfile: pubkyProfile,
                        contactsManager: contactsManager,
                        operations: operations.makeOperations(),
                        defaults: defaults
                    )
                }
                await fulfillment(of: [loadStarted], timeout: 2)

                var runningSignOut: (task: Task<Void, Error>, release: AsyncStream<Void>.Continuation)?
                switch testCase.signOut {
                case .never:
                    break
                case .finished:
                    try await pubkyProfile.signOut(performSessionCleanup: {})
                case .running:
                    let cleanupStarted = expectation(description: "\(testCase.name): sign-out started")
                    let (cleanupGate, releaseCleanup) = AsyncStream<Void>.makeStream()
                    let signOut = Task {
                        try await pubkyProfile.signOut(performSessionCleanup: {
                            cleanupStarted.fulfill()
                            for await _ in cleanupGate {}
                        })
                    }
                    await fulfillment(of: [cleanupStarted], timeout: 2)
                    runningSignOut = (signOut, releaseCleanup)
                }
                releaseLoad.finish()
                let result = await change.result
                let enabled = testCase.signOut == .never
                XCTAssertEqual(try result.get(), enabled, testCase.name)
                if let runningSignOut {
                    runningSignOut.release.finish()
                    try await runningSignOut.task.value
                }

                XCTAssertEqual(operations.calls, enabled ? ["public:true", "private:publish"] : [], testCase.name)
                XCTAssertEqual(operations.privatePublications.map(\.contactPublicKeys), enabled ? [[contactKey]] : [], testCase.name)
                XCTAssertEqual(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), enabled, testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), enabled, testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), enabled, testCase.name)
            }
        }
    }

    /// A publication already holding its lock can finish; sign-out must remove it afterward and retain failed cleanup.
    func testContactPaymentsEnableStopsWhenPubkySignsOutDuringPublication() async throws {
        enum HeldPublication {
            case publicBeforeLock, privateBeforeLock, publicHoldingLock
        }
        let cases: [(name: String, held: HeldPublication, calls: [String], writes: [String], keepsFlags: Bool)] = [
            (
                "public publication waiting for its lock", .publicBeforeLock,
                ["public:true"], ["private:removed", "public:removal failed"], false
            ),
            (
                "private publication waiting for its lock", .privateBeforeLock,
                ["public:true", "private:publish"], ["public:published", "private:removed", "public:removal failed"], false
            ),
            (
                "public publication holding its lock while sign-out fails", .publicHoldingLock,
                ["public:true"], ["private:removal failed", "public:published"], true
            ),
        ]
        let ownerKey = try useLocalPubkySecretKey()
        let record = contactRecord(publicKey: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg")
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh, value: "bcrt1qendpoint", min: nil, max: nil, rawPayload: #"{"value":"bcrt1qendpoint"}"#
        )

        for testCase in cases {
            let defaults = UserDefaults.standard
            for key in [
                ContactPaymentsService.confirmedPreferenceKey, PublicPaykitService.publishingEnabledKey,
                PrivatePaykitService.publishingEnabledKey, PublicPaykitService.cleanupPendingKey,
                PrivatePaykitService.cleanupPendingKey, PrivatePaykitService.cacheStateKey,
            ] {
                defaults.removeObject(forKey: key)
            }
            let pubkyProfile = signedInProfile(ownerKey: ownerKey)
            let contactsManager = ContactsManager(contactRecords: { [record] })
            let privatePaykit = PrivatePaykitService()
            let writes = WriteLog()
            let publicationOperations = PrivatePaykitService.EndpointPublicationOperations(
                currentPublicKey: { ownerKey },
                ensureLink: { _ in .linked },
                buildEndpoints: { _ in [endpoint] },
                syncPaymentLists: { _ in
                    writes.append("private:published")
                    return PrivatePaymentListDeliveryReport(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
                }
            )
            let reachedHeldPoint = expectation(description: "\(testCase.name): publication reached its held point")
            let (gate, release) = AsyncStream<Void>.makeStream()
            let held = testCase.held
            let operations = OperationsSpy()
            operations.preparePrivateEndpoints = { contactPublicKeys, requireImmediatePublication, isSessionCurrent in
                if held == .privateBeforeLock {
                    reachedHeldPoint.fulfill()
                    for await _ in gate {}
                }
                _ = await privatePaykit.rememberSavedContacts(contactPublicKeys, replacing: true)
                return await privatePaykit.syncLocalEndpointPublication(
                    for: contactPublicKeys,
                    reason: "test",
                    requireImmediatePublication: requireImmediatePublication,
                    isSessionCurrent: isSessionCurrent,
                    operations: publicationOperations
                )
            }
            operations.syncPublicEndpoints = { publish, isSessionCurrent in
                guard publish else { return }
                if held == .publicBeforeLock {
                    reachedHeldPoint.fulfill()
                    for await _ in gate {}
                }
                try await PublicPaykitService.withEndpointLock(unlessSessionEnded: isSessionCurrent) {
                    if held == .publicHoldingLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    writes.append("public:published")
                }
            }
            let enable = Task {
                try await ContactPaymentsService.setEnabled(
                    true,
                    pubkyProfile: pubkyProfile,
                    contactsManager: contactsManager,
                    operations: operations.makeOperations(),
                    defaults: defaults
                )
            }
            await fulfillment(of: [reachedHeldPoint], timeout: 2)

            let privateRemovalFails = held == .publicHoldingLock
            do {
                try await pubkyProfile.signOut(performSessionCleanup: { @MainActor in
                    try await privatePaykit.withPublicationLock {
                        guard !privateRemovalFails else {
                            writes.append("private:removal failed")
                            throw TestError.operationFailed
                        }
                        writes.append("private:removed")
                    }
                    do {
                        try await PublicPaykitService.withEndpointLock {
                            writes.append("public:removal failed")
                            throw TestError.operationFailed
                        }
                    } catch {
                        PublicPaykitService.setCleanupPending(true)
                    }
                })
                XCTAssertFalse(privateRemovalFails, testCase.name)
            } catch {
                XCTAssertTrue(privateRemovalFails, testCase.name)
            }
            release.finish()
            let result = await enable.result

            XCTAssertFalse(try result.get(), testCase.name)
            XCTAssertEqual(operations.calls, testCase.calls, testCase.name)
            XCTAssertEqual(writes.entries, testCase.writes, testCase.name)
            XCTAssertEqual(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), testCase.keepsFlags, testCase.name)
            XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), testCase.keepsFlags, testCase.name)
            XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), testCase.keepsFlags, testCase.name)
            XCTAssertEqual(operations.publicCleanupValues, held == .privateBeforeLock ? [false] : [], testCase.name)
            XCTAssertEqual(operations.privateCleanupValues, held == .privateBeforeLock ? [false] : [], testCase.name)
            XCTAssertTrue(PublicPaykitService.isCleanupPending, testCase.name)
        }
    }

    func testContactPaymentsChangeWritesNothingOnceThePubkySessionChanged() async throws {
        let cases: [(name: String, enabled: Bool, calls: [String])] = [
            ("enable", true, []),
            ("disable", false, []),
        ]

        for testCase in cases {
            try await withIsolatedDefaultsAsync { defaults in
                let sharing = !testCase.enabled
                defaults.set(sharing, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(sharing, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(sharing, forKey: PrivatePaykitService.publishingEnabledKey)
                let operations = OperationsSpy()

                try await ContactPaymentsService.setEnabled(
                    testCase.enabled,
                    contactPublicKeys: ["contact-a"],
                    canUsePrivatePayments: true,
                    operations: operations.makeOperations(),
                    defaults: defaults,
                    isChangeCurrent: { false }
                )

                XCTAssertEqual(operations.calls, testCase.calls, testCase.name)
                XCTAssertEqual(operations.publicCleanupValues, [], testCase.name)
                XCTAssertEqual(operations.privateCleanupValues, [], testCase.name)
                XCTAssertEqual(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), sharing, testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), sharing, testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), sharing, testCase.name)
            }
        }
    }

    func testContactPaymentsDisableWinsOverAnOlderEnableStillPublishing() async throws {
        enum HeldPublication {
            case privateBeforeLock, publicBeforeLock, publicHoldingLock
        }
        let cases: [(name: String, held: HeldPublication, writes: [String])] = [
            ("private publication waiting for its lock", .privateBeforeLock, ["public:published", "private:removed", "public:removed"]),
            ("public publication waiting for its lock", .publicBeforeLock, ["private:removed", "public:removed"]),
            (
                "public publication holding its lock", .publicHoldingLock,
                ["public:published", "private:removed", "public:removed"]
            ),
        ]
        let ownerKey = try useLocalPubkySecretKey()
        let record = contactRecord(publicKey: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg")

        for testCase in cases {
            try await withIsolatedDefaultsAsync { defaults in
                let pubkyProfile = signedInProfile(ownerKey: ownerKey)
                let contactsManager = ContactsManager(contactRecords: { [record] })
                let endpoints = LockedEndpointWrites()
                let reachedHeldPoint = expectation(description: "\(testCase.name): publication reached its held point")
                let disableRequested = expectation(description: "\(testCase.name): disable requested")
                let (gate, release) = AsyncStream<Void>.makeStream()
                let held = testCase.held
                let operations = OperationsSpy()
                operations.preparePrivateEndpoints = { _, _, isChangeCurrent in
                    if held == .privateBeforeLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    return await endpoints.writePrivateReturningError("private:published", isChangeCurrent: isChangeCurrent)
                }
                operations.removePrivateEndpoints = { isChangeCurrent in
                    try await endpoints.writePrivate("private:removed", isChangeCurrent: isChangeCurrent)
                }
                operations.syncPublicEndpoints = { publish, isChangeCurrent in
                    if publish, held == .publicBeforeLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    try await endpoints.writePublic(publish ? "public:published" : "public:removed", isChangeCurrent: isChangeCurrent) {
                        if publish, held == .publicHoldingLock {
                            reachedHeldPoint.fulfill()
                            for await _ in gate {}
                        }
                    }
                }
                let enable = Task {
                    return try await ContactPaymentsService.setEnabled(
                        true, pubkyProfile: pubkyProfile, contactsManager: contactsManager, operations: operations.makeOperations(),
                        defaults: defaults
                    )
                }
                await fulfillment(of: [reachedHeldPoint], timeout: 2)

                let disable = Task {
                    disableRequested.fulfill()
                    return try await ContactPaymentsService.setEnabled(
                        false, pubkyProfile: pubkyProfile, contactsManager: contactsManager, operations: operations.makeOperations(),
                        defaults: defaults
                    )
                }
                await fulfillment(of: [disableRequested], timeout: 2)
                release.finish()
                let enableResult = await enable.result
                let disableResult = await disable.result

                XCTAssertFalse(try enableResult.get(), testCase.name)
                XCTAssertTrue(try disableResult.get(), testCase.name)
                XCTAssertEqual(endpoints.entries, testCase.writes, testCase.name)
                XCTAssertEqual(operations.publicCleanupValues.last, false, testCase.name)
                XCTAssertEqual(operations.privateCleanupValues.last, false, testCase.name)
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), testCase.name)
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), testCase.name)
                XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), testCase.name)
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults), testCase.name)
            }
        }
    }

    func testContactPaymentsEnableWinsOverAnOlderDisableStillRemoving() async throws {
        enum HeldRemoval {
            case privateBeforeLock, publicBeforeLock, publicHoldingLock
        }
        let cases: [(name: String, held: HeldRemoval, writes: [String])] = [
            ("private removal waiting for its lock", .privateBeforeLock, ["public:published", "private:published"]),
            (
                "public removal waiting for its lock", .publicBeforeLock,
                ["private:removed", "public:published", "private:published"]
            ),
            (
                "public removal holding its lock", .publicHoldingLock,
                ["private:removed", "public:removed", "public:published", "private:published"]
            ),
        ]
        let ownerKey = try useLocalPubkySecretKey()
        let record = contactRecord(publicKey: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg")

        for testCase in cases {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
                let pubkyProfile = signedInProfile(ownerKey: ownerKey)
                let contactsManager = ContactsManager(contactRecords: { [record] })
                let endpoints = LockedEndpointWrites()
                let reachedHeldPoint = expectation(description: "\(testCase.name): removal reached its held point")
                let enableRequested = expectation(description: "\(testCase.name): enable requested")
                let (gate, release) = AsyncStream<Void>.makeStream()
                let held = testCase.held
                let operations = OperationsSpy()
                operations.removePrivateEndpoints = { isChangeCurrent in
                    if held == .privateBeforeLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    try await endpoints.writePrivate("private:removed", isChangeCurrent: isChangeCurrent)
                }
                operations.preparePrivateEndpoints = { _, _, isChangeCurrent in
                    return await endpoints.writePrivateReturningError("private:published", isChangeCurrent: isChangeCurrent)
                }
                operations.syncPublicEndpoints = { publish, isChangeCurrent in
                    if !publish, held == .publicBeforeLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    try await endpoints.writePublic(publish ? "public:published" : "public:removed", isChangeCurrent: isChangeCurrent) {
                        if !publish, held == .publicHoldingLock {
                            reachedHeldPoint.fulfill()
                            for await _ in gate {}
                        }
                    }
                }
                let disable = Task {
                    try await ContactPaymentsService.setEnabled(
                        false, pubkyProfile: pubkyProfile, contactsManager: contactsManager, operations: operations.makeOperations(),
                        defaults: defaults
                    )
                }
                await fulfillment(of: [reachedHeldPoint], timeout: 2)

                let enable = Task {
                    enableRequested.fulfill()
                    return try await ContactPaymentsService.setEnabled(
                        true, pubkyProfile: pubkyProfile, contactsManager: contactsManager, operations: operations.makeOperations(),
                        defaults: defaults
                    )
                }
                await fulfillment(of: [enableRequested], timeout: 2)
                release.finish()
                let disableResult = await disable.result
                let enableResult = await enable.result

                XCTAssertFalse(try disableResult.get(), testCase.name)
                XCTAssertTrue(try enableResult.get(), testCase.name)
                XCTAssertEqual(endpoints.entries, testCase.writes, testCase.name)
                XCTAssertEqual(operations.publicCleanupValues.last, false, testCase.name)
                XCTAssertEqual(operations.privateCleanupValues.last, false, testCase.name)
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), testCase.name)
                XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), testCase.name)
                XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), testCase.name)
            }
        }
    }

    func testContactPaymentsEnableSupersedesAnOlderEnableStillPublishing() async throws {
        let ownerKey = try useLocalPubkySecretKey()
        let record = contactRecord(publicKey: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg")

        try await withIsolatedDefaultsAsync { defaults in
            let pubkyProfile = signedInProfile(ownerKey: ownerKey)
            let contactsManager = ContactsManager(contactRecords: { [record] })
            let endpoints = LockedEndpointWrites()
            let olderReachedPublication = expectation(description: "older enable reached its private publication")
            let (gate, release) = AsyncStream<Void>.makeStream()
            var publicationCount = 0
            let operations = OperationsSpy()
            operations.preparePrivateEndpoints = { _, _, isChangeCurrent in
                publicationCount += 1
                if publicationCount == 1 {
                    olderReachedPublication.fulfill()
                    for await _ in gate {}
                }
                return await endpoints.writePrivateReturningError("private:published", isChangeCurrent: isChangeCurrent)
            }
            operations.syncPublicEndpoints = { publish, isChangeCurrent in
                try await endpoints.writePublic(publish ? "public:published" : "public:removed", isChangeCurrent: isChangeCurrent)
            }
            let olderEnable = Task {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: pubkyProfile, contactsManager: contactsManager, operations: operations.makeOperations(),
                    defaults: defaults
                )
            }
            await fulfillment(of: [olderReachedPublication], timeout: 2)

            let newerRequested = expectation(description: "newer enable requested")
            let newerEnable = Task {
                newerRequested.fulfill()
                return try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: pubkyProfile, contactsManager: contactsManager, operations: operations.makeOperations(),
                    defaults: defaults
                )
            }
            await fulfillment(of: [newerRequested], timeout: 2)
            release.finish()
            let isNewerEnableApplied = try await newerEnable.value
            let isOlderEnableApplied = try await olderEnable.value

            XCTAssertTrue(isNewerEnableApplied)
            XCTAssertFalse(isOlderEnableApplied)
            XCTAssertEqual(endpoints.entries, ["public:published", "public:published", "private:published"])
            XCTAssertEqual(operations.publicCleanupValues.last, false)
            XCTAssertEqual(operations.privateCleanupValues.last, false)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testEndpointRemovalsRefuseOnceTheirChangeIsNoLongerCurrent() async {
        do {
            try await PrivatePaykitService().removePublishedEndpoints(
                for: ["pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"],
                isSessionCurrent: { false }
            )
            XCTFail("Expected the private endpoint removal to refuse")
        } catch PubkyServiceError.sessionNotActive {
        } catch {
            XCTFail("Unexpected private endpoint removal error: \(error)")
        }

        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: WalletViewModel(), publish: false, isSessionCurrent: { false })
            XCTFail("Expected the public endpoint removal to refuse")
        } catch PubkyServiceError.sessionNotActive {
        } catch {
            XCTFail("Unexpected public endpoint removal error: \(error)")
        }
    }

    /// Pay Contacts' Continue enables contact payments in a task that outlives the screen. Like an import that finishes
    /// after the user left it, it opens Profile only for an applied enable while Pay Contacts is still showing.
    func testPayContactsOpensProfileOnlyForAnAppliedEnableWhilePayContactsIsShowing() {
        let cases: [(name: String, isApplied: Bool, currentRoute: Route?, destination: Route?)] = [
            ("applied on Pay Contacts", true, .payContacts, .profile),
            ("stopped by a Pubky sign-out", false, .payContacts, nil),
            ("stopped after the user left", false, .settings, nil),
            ("applied after the user opened another screen", true, .settings, nil),
            ("applied after the user went back", true, .createProfile, nil),
            ("applied after the user went back to the start", true, nil, nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                PayContactsView.destinationAfterEnable(isApplied: testCase.isApplied, currentRoute: testCase.currentRoute),
                testCase.destination,
                testCase.name
            )
        }
    }

    /// Signs in with a local secret key so private contact payments are available, restoring the app's defaults, the
    /// Pubky secret key and the adopted reference when the test ends.
    private func useLocalPubkySecretKey() throws -> String {
        snapshotAppDefaultsDomain()
        let savedReference = AdoptedPubkyReference.current
        let savedSecretKey = try Keychain.load(key: .pubkySecretKey)
        addTeardownBlock {
            AdoptedPubkyReference.current = savedReference
            if let savedSecretKey {
                try? Keychain.upsert(key: .pubkySecretKey, data: savedSecretKey)
            } else {
                try? Keychain.delete(key: .pubkySecretKey)
            }
        }
        let secretKeyHex = String(repeating: "01", count: 32)
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secretKeyHex.utf8))
        let rawOwnerKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        return rawOwnerKey.hasPrefix("pubky") ? rawOwnerKey : "pubky\(rawOwnerKey)"
    }

    private func signedInProfile(ownerKey: String) -> PubkyProfileManager {
        let pubkyProfile = PubkyProfileManager()
        pubkyProfile.publicKey = ownerKey
        pubkyProfile.authState = .authenticated
        return pubkyProfile
    }

    private func contactRecord(publicKey: String) -> ContactRecord {
        ContactRecord(
            publicKey: publicKey, label: "Contact",
            profile: PaykitProfile(displayName: "Contact", imageUri: nil, extraJson: nil),
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ContactPaymentsServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try body(defaults)
    }

    private func withIsolatedDefaultsAsync(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "ContactPaymentsServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try await body(defaults)
    }

    private enum TestError: Error, Equatable {
        case operationFailed
    }

    @MainActor
    private final class WriteLog {
        private(set) var entries: [String] = []

        func append(_ entry: String) {
            entries.append(entry)
        }
    }

    /// Stands in for the Paykit services' endpoint writes. Each takes the lock its real counterpart takes and, like it,
    /// refuses once that lock is held for a change that is no longer current.
    @MainActor
    private final class LockedEndpointWrites {
        private let privatePaykit = PrivatePaykitService()
        private(set) var entries: [String] = []

        func writePrivate(_ entry: String, isChangeCurrent: @escaping ContactPaymentsService.ChangeCheck) async throws {
            try await privatePaykit.withPublicationLock {
                guard isChangeCurrent() else {
                    throw PubkyServiceError.sessionNotActive
                }
                entries.append(entry)
            }
        }

        func writePrivateReturningError(_ entry: String, isChangeCurrent: @escaping ContactPaymentsService.ChangeCheck) async -> Error? {
            do {
                try await writePrivate(entry, isChangeCurrent: isChangeCurrent)
                return nil
            } catch {
                return error
            }
        }

        func writePublic(
            _ entry: String,
            isChangeCurrent: @escaping ContactPaymentsService.ChangeCheck,
            whileLocked: () async -> Void = {}
        ) async throws {
            try await PublicPaykitService.withEndpointLock(unlessSessionEnded: isChangeCurrent) {
                await whileLocked()
                entries.append(entry)
            }
        }
    }

    private final class OperationsSpy {
        struct PrivatePublication {
            let contactPublicKeys: [String]
            let requiresImmediatePublication: Bool
        }

        var publicPublicationValues: [Bool] = []
        var privatePublications: [PrivatePublication] = []
        var privateRemovalCount = 0
        var publicCleanupValues: [Bool] = []
        var privateCleanupValues: [Bool] = []
        var calls: [String] = []
        var publicPublicationFailures: Set<Int> = []
        var privatePublicationFailures: Set<Int> = []
        var privateRemovalFailures: Set<Int> = []
        var onPreparePrivateEndpoints: (() -> Void)?
        var preparePrivateEndpoints: (([String], Bool, @escaping ContactPaymentsService.ChangeCheck) async -> Error?)?
        var syncPublicEndpoints: ((Bool, @escaping ContactPaymentsService.ChangeCheck) async throws -> Void)?
        var removePrivateEndpoints: ((@escaping ContactPaymentsService.ChangeCheck) async throws -> Void)?
        var onRemovePrivateEndpoints: (() async -> Void)?
        var onSyncPublicEndpoints: ((Bool) async -> Void)?

        func makeOperations(defaults: UserDefaults? = nil) -> ContactPaymentsService.Operations {
            ContactPaymentsService.Operations(
                syncPublicEndpoints: { publish, isChangeCurrent in
                    self.calls.append("public:\(publish)")
                    self.publicPublicationValues.append(publish)
                    await self.onSyncPublicEndpoints?(publish)
                    try await self.syncPublicEndpoints?(publish, isChangeCurrent)
                    if self.publicPublicationFailures.contains(self.publicPublicationValues.count) {
                        throw TestError.operationFailed
                    }
                },
                preparePrivateEndpoints: { contactPublicKeys, requiresImmediatePublication, isChangeCurrent in
                    self.onPreparePrivateEndpoints?()
                    self.calls.append("private:publish")
                    self.privatePublications.append(
                        PrivatePublication(
                            contactPublicKeys: contactPublicKeys,
                            requiresImmediatePublication: requiresImmediatePublication
                        )
                    )
                    if let preparePrivateEndpoints = self.preparePrivateEndpoints {
                        return await preparePrivateEndpoints(contactPublicKeys, requiresImmediatePublication, isChangeCurrent)
                    }
                    return self.privatePublicationFailures.contains(self.privatePublications.count) ? TestError.operationFailed : nil
                },
                removePrivateEndpoints: { isChangeCurrent in
                    self.calls.append("private:remove")
                    self.privateRemovalCount += 1
                    await self.onRemovePrivateEndpoints?()
                    if self.privateRemovalFailures.contains(self.privateRemovalCount) {
                        throw TestError.operationFailed
                    }
                    try await self.removePrivateEndpoints?(isChangeCurrent)
                },
                setPublicCleanupPending: {
                    self.publicCleanupValues.append($0)
                    defaults?.set($0, forKey: PublicPaykitService.cleanupPendingKey)
                },
                setPrivateCleanupPending: {
                    self.privateCleanupValues.append($0)
                    defaults?.set($0, forKey: PrivatePaykitService.cleanupPendingKey)
                }
            )
        }
    }
}
