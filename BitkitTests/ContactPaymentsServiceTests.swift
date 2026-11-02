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

    func testConfirmedContactPaymentsReflectOnlyPrivateSharing() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))

            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))

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

    func testEnablingContactPaymentsPublishesOnlyPrivateEndpoints() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            operations.onPreparePrivateEndpoints = {
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
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

            XCTAssertEqual(operations.privateCapabilityValues, [true])
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertEqual(operations.privatePublications[0].contactPublicKeys, ["contact-a", "contact-b"])
            XCTAssertFalse(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.calls, ["capability:true", "private:publish"])
            XCTAssertEqual(operations.privateRemovalCount, 0)
            XCTAssertTrue(operations.publicPublicationValues.isEmpty)
            XCTAssertTrue(operations.publicCleanupValues.isEmpty)
            XCTAssertEqual(operations.privateCleanupValues, [false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.lightningPaymentOptionEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.onchainPaymentOptionEnabledKey))
        }
    }

    func testEnablingContactPaymentsWithoutPrivateCapabilityDoesNotPublish() async throws {
        for sharesPrivateEndpoints in [false, true] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(sharesPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(sharesPrivateEndpoints, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
                let previousPreferences = defaults.dictionaryRepresentation() as NSDictionary
                let operations = OperationsSpy()

                do {
                    try await ContactPaymentsService.setEnabled(
                        true, contactPublicKeys: ["contact-a"], canUsePrivatePayments: false,
                        operations: operations.makeOperations(), defaults: defaults
                    )
                    XCTFail("Private sharing requires private payment access")
                } catch PrivatePaykitError.privateUnavailable {}

                XCTAssertTrue(operations.calls.isEmpty)
                XCTAssertTrue(operations.privateCleanupValues.isEmpty)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, previousPreferences)
                XCTAssertEqual(ContactPaymentsService.isEnabled(defaults: defaults), sharesPrivateEndpoints)
            }
        }
    }

    func testEnablePreservesContactSavedWhileCapabilitySyncIsPending() async throws {
        snapshotAppDefaultsDomain()
        PrivatePaykitService.setContactSharingCleanupPending(false)
        try await withIsolatedDefaultsAsync { defaults in
            let key = "pubky" + String(repeating: "y", count: 52)
            let publicationStarted = expectation(description: "Capability sync is pending")
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let profile = signedInProfile(ownerKey: "owner")
            let contacts = ContactsManager()
            contacts.hasLoaded = true
            let service = PrivatePaykitService()
            await service.setBackgroundWorkPaused(true)
            let operations = OperationsSpy()
            operations.syncPrivateCapability = { _, _ in
                publicationStarted.fulfill()
                for await _ in resume {}
            }
            operations.preparePrivateEndpoints = { keys, immediate, isCurrent in
                await service.prepareSavedContacts(
                    keys, wallet: WalletViewModel(), requireImmediatePublication: immediate, isSessionCurrent: isCurrent
                )
            }
            let enable = Task {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(), defaults: defaults, privatePaymentAccess: { _ in true }
                )
            }
            await fulfillment(of: [publicationStarted], timeout: 2)
            contacts.contacts = [.init(publicKey: key, profile: PubkyProfile.placeholder(publicKey: key))]
            _ = await service.rememberSavedContacts([key], replacing: false)
            await service.scheduleExplicitContactLink(publicKey: key, identity: "owner")
            let retry = await service.pendingMessageDrainRetries[key]
            continuation.finish()
            let applied = try await enable.value
            XCTAssertTrue(applied)
            let known = await service.knownSavedContactKeys
            let retained = await service.pendingMessageDrainRetries[key]
            XCTAssertEqual(known, [key])
            XCTAssertNotNil(retry)
            XCTAssertEqual(retained?.id, retry?.id)
            XCTAssertEqual(retained?.foregroundUntil, retry?.foregroundUntil)
            await service.invalidateContactPreparation()
            await service.setBackgroundWorkPaused(false)
        }
    }

    func testEnableQueuesCurrentContactsWhenMembershipChangesDuringPrivatePreparation() async throws {
        snapshotAppDefaultsDomain()
        PrivatePaykitService.clearDeletedContactCleanupPending()
        let defaults = UserDefaults.standard
        let firstKey = "pubky" + String(repeating: "y", count: 52)
        let secondKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        for removesContact in [false, true] {
            defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
            let profile = signedInProfile(ownerKey: "owner")
            let contacts = ContactsManager()
            contacts.hasLoaded = true
            let initialKeys = removesContact ? [firstKey, secondKey] : [firstKey]
            let currentKeys = removesContact ? [firstKey] : [firstKey, secondKey]
            contacts.contacts = initialKeys.map { .init(publicKey: $0, profile: PubkyProfile.placeholder(publicKey: $0)) }
            let service = PrivatePaykitService()
            await service.setBackgroundWorkPaused(true)
            _ = await service.rememberSavedContacts(initialKeys, replacing: true)
            let preparationStarted = expectation(description: "Private preparation is pending")
            let (resume, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            let operations = OperationsSpy()
            var held = false
            operations.preparePrivateEndpoints = { keys, immediate, isCurrent in
                if !held {
                    held = true
                    preparationStarted.fulfill()
                    for await _ in resume {}
                }
                return await service.prepareSavedContacts(
                    keys, wallet: WalletViewModel(), requireImmediatePublication: immediate, isSessionCurrent: isCurrent
                )
            }
            let enable = Task {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults, privatePaymentAccess: { _ in true }
                )
            }
            await fulfillment(of: [preparationStarted], timeout: 2)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            contacts.contacts = currentKeys.map { .init(publicKey: $0, profile: PubkyProfile.placeholder(publicKey: $0)) }
            _ = await service.rememberSavedContacts(currentKeys, replacing: true)
            await service.scheduleExplicitContactLink(publicKey: firstKey, identity: "owner")
            let retry = await service.pendingMessageDrainRetries[firstKey]
            release.finish()
            let applied = try await enable.value
            await service.retryPendingEndpointReconciliation(wallet: WalletViewModel(), savedPublicKeys: currentKeys)
            let queued = await service.pendingPreparationKeys
            let known = await service.knownSavedContactKeys
            let retainedRetry = await service.pendingMessageDrainRetries[firstKey]
            XCTAssertTrue(applied)
            XCTAssertEqual(queued, Set(currentKeys), "Enabling must queue current membership after superseded preparation")
            XCTAssertEqual(known, Set(currentKeys))
            XCTAssertNotNil(retry)
            XCTAssertEqual(retainedRetry?.id, retry?.id)
            XCTAssertEqual(retainedRetry?.foregroundUntil, retry?.foregroundUntil)
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertEqual(operations.privateRemovalCount, 0)
            await service.invalidateContactPreparation()
            await service.setBackgroundWorkPaused(false)
        }
    }

    func testEnableCancelledAfterCapabilitySyncDoesNotReportApplied() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let contacts = ContactsManager()
            contacts.hasLoaded = true
            let profile = signedInProfile(ownerKey: "owner")
            let publicationStarted = expectation(description: "Capability sync is pending")
            var release: CheckedContinuation<Void, Never>?
            defer { release?.resume() }
            let operations = OperationsSpy()
            operations.syncPrivateCapability = { publish, _ in
                guard publish else { return }
                await withCheckedContinuation { continuation in
                    release = continuation
                    publicationStarted.fulfill()
                }
            }
            let enable = Task {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults, privatePaymentAccess: { _ in true }
                )
            }
            await fulfillment(of: [publicationStarted], timeout: 2)
            enable.cancel()
            let continuation = try XCTUnwrap(release)
            release = nil
            continuation.resume()
            do {
                _ = try await enable.value
                XCTFail("Cancelled enable must not report that the preference was applied")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
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
            XCTAssertEqual(operations.privateCapabilityValues, [true])
            XCTAssertEqual(operations.privateRemovalCount, 0)
            let knownContacts = await service.knownSavedContactKeys
            XCTAssertEqual(knownContacts, [contactPublicKey])
        }
    }

    func testEnableDoesNotRestoreContactDeletedWhileCapabilitySyncIsPending() async throws {
        snapshotAppDefaultsDomain()
        try await withIsolatedDefaultsAsync { defaults in
            let key = "pubky" + String(repeating: "y", count: 52)
            let contacts = ContactsManager()
            contacts.hasLoaded = true
            contacts.contacts = [.init(publicKey: key, profile: PubkyProfile.placeholder(publicKey: key))]
            let service = PrivatePaykitService()
            let operations = OperationsSpy()
            operations.syncPrivateCapability = { _, _ in contacts.contacts = [] }
            operations.preparePrivateEndpoints = { keys, _, isCurrent in
                await service.prepareSavedContacts(keys, wallet: WalletViewModel(), isSessionCurrent: isCurrent)
            }
            let applied = try await ContactPaymentsService.setEnabled(
                true, pubkyProfile: signedInProfile(ownerKey: "owner"), contactsManager: contacts,
                operations: operations.makeOperations(), defaults: defaults, privatePaymentAccess: { _ in true }
            )
            let known = await service.knownSavedContactKeys
            XCTAssertTrue(applied)
            XCTAssertTrue(known.isEmpty)
            await service.invalidateContactPreparation()
        }
    }

    func testPrivateAccessFailurePreservesPreferencesAndAllowsSetupRetry() async throws {
        for failure in [KeychainError.failedToLoad as Error, CancellationError()] {
            try await withIsolatedDefaultsAsync { defaults in
                let profile = signedInProfile(ownerKey: "pubky-current")
                let contactsLoaded = expectation(description: "Contacts loaded after access check")
                let contacts = ContactsManager(contactRecords: { contactsLoaded.fulfill(); return [] })
                let operations = OperationsSpy()
                defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
                defaults.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
                defaults.set(false, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
                let previousPreferences = defaults.dictionaryRepresentation() as NSDictionary

                do {
                    try await ContactPaymentsService.setEnabled(
                        true, pubkyProfile: profile, contactsManager: contacts,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults,
                        privatePaymentAccess: { publicKey in
                            XCTAssertEqual(publicKey, "pubky-current")
                            throw failure
                        }
                    )
                    XCTFail("Setup must surface the access failure")
                } catch {
                    XCTAssertEqual(error is CancellationError, failure is CancellationError)
                    XCTAssertEqual(error is KeychainError, failure is KeychainError)
                }
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, previousPreferences)
                XCTAssertFalse(contacts.hasLoaded)
                XCTAssertTrue(operations.calls.isEmpty)
                XCTAssertTrue(operations.publicCleanupValues.isEmpty)
                XCTAssertTrue(operations.privateCleanupValues.isEmpty)

                operations.onSyncPrivateCapability = { publish in
                    XCTAssertTrue(publish)
                    XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                }
                let applied = try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults,
                    privatePaymentAccess: { _ in true }
                )
                XCTAssertTrue(applied)
                await fulfillment(of: [contactsLoaded], timeout: 2)
                XCTAssertEqual(operations.calls, ["capability:true", "private:publish"])
                XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            }
        }
    }

    func testCancelledSetupDoesNotReadKeysOrPublish() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let profile = signedInProfile(ownerKey: "pubky-current")
            let contacts = ContactsManager(contactRecords: { XCTFail("Cancelled setup must not load contacts"); return [] })
            let operations = OperationsSpy()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(), defaults: defaults,
                    privatePaymentAccess: { _ in XCTFail("Cancelled setup must not read keys"); return true }
                )
            }
            do {
                _ = try await task.value
                XCTFail("Setup must remain cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(operations.calls.isEmpty)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testSetupWithoutPrivateAccessFailsAndDisableDoesNotReadKeys() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let profile = signedInProfile(ownerKey: "pubky-current")
            let contacts = ContactsManager(contactRecords: { XCTFail("Unavailable private setup must not load contacts"); return [] })
            let operations = OperationsSpy()
            do {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults,
                    privatePaymentAccess: { _ in false }
                )
                XCTFail("Private sharing requires private payment access")
            } catch PrivatePaykitError.privateUnavailable {}
            XCTAssertTrue(operations.calls.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))

            let disabled = try await ContactPaymentsService.setEnabled(
                false, pubkyProfile: profile, contactsManager: contacts,
                operations: operations.makeOperations(defaults: defaults), defaults: defaults,
                privatePaymentAccess: { _ in XCTFail("Disabling must not read keys"); throw KeychainError.failedToLoad }
            )
            XCTAssertTrue(disabled)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertTrue(operations.privatePublications.isEmpty)
        }
    }

    func testDisablingContactPaymentsRemovesOnlyPrivateEndpoints() async throws {
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

            XCTAssertEqual(operations.privateCapabilityValues, [false])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.calls, ["private:remove", "capability:false"])
            XCTAssertTrue(operations.publicPublicationValues.isEmpty)
            XCTAssertTrue(operations.publicCleanupValues.isEmpty)
            XCTAssertEqual(operations.privateCleanupValues, [true, false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testPrivateCapabilityFailureWithNoContactsRestoresPreferenceAndRetainsCleanup() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            operations.privateCapabilityFailures = [1, 2]
            do {
                try await ContactPaymentsService.setEnabled(
                    true, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
                XCTFail("Capability sync failure must be reported even with no contacts")
            } catch {
                XCTAssertEqual(error as? TestError, .operationFailed)
            }
            XCTAssertEqual(operations.privateCapabilityValues, [true, false])
            XCTAssertTrue(operations.publicPublicationValues.isEmpty)
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testPrivateCapabilityRollbackRetriesWithoutContactsOrPublicConsent() async throws {
        snapshotAppDefaultsDomain()
        let defaults = UserDefaults.standard
        for privateEnabled in [false, true] {
            defaults.set(privateEnabled, forKey: PrivatePaykitService.publishingEnabledKey)
            defaults.set(privateEnabled, forKey: ContactPaymentsService.confirmedPreferenceKey)
            defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(false, forKey: PublicPaykitService.cleanupPendingKey)
            defaults.set(false, forKey: PrivatePaykitService.cleanupPendingKey)
            let operations = OperationsSpy()
            operations.privateCapabilityFailures = [1, 2]
            do {
                try await ContactPaymentsService.setEnabled(
                    true, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
                XCTFail("Expected capability synchronization and rollback to fail")
            } catch {
                XCTAssertEqual(error as? TestError, .operationFailed)
            }
            XCTAssertEqual(operations.privateCapabilityValues, [true, privateEnabled])
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertTrue(PublicPaykitService.isCleanupPending)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))

            let wallet = WalletViewModel()
            var capabilities: [Bool] = []
            var attempts = 0
            let retry = {
                try await PublicPaykitService.retryPendingEndpointReconciliation(
                    wallet: wallet, isSessionCurrent: { true },
                    syncApp: {
                        attempts += 1
                        if attempts == 1 {
                            throw TestError.operationFailed
                        }
                        capabilities.append(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                    },
                    applyEndpoints: { XCTAssertTrue($0.isEmpty, "Registry repair must not opt into public payments") }
                )
            }
            do {
                try await retry()
                XCTFail("Failed registry repair must remain pending")
            } catch {
                XCTAssertEqual(error as? TestError, .operationFailed)
            }
            XCTAssertTrue(PublicPaykitService.isCleanupPending)
            try await retry()
            XCTAssertEqual(capabilities, [privateEnabled])
            XCTAssertFalse(PublicPaykitService.isCleanupPending)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertEqual(ContactPaymentsService.isEnabled(), privateEnabled)
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
        }
    }

    func testFailedPrivateSetupRestoresDisabledStateWithoutChangingPublicSharing() async throws {
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

            XCTAssertEqual(operations.privateCapabilityValues, [true, false])
            XCTAssertTrue(operations.calls.contains("capability:true"))
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertFalse(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertTrue(operations.publicPublicationValues.isEmpty)
            XCTAssertTrue(operations.publicCleanupValues.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertEqual(operations.privateCleanupValues, [false, true, false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
        }
    }

    func testFailedDisableKeepsContactPaymentsDisabledAndRetriesCleanup() async throws {
        for (privateFails, capabilityFails) in [(true, false), (false, true), (true, true)] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
                let operations = OperationsSpy()
                operations.privateRemovalFailures = privateFails ? [1] : []
                operations.privateCapabilityFailures = capabilityFails ? [1] : []

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

                XCTAssertEqual(operations.privateCapabilityValues, [false])
                XCTAssertEqual(operations.privateRemovalCount, 1)
                XCTAssertTrue(operations.privatePublications.isEmpty)
                XCTAssertEqual(operations.calls, ["private:remove", "capability:false"])
                XCTAssertTrue(operations.publicPublicationValues.isEmpty)
                XCTAssertTrue(operations.publicCleanupValues.isEmpty)
                XCTAssertEqual(operations.privateCleanupValues, [true, true])
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
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

                XCTAssertEqual(operations.privateCapabilityValues, [false, false])
                XCTAssertEqual(operations.privateRemovalCount, 2)
                XCTAssertTrue(operations.privatePublications.isEmpty)
                XCTAssertTrue(operations.publicCleanupValues.isEmpty)
                XCTAssertEqual(operations.privateCleanupValues, [true, true, true, false])
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            }
        }
    }

    func testForegroundReconciliationSkipsBothPhasesOfActiveDisable() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let privateRemovalStarted = expectation(description: "Private removal started")
            let capabilitySyncStarted = expectation(description: "Private capability sync started")
            let (privateRemoval, finishPrivateRemoval) = AsyncStream<Void>.makeStream()
            let (capabilitySync, finishCapabilitySync) = AsyncStream<Void>.makeStream()
            defer {
                finishPrivateRemoval.finish()
                finishCapabilitySync.finish()
            }
            operations.onRemovePrivateEndpoints = {
                privateRemovalStarted.fulfill()
                for await _ in privateRemoval {}
            }
            operations.onSyncPrivateCapability = { _ in
                capabilitySyncStarted.fulfill()
                for await _ in capabilitySync {}
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
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            await ContactPaymentsService.reconcilePendingEndpoints {
                XCTFail("Foreground cleanup must not restart private withdrawal")
            }

            finishPrivateRemoval.finish()
            await fulfillment(of: [capabilitySyncStarted], timeout: 2)
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            await ContactPaymentsService.reconcilePendingEndpoints {
                XCTFail("Foreground cleanup must not duplicate capability sync")
            }

            finishCapabilitySync.finish()
            try await disable.value
            XCTAssertEqual(operations.calls, ["private:remove", "capability:false"])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            var reconciled = false
            await ContactPaymentsService.reconcilePendingEndpoints { reconciled = true }
            XCTAssertTrue(reconciled)
        }
    }

    func testForegroundReconciliationRetainsRegistryRepairDuringDeletionOrCancellation() async {
        snapshotAppDefaultsDomain()
        for interruption in ["deletion", "deletionAfterPrivate", "cancelAfterPrivate"] {
            PublicPaykitService.setCleanupPending(true)
            if interruption == "deletion" {
                await PrivatePaykitService.shared.beginProfileDeletion()
            }
            var registryUpdates = 0
            let reconciliation = Task {
                await ContactPaymentsService.reconcilePendingEndpoints(reconcilePrivate: {
                    if interruption == "deletionAfterPrivate" {
                        await PrivatePaykitService.shared.beginProfileDeletion()
                    }
                    if interruption == "cancelAfterPrivate" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }) {
                    registryUpdates += 1
                    PublicPaykitService.setCleanupPending(false)
                }
            }
            await reconciliation.value
            await PrivatePaykitService.shared.endProfileDeletion()
            XCTAssertEqual(registryUpdates, 0, interruption)
            XCTAssertTrue(PublicPaykitService.isCleanupPending, interruption)

            await ContactPaymentsService.reconcilePendingEndpoints {
                registryUpdates += 1
                PublicPaykitService.setCleanupPending(false)
            }
            XCTAssertEqual(registryUpdates, 1, interruption)
            XCTAssertFalse(PublicPaykitService.isCleanupPending, interruption)
        }
    }

    func testEnablingWaitsForSuccessfulOrFailedDisable() async throws {
        let ownerKey = try useLocalPubkySecretKey()
        for (disableUI, removalFails) in [(false, false), (false, true), (true, false), (true, true)] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
                defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
                let pubkyProfile = signedInProfile(ownerKey: ownerKey)
                let contactsManager = ContactsManager(contactRecords: { [] })
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
                    if disableUI {
                        return try await ContactPaymentsService.disablePaykitUI(
                            pubkyProfile: pubkyProfile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                        )
                    }
                    try await ContactPaymentsService.setEnabled(
                        false, contactPublicKeys: [], canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                    return true
                }
                await fulfillment(of: [removalStarted], timeout: 2)
                if disableUI {
                    XCTAssertFalse(defaults.bool(forKey: PaykitFeatureFlags.uiEnabledKey))
                    XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
                }
                let enable = Task {
                    enableRequested.fulfill()
                    if disableUI {
                        defaults.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
                        let applied = try await ContactPaymentsService.setEnabled(
                            true, pubkyProfile: pubkyProfile, contactsManager: contactsManager,
                            operations: operations.makeOperations(defaults: defaults), defaults: defaults
                        )
                        XCTAssertTrue(applied)
                        return
                    }
                    try await ContactPaymentsService.setEnabled(
                        true, contactPublicKeys: ["contact-a"], canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                }
                await fulfillment(of: [enableRequested], timeout: 2)
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertEqual(operations.calls, disableUI ? ["public:false", "private:remove"] : ["private:remove"])

                finishRemoval.finish()
                switch await disable.result {
                case let .success(applied):
                    XCTAssertEqual(applied, !disableUI)
                    if !disableUI {
                        XCTAssertFalse(removalFails)
                    }
                case let .failure(error):
                    XCTAssertTrue(removalFails)
                    XCTAssertEqual(error as? TestError, .operationFailed)
                }
                try await enable.value
                let cleanupCalls = disableUI ? ["public:false", "private:remove"] : ["private:remove", "capability:false"]
                XCTAssertEqual(operations.calls, cleanupCalls + ["capability:true", "private:publish"])
                XCTAssertTrue(defaults.bool(forKey: PaykitFeatureFlags.uiEnabledKey))
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
            XCTAssertEqual(operations.privateCapabilityValues, [true])
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
                await fulfillment(of: [loadStarted], timeout: 10)

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

                XCTAssertEqual(operations.calls, enabled ? ["capability:true", "private:publish"] : [], testCase.name)
                XCTAssertEqual(operations.privatePublications.map(\.contactPublicKeys), enabled ? [[contactKey]] : [], testCase.name)
                XCTAssertEqual(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), enabled, testCase.name)
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), enabled, testCase.name)
            }
        }
    }

    /// A publication already holding its lock can finish; sign-out must remove it afterward and retain failed cleanup.
    func testContactPaymentsEnableStopsWhenPubkySignsOutDuringPublication() async throws {
        enum HeldPublication {
            case capabilityBeforeLock, privateBeforeLock, capabilityHoldingLock
        }
        let cases: [(name: String, held: HeldPublication, calls: [String], writes: [String], keepsFlags: Bool)] = [
            (
                "capability sync waiting for its lock", .capabilityBeforeLock,
                ["capability:true"], ["private:removed", "public:removal failed"], false
            ),
            (
                "private publication waiting for its lock", .privateBeforeLock,
                ["capability:true", "private:publish"], ["capability:enabled", "private:removed", "public:removal failed"], false
            ),
            (
                "capability sync holding its lock while sign-out fails", .capabilityHoldingLock,
                ["capability:true"], ["private:removal failed", "capability:enabled"], true
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
            operations.syncPrivateCapability = { publish, isSessionCurrent in
                guard publish else { return }
                if held == .capabilityBeforeLock {
                    reachedHeldPoint.fulfill()
                    for await _ in gate {}
                }
                try await PublicPaykitService.withEndpointLock(unlessSessionEnded: isSessionCurrent) {
                    if held == .capabilityHoldingLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    writes.append("capability:enabled")
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

            let privateRemovalFails = held == .capabilityHoldingLock
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
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), testCase.name)
            XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), testCase.keepsFlags, testCase.name)
            XCTAssertTrue(operations.publicCleanupValues.isEmpty, testCase.name)
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
            case privateBeforeLock, capabilityBeforeLock, capabilityHoldingLock
        }
        let cases: [(name: String, held: HeldPublication, writes: [String])] = [
            ("private publication waiting for its lock", .privateBeforeLock, ["capability:enabled", "private:removed", "capability:disabled"]),
            ("capability sync waiting for its lock", .capabilityBeforeLock, ["private:removed", "capability:disabled"]),
            (
                "capability sync holding its lock", .capabilityHoldingLock,
                ["capability:enabled", "private:removed", "capability:disabled"]
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
                operations.syncPrivateCapability = { publish, isChangeCurrent in
                    if publish, held == .capabilityBeforeLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    try await endpoints.writePublic(publish ? "capability:enabled" : "capability:disabled", isChangeCurrent: isChangeCurrent) {
                        if publish, held == .capabilityHoldingLock {
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
                XCTAssertTrue(operations.publicCleanupValues.isEmpty, testCase.name)
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
            case privateBeforeLock, capabilityBeforeLock, capabilityHoldingLock
        }
        let cases: [(name: String, held: HeldRemoval, writes: [String])] = [
            ("private removal waiting for its lock", .privateBeforeLock, ["capability:enabled", "private:published"]),
            (
                "capability removal waiting for its lock", .capabilityBeforeLock,
                ["private:removed", "capability:enabled", "private:published"]
            ),
            (
                "capability removal holding its lock", .capabilityHoldingLock,
                ["private:removed", "capability:disabled", "capability:enabled", "private:published"]
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
                operations.syncPrivateCapability = { publish, isChangeCurrent in
                    if !publish, held == .capabilityBeforeLock {
                        reachedHeldPoint.fulfill()
                        for await _ in gate {}
                    }
                    try await endpoints.writePublic(publish ? "capability:enabled" : "capability:disabled", isChangeCurrent: isChangeCurrent) {
                        if !publish, held == .capabilityHoldingLock {
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
                XCTAssertTrue(operations.publicCleanupValues.isEmpty, testCase.name)
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
            operations.syncPrivateCapability = { publish, isChangeCurrent in
                try await endpoints.writePublic(publish ? "capability:enabled" : "capability:disabled", isChangeCurrent: isChangeCurrent)
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
            XCTAssertEqual(endpoints.entries, ["capability:enabled", "capability:enabled", "private:published"])
            XCTAssertTrue(operations.publicCleanupValues.isEmpty)
            XCTAssertEqual(operations.privateCleanupValues.last, false)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testPublicSharingChangesPreservePrivatePreferences() async throws {
        for privateEnabled in [false, true] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(privateEnabled, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(privateEnabled, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
                let profile = signedInProfile(ownerKey: "owner")
                let operations = OperationsSpy()
                for publicEnabled in [true, false] {
                    let applied = try await ContactPaymentsService.setPublicEnabled(
                        publicEnabled, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                    XCTAssertTrue(applied)
                    XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), publicEnabled)
                    XCTAssertEqual(ContactPaymentsService.isEnabled(defaults: defaults), privateEnabled)
                    XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                }
                XCTAssertEqual(operations.calls, ["public:true", "public:false"])
                XCTAssertTrue(operations.privateCleanupValues.isEmpty)
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            }
        }
    }

    func testPublicSharingFailurePreservesPrivateStateAndRetriesWithdrawal() async throws {
        for enabling in [false, true] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(!enabling, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
                let operations = OperationsSpy()
                operations.publicPublicationFailures = enabling ? [1, 2] : [1]
                let profile = signedInProfile(ownerKey: "owner")
                do {
                    try await ContactPaymentsService.setPublicEnabled(
                        enabling, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                    XCTFail("Failed public publication or withdrawal must be reported")
                } catch {
                    XCTAssertEqual(error as? TestError, .operationFailed)
                }
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertTrue(operations.privateCleanupValues.isEmpty)
                XCTAssertTrue(operations.privateCapabilityValues.isEmpty)
                XCTAssertEqual(operations.privateRemovalCount, 0)

                try await ContactPaymentsService.setPublicEnabled(
                    false, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
            }
        }
    }

    func testPublicSharingHonorsLatestIntentAcrossPublicationLocks() async throws {
        enum HeldOperation { case beforeLock, holdingLock, capabilitySync }
        for held in [HeldOperation.beforeLock, .holdingLock, .capabilitySync] {
            for (olderValue, newerValue) in [(true, false), (false, true), (true, true)] {
                try await withIsolatedDefaultsAsync { defaults in
                    defaults.set(!olderValue, forKey: PublicPaykitService.publishingEnabledKey)
                    let profile = signedInProfile(ownerKey: "owner")
                    let endpoints = LockedEndpointWrites()
                    let operations = OperationsSpy()
                    let reachedHold = expectation(description: "Public sharing reached its held point")
                    let newerRequested = expectation(description: "New public sharing intent requested")
                    let (gate, release) = AsyncStream<Void>.makeStream()
                    defer { release.finish() }
                    var first = true
                    operations.syncPublicEndpoints = { publish, isCurrent in
                        let hold = first
                        first = false
                        if hold, held == .beforeLock {
                            reachedHold.fulfill()
                            for await _ in gate {}
                        }
                        if hold, !publish, held == .capabilitySync {
                            try await endpoints.removePublic(isChangeCurrent: isCurrent) {
                                reachedHold.fulfill()
                                for await _ in gate {}
                            }
                            return
                        }
                        try await endpoints.writePublic(publish ? "public:published" : "public:removed", isChangeCurrent: isCurrent) {
                            if hold, held != .beforeLock {
                                reachedHold.fulfill()
                                for await _ in gate {}
                            }
                        }
                    }
                    let older = Task {
                        try await ContactPaymentsService.setPublicEnabled(
                            olderValue, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                        )
                    }
                    await fulfillment(of: [reachedHold], timeout: 2)
                    let newer = Task {
                        newerRequested.fulfill()
                        return try await ContactPaymentsService.setPublicEnabled(
                            newerValue, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                        )
                    }
                    await fulfillment(of: [newerRequested], timeout: 2)
                    release.finish()
                    let olderApplied = try await older.value
                    let newerApplied = try await newer.value
                    XCTAssertFalse(olderApplied)
                    XCTAssertTrue(newerApplied)
                    XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), newerValue)
                    XCTAssertEqual(endpoints.entries.last, newerValue ? "public:published" : "public:removed")
                    XCTAssertEqual(endpoints.entries.count, held == .beforeLock ? 1 : 2)
                    XCTAssertTrue(operations.privateCapabilityValues.isEmpty)
                    XCTAssertTrue(operations.privatePublications.isEmpty)
                    XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
                }
            }
        }
    }

    func testPublicEnableStopsOnCancellationOrSessionChange() async throws {
        snapshotAppDefaultsDomain()
        for cancel in [false, true] {
            try await withIsolatedDefaultsAsync { defaults in
                let profile = signedInProfile(ownerKey: "owner")
                let operations = OperationsSpy()
                let reachedHold = expectation(description: "Public enable waiting for publication")
                let (gate, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                let endpoints = LockedEndpointWrites()
                operations.syncPublicEndpoints = { publish, isCurrent in
                    if publish {
                        reachedHold.fulfill()
                        for await _ in gate {}
                    }
                    try await endpoints.writePublic(publish ? "public:published" : "public:removed", isChangeCurrent: isCurrent)
                }
                let enable = Task {
                    try await ContactPaymentsService.setPublicEnabled(
                        true, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                }
                await fulfillment(of: [reachedHold], timeout: 2)
                if cancel {
                    enable.cancel()
                } else {
                    try await profile.signOut(performSessionCleanup: {})
                }
                release.finish()
                do {
                    let applied = try await enable.value
                    XCTAssertFalse(cancel)
                    XCTAssertFalse(applied)
                } catch {
                    XCTAssertTrue(cancel)
                    XCTAssertTrue(error is CancellationError)
                    XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
                    XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                }
                XCTAssertEqual(endpoints.entries, cancel ? ["public:published", "public:removed"] : [])
                XCTAssertTrue(operations.privateCapabilityValues.isEmpty)
            }
        }
    }

    func testIndependentSharingIntentsDoNotSupersedeEachOther() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let profile = signedInProfile(ownerKey: "owner")
            let contacts = ContactsManager()
            contacts.hasLoaded = true
            let operations = OperationsSpy()
            let reachedHold = expectation(description: "Private enable syncing capability")
            let publicRequested = expectation(description: "Public enable requested")
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            operations.syncPrivateCapability = { _, _ in
                reachedHold.fulfill()
                for await _ in gate {}
            }
            let privateEnable = Task {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: contacts,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults, privatePaymentAccess: { _ in true }
                )
            }
            await fulfillment(of: [reachedHold], timeout: 2)
            let publicEnable = Task {
                publicRequested.fulfill()
                return try await ContactPaymentsService.setPublicEnabled(
                    true, pubkyProfile: profile, operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [publicRequested], timeout: 2)
            XCTAssertTrue(operations.publicPublicationValues.isEmpty)
            release.finish()
            let privateApplied = try await privateEnable.value
            let publicApplied = try await publicEnable.value
            XCTAssertTrue(privateApplied)
            XCTAssertTrue(publicApplied)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertEqual(operations.privatePublications.first?.contactPublicKeys, [])
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

        func removePublic(isChangeCurrent: @escaping ContactPaymentsService.ChangeCheck, syncApp: () async throws -> Void) async throws {
            try await PublicPaykitService.syncPublishedEndpoints(
                publish: false,
                isSessionCurrent: isChangeCurrent,
                buildEndpoints: { [] },
                syncApp: syncApp,
                applyEndpoints: { _ in self.entries.append("public:removed") }
            )
        }
    }

    private final class OperationsSpy {
        struct PrivatePublication {
            let contactPublicKeys: [String]
            let requiresImmediatePublication: Bool
        }

        var publicPublicationValues: [Bool] = []
        var privateCapabilityValues: [Bool] = []
        var privatePublications: [PrivatePublication] = []
        var privateRemovalCount = 0
        var publicCleanupValues: [Bool] = []
        var privateCleanupValues: [Bool] = []
        var calls: [String] = []
        var publicPublicationFailures: Set<Int> = []
        var privateCapabilityFailures: Set<Int> = []
        var privatePublicationFailures: Set<Int> = []
        var privateRemovalFailures: Set<Int> = []
        var onPreparePrivateEndpoints: (() -> Void)?
        var preparePrivateEndpoints: (([String], Bool, @escaping ContactPaymentsService.ChangeCheck) async -> Error?)?
        var syncPublicEndpoints: ((Bool, @escaping ContactPaymentsService.ChangeCheck) async throws -> Void)?
        var removePrivateEndpoints: ((@escaping ContactPaymentsService.ChangeCheck) async throws -> Void)?
        var onRemovePrivateEndpoints: (() async -> Void)?
        var onSyncPublicEndpoints: ((Bool) async -> Void)?
        var onSyncPrivateCapability: ((Bool) async -> Void)?
        var syncPrivateCapability: ((Bool, @escaping ContactPaymentsService.ChangeCheck) async throws -> Void)?

        func makeOperations(defaults: UserDefaults? = nil) -> ContactPaymentsService.Operations {
            ContactPaymentsService.Operations(
                syncPublicEndpoints: { @MainActor publish, isChangeCurrent in
                    self.calls.append("public:\(publish)")
                    self.publicPublicationValues.append(publish)
                    await self.onSyncPublicEndpoints?(publish)
                    try await self.syncPublicEndpoints?(publish, isChangeCurrent)
                    if self.publicPublicationFailures.contains(self.publicPublicationValues.count) {
                        throw TestError.operationFailed
                    }
                    if publish, !Task.isCancelled, isChangeCurrent() {
                        self.publicCleanupValues.append(false)
                        defaults?.set(false, forKey: PublicPaykitService.cleanupPendingKey)
                    }
                },
                syncPrivateCapability: { enabled, isChangeCurrent in
                    self.calls.append("capability:\(enabled)")
                    self.privateCapabilityValues.append(enabled)
                    await self.onSyncPrivateCapability?(enabled)
                    try await self.syncPrivateCapability?(enabled, isChangeCurrent)
                    if self.privateCapabilityFailures.contains(self.privateCapabilityValues.count) {
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
