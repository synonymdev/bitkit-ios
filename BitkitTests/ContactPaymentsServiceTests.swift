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
            XCTAssertTrue(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.calls, ["private:publish", "public:true"])
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
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [false])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
            XCTAssertEqual(operations.publicCleanupValues, [false])
            XCTAssertEqual(operations.privateCleanupValues, [false])
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

    func testFailedPrivateEnableDoesNotPublishPublicEndpointAndRestoresDisabledState() async throws {
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

            XCTAssertEqual(operations.publicPublicationValues, [false])
            XCTAssertFalse(operations.calls.contains("public:true"))
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertTrue(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.publicCleanupValues, [true])
            XCTAssertEqual(operations.privateCleanupValues, [false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
        }
    }

    func testFailedPrivateDisableKeepsContactPaymentsDisabled() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
            let operations = OperationsSpy()
            operations.privateRemovalFailures = [1]

            try await ContactPaymentsService.setEnabled(
                false,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [false])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
            XCTAssertEqual(operations.publicCleanupValues, [false])
            XCTAssertEqual(operations.privateCleanupValues, [true])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    /// General Settings turns contact payments on in a task that outlives the screen, after the first contacts load. A
    /// Pubky sign-out during that load, finished or still running, stops the change before it writes the preference or
    /// publishes anything, and a load that then fails reports nothing.
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
                XCTAssertNoThrow(try result.get(), testCase.name)
                if let runningSignOut {
                    runningSignOut.release.finish()
                    try await runningSignOut.task.value
                }

                let enabled = testCase.signOut == .never
                XCTAssertEqual(operations.calls, enabled ? ["private:publish", "public:true"] : [], testCase.name)
                XCTAssertEqual(operations.privatePublications.map(\.contactPublicKeys), enabled ? [[contactKey]] : [], testCase.name)
                XCTAssertEqual(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), enabled, testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), enabled, testCase.name)
                XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), enabled, testCase.name)
            }
        }
    }

    /// General Settings turns contact payments on in a task that outlives the screen. A Pubky sign-out that starts while
    /// an endpoint publication is in flight stops that enable: a publication that gets its lock after sign-out's removal
    /// writes nothing, and the enable writes no preference or flag and restores nothing. A publication that already held
    /// its lock still finishes, but the enable then clears no cleanup mark the sign-out left for a removal that failed.
    func testContactPaymentsEnableStopsWhenPubkySignsOutDuringPublication() async throws {
        enum HeldPublication {
            case publicBeforeLock, privateBeforeLock, publicHoldingLock
        }
        let cases: [(name: String, held: HeldPublication, calls: [String], writes: [String], keepsFlags: Bool)] = [
            (
                "public publication waiting for its lock", .publicBeforeLock,
                ["private:publish", "public:true"], ["private:published", "private:removed", "public:removal failed"], false
            ),
            (
                "private publication waiting for its lock", .privateBeforeLock,
                ["private:publish"], ["private:removed", "public:removal failed"], false
            ),
            (
                "public publication holding its lock while sign-out fails", .publicHoldingLock,
                ["private:publish", "public:true"], ["private:published", "private:removal failed", "public:published"], true
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
                linkedReceiverPaths: { _ in ([:], nil) },
                receiverPaths: { _ in [PaykitReceiverPath.wallet] },
                receiverPathSelection: { _, _ in
                    PrivateReceiverPathSelection(
                        linkableReceiverPaths: [], publishableReceiverPaths: [PaykitReceiverPath.wallet],
                        cleanupProtectedReceiverPaths: [], error: nil
                    )
                },
                ensureLink: { _, _ in },
                buildEndpoints: { _, _ in [endpoint] },
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

            XCTAssertNoThrow(try result.get(), testCase.name)
            XCTAssertEqual(operations.calls, testCase.calls, testCase.name)
            XCTAssertEqual(writes.entries, testCase.writes, testCase.name)
            XCTAssertEqual(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey), testCase.keepsFlags, testCase.name)
            XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey), testCase.keepsFlags, testCase.name)
            XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), testCase.keepsFlags, testCase.name)
            XCTAssertEqual(operations.publicCleanupValues, [], testCase.name)
            XCTAssertEqual(operations.privateCleanupValues, [], testCase.name)
            XCTAssertTrue(PublicPaykitService.isCleanupPending, testCase.name)
        }
    }

    /// A sign-out that lands after the last session check before a change's writes still stops it: the change checks the
    /// session again right before it writes the preference, the flags or a cleared cleanup mark.
    func testContactPaymentsChangeWritesNothingOnceThePubkySessionChanged() async throws {
        let cases: [(name: String, enabled: Bool, calls: [String])] = [
            ("enable", true, []),
            ("disable", false, ["private:remove", "public:false"]),
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
                    isSessionCurrent: { false }
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
            publicKey: publicKey, receiverPaths: [PaykitReceiverPath.wallet], label: "Contact",
            profile: PaykitProfile(displayName: "Contact", imageUri: nil, extraJson: nil),
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
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
        var preparePrivateEndpoints: (([String], Bool, @escaping ContactPaymentsService.SessionCheck) async -> Error?)?
        var syncPublicEndpoints: ((Bool, @escaping ContactPaymentsService.SessionCheck) async throws -> Void)?

        func makeOperations() -> ContactPaymentsService.Operations {
            ContactPaymentsService.Operations(
                syncPublicEndpoints: { publish, isSessionCurrent in
                    self.calls.append("public:\(publish)")
                    self.publicPublicationValues.append(publish)
                    try await self.syncPublicEndpoints?(publish, isSessionCurrent)
                    if self.publicPublicationFailures.contains(self.publicPublicationValues.count) {
                        throw TestError.operationFailed
                    }
                },
                preparePrivateEndpoints: { contactPublicKeys, requiresImmediatePublication, isSessionCurrent in
                    self.onPreparePrivateEndpoints?()
                    self.calls.append("private:publish")
                    self.privatePublications.append(
                        PrivatePublication(
                            contactPublicKeys: contactPublicKeys,
                            requiresImmediatePublication: requiresImmediatePublication
                        )
                    )
                    if let preparePrivateEndpoints = self.preparePrivateEndpoints {
                        return await preparePrivateEndpoints(contactPublicKeys, requiresImmediatePublication, isSessionCurrent)
                    }
                    return self.privatePublicationFailures.contains(self.privatePublications.count) ? TestError.operationFailed : nil
                },
                removePrivateEndpoints: {
                    self.calls.append("private:remove")
                    self.privateRemovalCount += 1
                    if self.privateRemovalFailures.contains(self.privateRemovalCount) {
                        throw TestError.operationFailed
                    }
                },
                setPublicCleanupPending: { self.publicCleanupValues.append($0) },
                setPrivateCleanupPending: { self.privateCleanupValues.append($0) }
            )
        }
    }
}
