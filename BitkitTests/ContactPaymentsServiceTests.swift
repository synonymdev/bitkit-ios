@testable import Bitkit
import Foundation
import struct Paykit.ContactRecord
import struct Paykit.PaykitProfile
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
            operations.preparePrivateEndpoints = { contactPublicKeys, requireImmediatePublication in
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
        let ownerKey = rawOwnerKey.hasPrefix("pubky") ? rawOwnerKey : "pubky\(rawOwnerKey)"
        let contactKey = "pubky" + String(repeating: "y", count: 52)
        let record = ContactRecord(
            publicKey: contactKey, receiverPaths: [PaykitReceiverPath.wallet], label: "Contact",
            profile: PaykitProfile(displayName: "Contact", imageUri: nil, extraJson: nil),
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )

        for testCase in cases {
            try await withIsolatedDefaultsAsync { defaults in
                let pubkyProfile = PubkyProfileManager()
                pubkyProfile.publicKey = ownerKey
                pubkyProfile.authState = .authenticated
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
        var preparePrivateEndpoints: (([String], Bool) async -> Error?)?

        func makeOperations() -> ContactPaymentsService.Operations {
            ContactPaymentsService.Operations(
                syncPublicEndpoints: { publish in
                    self.calls.append("public:\(publish)")
                    self.publicPublicationValues.append(publish)
                    if self.publicPublicationFailures.contains(self.publicPublicationValues.count) {
                        throw TestError.operationFailed
                    }
                },
                preparePrivateEndpoints: { contactPublicKeys, requiresImmediatePublication in
                    self.onPreparePrivateEndpoints?()
                    self.calls.append("private:publish")
                    self.privatePublications.append(
                        PrivatePublication(
                            contactPublicKeys: contactPublicKeys,
                            requiresImmediatePublication: requiresImmediatePublication
                        )
                    )
                    if let preparePrivateEndpoints = self.preparePrivateEndpoints {
                        return await preparePrivateEndpoints(contactPublicKeys, requiresImmediatePublication)
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
