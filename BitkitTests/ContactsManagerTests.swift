@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

@MainActor
final class ContactsManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // tearDown used to delete this outright, so a user who had enabled Paykit UI lost the setting.
        snapshotAppDefaults(PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(false, forKey: PaykitFeatureFlags.uiEnabledKey)
    }

    func testImportPersistsPreparedContactThroughDefaultSDKWithoutSession() async throws {
        let keys: [KeychainEntryType] = [.paykitSdkState, .paykitSession]
        let originals = try keys.map { try Keychain.load(key: $0) }
        addTeardownBlock {
            await PaykitSdkService.shared.clearState()
            for (key, value) in zip(keys, originals) {
                if let value {
                    try Keychain.upsert(key: key, data: value)
                } else {
                    try Keychain.delete(key: key)
                }
            }
        }
        await PaykitSdkService.shared.clearState()
        try Keychain.delete(key: .paykitSession)
        // Generated with Paykit rc56's StorageStateEnvelope v1 and postcard::to_allocvec:
        // one public identity initialized at 2026-01-01T00:00:00Z, generation 0, no Noise key or other records.
        let fixture = try XCTUnwrap(Data(base64Encoded:
            "AQEBNDNyc2R1aGN4cHc3NHNud3ljdDg2bTM4YzYzajNwcTh4NHljcWlreGc2NHJvaWs4eXc1eHkAFDIwMjYtMDEtMDFUMDA6MDA6MDBaAAAAAAAAAAAAAAAAAAAAAAA="))
        let snapshot = SdkStateBlobSnapshot(blob: SdkStateBlob(bytes: fixture), revision: "contact-import-fixture")
        try Keychain.upsert(key: .paykitSdkState, data: encodeSdkStateBlobSnapshot(snapshot: snapshot))

        let prepared = makeContact(publicKey: "pubky5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo")
        let manager = ContactsManager()
        try await manager.importContacts(contacts: [prepared])
        let stored = try await PubkyService.contactRecords()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.publicKey, prepared.publicKey)
        XCTAssertEqual(stored.first?.label, prepared.displayName)
        XCTAssertEqual(stored.first?.receiverPaths, [PaykitReceiverPath.wallet])
        XCTAssertEqual(manager.contacts, [prepared])

        _ = try await PubkyService.saveContact(
            publicKey: prepared.publicKey, label: prepared.displayName,
            receiverPaths: [PaykitReceiverPath.wallet, PaykitReceiverPath.server]
        )
        try await ContactsManager().importContacts(contacts: [prepared])
        let persisted = try XCTUnwrap(Keychain.load(key: .paykitSdkState))
        await PaykitSdkService.shared.clearState()
        try Keychain.upsert(key: .paykitSdkState, data: persisted)
        let reloaded = try await PubkyService.contactRecords()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.publicKey, prepared.publicKey)
        XCTAssertEqual(reloaded.first?.label, prepared.displayName)
        XCTAssertEqual(Set(reloaded.first?.receiverPaths ?? []), [PaykitReceiverPath.wallet, PaykitReceiverPath.server])
        XCTAssertNil(try Keychain.load(key: .paykitSession))
    }

    func testImportSavesPreparedContactsWithoutNetworkAndSkipsDuplicates() async throws {
        let manager = ContactsManager()
        let prepared = (0 ..< 62).map { makeContact(publicKey: "pubky-contact-\($0)") }
        var saved: [String] = []
        try await manager.importContacts(contacts: prepared + prepared) { key, label in
            XCTAssertEqual(label, "Alice")
            saved.append(key)
        }

        XCTAssertEqual(saved, prepared.map(\.publicKey))
        XCTAssertEqual(Set(manager.contacts), Set(prepared))
        XCTAssertEqual(manager.contacts.count, 62)
    }

    func testDiscoveryExcludesSelfFollowsBeforeResolvingAndImportingContacts() async throws {
        let ownKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let ownPublicKey = "pubky\(ownKey)"
        let friend = makeContact(publicKey: "pubky5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo")
        let profiles = [ownPublicKey: makeProfile(publicKey: ownPublicKey), friend.publicKey: friend.profile]
        let cases: [([String], [Bitkit.PubkyContact])] = [
            ([ownKey, ownPublicKey, friend.publicKey], [friend]),
            ([ownKey, ownPublicKey], []),
        ]

        for (followKeys, expected) in cases {
            let manager = ContactsManager()
            await manager.discoverRemoteContacts(publicKey: ownKey, fetchContactKeys: { publicKey in
                XCTAssertEqual(publicKey, ownPublicKey)
                return followKeys
            }, resolveProfile: { publicKey in
                XCTAssertFalse(PubkyPublicKeyFormat.matches(publicKey, ownPublicKey))
                return try XCTUnwrap(profiles[publicKey])
            })

            XCTAssertEqual(manager.pendingImportContacts, expected)
            var saved: [String] = []
            try await manager.importContacts(contacts: manager.pendingImportContacts) { publicKey, _ in
                XCTAssertFalse(PubkyPublicKeyFormat.matches(publicKey, ownPublicKey))
                saved.append(publicKey)
            }
            XCTAssertEqual(saved, expected.map(\.publicKey))
            XCTAssertEqual(manager.contacts, expected)
        }
    }

    func testImportPreservesSavedContactsOnFailureAndRetriesMissingContacts() async throws {
        let manager = ContactsManager()
        let alice = makeContact(publicKey: "pubky-alice")
        let bob = makeContact(publicKey: "pubky-bob")
        var saved: [String] = []
        do {
            try await manager.importContacts(contacts: [alice, bob]) { key, _ in
                if key == bob.publicKey {
                    throw CocoaError(.fileWriteUnknown)
                }
                saved.append(key)
            }
            XCTFail("Import should report the failed save")
        } catch {
            XCTAssertEqual(manager.contacts, [alice])
        }

        try await manager.importContacts(contacts: [alice, bob]) { key, _ in saved.append(key) }
        XCTAssertEqual(saved, [alice.publicKey, bob.publicKey])
        XCTAssertEqual(Set(manager.contacts), Set([alice, bob]))
    }

    func testCancelledImportStopsSavingAndDoesNotPublishStaleResults() async throws {
        let manager = ContactsManager()
        let prepared = (0 ..< 3).map { makeContact(publicKey: "pubky-contact-\($0)") }
        var attempted: [String] = []
        do {
            try await manager.importContacts(contacts: prepared) { key, _ in
                attempted.append(key)
                if key == prepared[1].publicKey {
                    throw CancellationError()
                }
            }
            XCTFail("Import should propagate cancellation")
        } catch is CancellationError {
            XCTAssertEqual(attempted, Array(prepared.prefix(2)).map(\.publicKey))
            XCTAssertTrue(manager.contacts.isEmpty)
        }
    }

    func testInitialLoadPreservesUnchangedContactsAfterLocalMutations() async throws {
        for deletesContact in [true, false] {
            let first = contactRecord(key: "pubky" + String(repeating: "y", count: 52), name: "First")
            let second = contactRecord(key: "pubky" + String(repeating: "z", count: 52), name: "Second")
            let added = contactRecord(key: "pubky" + String(repeating: "r", count: 52), name: "Added")
            let source = SuspendedContactRecords(records: [first, second])
            let manager = ContactsManager(contactRecords: { await source.load() })
            let load = Task { try await manager.loadContacts(for: "owner") }
            while await !(source.isPaused) {
                await Task.yield()
            }
            let expected: [ContactRecord]
            if deletesContact {
                manager.contacts.removeAll { $0.publicKey == second.publicKey }
                expected = [first]
            } else {
                manager.contacts.append(makeContact(publicKey: added.publicKey))
                expected = [first, second, added]
            }
            await source.resume(with: expected)
            try await load.value
            XCTAssertEqual(Set(manager.contacts.map(\.publicKey)), Set(expected.map(\.publicKey)))
            XCTAssertTrue(manager.hasLoaded)
            XCTAssertFalse(manager.isLoading)
        }
    }

    func testResetStopsAnInvalidatedContactLoad() async throws {
        let record = contactRecord(key: "pubky" + String(repeating: "y", count: 52), name: "Contact")
        let source = SuspendedContactRecords(records: [record])
        let manager = ContactsManager(contactRecords: { await source.load() })
        let load = Task { try await manager.loadContacts(for: "owner") }
        while await !(source.isPaused) {
            await Task.yield()
        }
        manager.reset()
        await source.resume(with: [record])
        try await load.value
        XCTAssertTrue(manager.contacts.isEmpty)
        XCTAssertFalse(manager.hasLoaded)
        XCTAssertFalse(manager.isLoading)
    }

    /// General Settings used to await `loadContactsIfNeeded` in its `.task`, so leaving mid-load surfaced the cancellation
    /// as an error toast. Another caller still finishes the load whichever screen's load it waited on is cancelled. The
    /// Contacts screen's cancelled load reports no error, also when its record read throws once cancelled, as a read
    /// waiting for the SDK lock does.
    func testLoadContactsIfNeededFinishesAfterTheLoadItWaitedOnIsCancelled() async throws {
        let cases: [(
            name: String,
            cancelledLoadThrows: Bool,
            recordReadThrowsOnceCancelled: Bool,
            cancelledLoad: @MainActor (ContactsManager) async throws -> Void
        )] = [
            ("another loadContactsIfNeeded", true, false, { try await $0.loadContactsIfNeeded(for: "owner") }),
            ("the Contacts screen's loadContacts", false, false, { try await $0.loadContacts(for: "owner") }),
            ("the Contacts screen's loadContacts, record read throws", false, true, { try await $0.loadContacts(for: "owner") }),
        ]
        for testCase in cases {
            let record = contactRecord(key: "pubky" + String(repeating: "y", count: 52), name: "Contact")
            let source = SuspendedContactRecords(records: [record])
            let recordReadThrowsOnceCancelled = testCase.recordReadThrowsOnceCancelled
            let manager = ContactsManager(contactRecords: {
                let records = await source.load()
                if recordReadThrowsOnceCancelled {
                    try Task.checkCancellation()
                }
                return records
            })
            let cancelledLoad = Task { try await testCase.cancelledLoad(manager) }
            while await !(source.isPaused) {
                await Task.yield()
            }
            let enable = Task { try await manager.loadContactsIfNeeded(for: "owner") }
            await Task.yield()
            cancelledLoad.cancel()
            await source.resume(with: [record])

            let cancelledResult = await cancelledLoad.result
            if testCase.cancelledLoadThrows {
                XCTAssertThrowsError(try cancelledResult.get(), testCase.name) {
                    XCTAssertTrue($0 is CancellationError, "\(testCase.name): expected cancellation, got \($0)")
                }
            } else {
                XCTAssertNoThrow(try cancelledResult.get(), testCase.name)
            }
            let enableResult = await enable.result
            XCTAssertNoThrow(try enableResult.get(), testCase.name)
            XCTAssertTrue(manager.hasLoaded, testCase.name)
            XCTAssertEqual(manager.contacts.map(\.publicKey), [record.publicKey], testCase.name)
            XCTAssertNil(manager.loadErrorMessage, testCase.name)
            XCTAssertFalse(manager.isLoading, testCase.name)
        }
    }

    private func contactRecord(key: String, name: String) -> ContactRecord {
        ContactRecord(
            publicKey: key, receiverPaths: [PaykitReceiverPath.wallet], label: name,
            profile: PaykitProfile(displayName: name, imageUri: nil, extraJson: nil),
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
    }

    private func unprofiledRecord(key: String, label: String?) -> ContactRecord {
        ContactRecord(
            publicKey: key, receiverPaths: [PaykitReceiverPath.wallet], label: label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
    }

    func testPubkyPublicKeyFormatNormalizesPrefixedAndUnprefixedKeys() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let prefixedKey = "pubky\(rawKey)"

        XCTAssertEqual(PubkyPublicKeyFormat.normalized(rawKey), prefixedKey)
        XCTAssertEqual(PubkyPublicKeyFormat.normalized(prefixedKey), prefixedKey)
    }

    func testPubkyPublicKeyFormatRejectsInvalidLengthAndCharacters() {
        XCTAssertNil(PubkyPublicKeyFormat.normalized("pubkyshort"))
        XCTAssertNil(PubkyPublicKeyFormat.normalized("pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5x0"))
    }

    func testPubkyPublicKeyFormatMatchesEquivalentRepresentations() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let prefixedKey = "pubky\(rawKey)"

        XCTAssertTrue(PubkyPublicKeyFormat.matches(rawKey, prefixedKey))
        XCTAssertFalse(PubkyPublicKeyFormat.matches(prefixedKey, "pubkyinvalid"))
    }

    func testPubkyPublicKeyFormatDisplaysRawTruncatedKey() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated(rawKey), "3rsd...w5xg")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pubky\(rawKey)"), "3rsd...w5xg")
    }

    func testActivityContactResolvesLightningContactKey() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let contact = makeContact(publicKey: "pubky\(rawKey)")
        let activity = Activity.lightning(
            LightningActivity(
                walletId: WalletScope.default,
                id: "test-lightning-contact",
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 10,
                invoice: "lnbc...",
                message: "",
                timestamp: 0,
                preimage: nil,
                contact: rawKey,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        XCTAssertEqual(activity.contact(in: [contact])?.publicKey, contact.publicKey)
    }

    func testActivityContactResolvesBoostingOnchainContactKey() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let contact = makeContact(publicKey: "pubky\(rawKey)")
        let activity = Activity.onchain(
            OnchainActivity(
                walletId: WalletScope.default,
                id: "test-onchain-boosting-contact",
                txType: .sent,
                txId: "txid",
                value: 1000,
                fee: 10,
                feeRate: 1,
                address: "bcrt1...",
                confirmed: false,
                timestamp: 0,
                isBoosted: true,
                boostTxIds: [],
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                contact: contact.publicKey,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        XCTAssertEqual(activity.contact(in: [contact])?.publicKey, contact.publicKey)
    }

    func testActivityDetectsReplacedSentTransaction() {
        let replacedTxId = "replaced_tx_id"
        let activity = Activity.onchain(
            OnchainActivity(
                walletId: WalletScope.default,
                id: replacedTxId,
                txType: .sent,
                txId: replacedTxId,
                value: 1000,
                fee: 10,
                feeRate: 1,
                address: "bcrt1...",
                confirmed: false,
                timestamp: 0,
                isBoosted: false,
                boostTxIds: [],
                isTransfer: false,
                doesExist: false,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                contact: nil,
                createdAt: nil,
                updatedAt: nil,
                seenAt: nil
            )
        )

        XCTAssertTrue(activity.isReplacedSentTransaction(txIdsInBoostTxIds: [replacedTxId]))
        XCTAssertFalse(activity.isReplacedSentTransaction(txIdsInBoostTxIds: ["other_tx_id"]))
    }

    func testResolveAddContactValidationReturnsEmptyForBlankInput() {
        XCTAssertEqual(resolveAddContactValidation(input: "   ", ownPublicKey: nil), .empty)
    }

    func testResolveAddContactValidationReturnsInvalidKeyForBadInput() {
        XCTAssertEqual(
            resolveAddContactValidation(input: "pubkyinvalid", ownPublicKey: nil),
            .invalidKey
        )
    }

    func testResolveAddContactValidationReturnsOwnKeyForSelf() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let ownPublicKey = "pubky\(rawKey)"

        XCTAssertEqual(
            resolveAddContactValidation(input: rawKey, ownPublicKey: ownPublicKey),
            .ownKey
        )
    }

    func testResolveAddContactValidationReturnsExistingContactForDuplicate() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let publicKey = "pubky\(rawKey)"

        XCTAssertEqual(
            resolveAddContactValidation(
                input: rawKey,
                ownPublicKey: nil,
                existingContacts: [makeContact(publicKey: publicKey)]
            ),
            .existingContact
        )
    }

    func testResolveAddContactValidationReturnsNormalizedKeyForValidInput() {
        let rawKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(
            resolveAddContactValidation(input: rawKey, ownPublicKey: nil),
            .valid(normalizedKey: "pubky\(rawKey)")
        )
    }

    func testClearPendingImportOnlyClearsTemporaryImportState() {
        let manager = ContactsManager()
        let profile = makeProfile(publicKey: "pubky_profile")
        let contact = makeContact(publicKey: "pubky_contact")

        manager.contacts = [contact]
        manager.hasLoaded = true
        manager.loadErrorMessage = "still here"
        manager.shouldOpenAddContactSheet = true
        manager.pendingImportProfile = profile
        manager.pendingImportContacts = [contact]

        manager.clearPendingImport()

        XCTAssertEqual(manager.contacts, [contact])
        XCTAssertTrue(manager.hasLoaded)
        XCTAssertEqual(manager.loadErrorMessage, "still here")
        XCTAssertTrue(manager.shouldOpenAddContactSheet)
        XCTAssertNil(manager.pendingImportProfile)
        XCTAssertTrue(manager.pendingImportContacts.isEmpty)
        XCTAssertFalse(manager.hasPendingImport)
    }

    func testHasPendingImportRequiresProfileAndContacts() {
        let manager = ContactsManager()

        manager.pendingImportProfile = makeProfile(publicKey: "pubky_profile")
        XCTAssertFalse(manager.hasPendingImport)

        manager.pendingImportContacts = [makeContact(publicKey: "pubky_contact")]
        XCTAssertTrue(manager.hasPendingImport)
    }

    func testIsMissingContactsDataErrorRecognizesMissingCocoaFileError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileNoSuchFile.rawValue)

        XCTAssertTrue(ContactsManager.isMissingContactsDataError(error))
    }

    func testIsMissingContactsDataErrorRecognizesUnderlyingMissingFileError() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoSuchFile.rawValue)
        let wrapped = NSError(domain: "BitkitTests", code: 99, userInfo: [NSUnderlyingErrorKey: underlying])

        XCTAssertTrue(ContactsManager.isMissingContactsDataError(wrapped))
    }

    func testIsMissingContactsDataErrorRecognizesWrappedAppErrorNotFoundMessage() {
        let error = AppError(message: "App Error", debugMessage: "Fetch failed: 404 Not Found")

        XCTAssertTrue(ContactsManager.isMissingContactsDataError(error))
    }

    func testIsMissingContactsDataErrorRecognizesPubkyProfileNotFoundIdentifier() {
        let error = AppError(message: "App Error", debugMessage: "BitkitCore.PubkyError.ProfileNotFound")

        XCTAssertTrue(ContactsManager.isMissingContactsDataError(error))
    }

    func testIsMissingContactsDataErrorDoesNotTreatGenericNotFoundAsEmptyContacts() {
        let error = AppError(message: "App Error", debugMessage: "Resolution failed: relay host not found")

        XCTAssertFalse(ContactsManager.isMissingContactsDataError(error))
    }

    func testIsMissingContactsDataErrorRecognizesProfileNotFound() {
        XCTAssertTrue(ContactsManager.isMissingContactsDataError(PubkyServiceError.profileNotFound))
    }

    func testIsMissingContactsDataErrorRejectsNonMissingErrors() {
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadCorruptFile.rawValue)

        XCTAssertFalse(ContactsManager.isMissingContactsDataError(error))
    }

    func testContactProfileLookupDoesNotRetryMissingProfile() async throws {
        for outcome: Result<Bitkit.PubkyProfile?, Error> in [.success(nil), .failure(PubkyServiceError.profileNotFound)] {
            let stub = ContactProfileFetchStub([outcome, .success(makeProfile(publicKey: contactProfileKey))])

            do {
                _ = try await ContactsManager.resolveContactProfile(
                    publicKey: contactProfileKey,
                    retryTransient: true,
                    fetchRemoteProfile: { try await stub.fetch($0) }
                )
                XCTFail("Expected a missing profile to throw")
            } catch PubkyServiceError.profileNotFound {
                // Expected.
            }

            let attempts = await stub.attempts
            XCTAssertEqual(attempts, 1)
        }
    }

    func testBulkContactProfileLookupDoesNotRetryTransportError() async throws {
        let stub = ContactProfileFetchStub([.failure(profileTransportError), .success(makeProfile(publicKey: contactProfileKey))])

        // Bulk and screen lookups leave retryTransient out, so this pins its default.
        let profile = try await ContactsManager.resolveContactProfile(
            publicKey: contactProfileKey,
            includePlaceholder: true,
            fetchRemoteProfile: { try await stub.fetch($0) }
        )

        XCTAssertEqual(profile.name, Bitkit.PubkyProfile.placeholder(publicKey: contactProfileKey).name)
        let attempts = await stub.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testUserInitiatedContactProfileLookupRetriesATransportErrorOnlyOnce() async {
        let placeholderName = Bitkit.PubkyProfile.placeholder(publicKey: contactProfileKey).name
        let found: Result<Bitkit.PubkyProfile?, Error> = .success(makeProfile(publicKey: contactProfileKey))
        let cases: [(name: String, outcomes: [Result<Bitkit.PubkyProfile?, Error>], expectedName: String)] = [
            ("user-initiated lookup retries once", [.failure(profileTransportError), found], "Alice"),
            ("user-initiated lookup falls back to the placeholder after one retry", [.failure(profileTransportError)], placeholderName),
        ]
        for testCase in cases {
            let stub = ContactProfileFetchStub(testCase.outcomes)

            let profile = try? await ContactsManager.resolveContactProfile(
                publicKey: contactProfileKey,
                includePlaceholder: true,
                retryTransient: true,
                fetchRemoteProfile: { try await stub.fetch($0) }
            )

            XCTAssertEqual(profile?.name, testCase.expectedName, testCase.name)
            let attempts = await stub.attempts
            XCTAssertEqual(attempts, 2, testCase.name)
        }
    }

    func testContactProfileRetryStopsWhenCancelledDuringBackoff() async {
        let stub = ContactProfileFetchStub([.failure(profileTransportError), .success(makeProfile(publicKey: contactProfileKey))])

        let lookup = Task {
            try await ContactsManager.resolveContactProfile(
                publicKey: contactProfileKey,
                includePlaceholder: true,
                retryTransient: true,
                fetchRemoteProfile: { publicKey in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await stub.fetch(publicKey)
                }
            )
        }

        let result = await lookup.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "Expected cancellation, got \($0)") }
        let attempts = await stub.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testLoadPublishesSavedContactsBeforeTheirProfilesResolve() async throws {
        let manager = ContactsManager()
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        await lookups.hold()
        let stored = contactRecord(key: unresolvedFollowKey, name: "Bob")
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only"), stored]

        let loadReturned = expectation(description: "Load returned while the profile lookup was still running")
        let load = Task {
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
            loadReturned.fulfill()
        }
        await fulfillment(of: [loadReturned], timeout: 2)

        XCTAssertTrue(manager.hasLoaded)
        XCTAssertFalse(manager.isLoading)
        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Label only", "Bob"])

        await lookups.release()
        try await load.value
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Alice", "Bob"])
        let fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys, [contactProfileKey], "A stored profile is not looked up again")
    }

    func testReloadShowsProfilesResolvedEarlierThisSessionWhenItsLookupsFail() async throws {
        let manager = ContactsManager()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        let resolving = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await resolving.fetch($0) })
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"])

        let failing = HeldProfileLookups(profiles: [:])
        await failing.hold()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await failing.fetch($0) })
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"], "A reload starts from the profile resolved earlier")

        await failing.release()
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"], "A failed lookup leaves the row as it is")
        XCTAssertTrue(manager.hasLoaded)
        XCTAssertNil(manager.loadErrorMessage)
    }

    func testResolvedProfilesAreForgottenOnResetAndForAnotherOwner() async throws {
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        let resolving = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        let failing = HeldProfileLookups(profiles: [:])
        let manager = ContactsManager()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await resolving.fetch($0) })
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"])

        try await manager.loadContacts(for: "another-owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await failing.fetch($0) })
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "Another owner's load must not show the first owner's profiles")

        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await resolving.fetch($0) })
        await manager.waitForProfileRefreshForTesting()
        manager.reset()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await failing.fetch($0) })
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "Reset forgets the profiles resolved before it")
    }

    func testProfileRefreshStartedBeforeResetIsIgnored() async throws {
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        let held = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        await held.hold()
        let failing = HeldProfileLookups(profiles: [:])
        let manager = ContactsManager()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await held.fetch($0) })
        while await held.heldCount < 1 {
            await Task.yield()
        }

        manager.reset()
        try await manager.loadContacts(for: "next-owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await failing.fetch($0) })
        await held.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "A refresh from before the reset must not update rows")

        try await manager.loadContacts(for: "next-owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await failing.fetch($0) })
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "A refresh from before the reset must not seed resolved profiles")
    }

    func testProfileRefreshDoesNotReportASavedContactsChange() async throws {
        let manager = ContactsManager()
        var changes: [Set<String>] = []
        let subscription = manager.savedContactsChangedPublisher.sink { changes.append(Set($0.map(\.publicKey))) }
        defer { subscription.cancel() }
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice", unresolvedFollowKey: "Bob"])
        let records = [unprofiledRecord(key: contactProfileKey, label: nil), unprofiledRecord(key: unresolvedFollowKey, label: nil)]

        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        await manager.waitForProfileRefreshForTesting()

        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Alice", "Bob"])
        XCTAssertEqual(changes, [[contactProfileKey, unresolvedFollowKey]], "Only the load itself may report a change")

        let addedKey = "pubky" + String(repeating: "r", count: 52)
        manager.contacts.append(makeContact(publicKey: addedKey))
        XCTAssertEqual(changes.last, [contactProfileKey, unresolvedFollowKey, addedKey])
    }

    /// Each announcement starts a private Paykit walk over every saved contact under the publication lock, so a Contacts
    /// visit that announced its unchanged list queued a full walk that a later Delete Profile waited behind.
    func testSavedContactsChangeIsAnnouncedOnlyWhenTheSavedKeysChange() async throws {
        let manager = ContactsManager()
        var changes: [Set<String>] = []
        let subscription = manager.savedContactsChangedPublisher.sink { changes.append(Set($0.map(\.publicKey))) }
        defer { subscription.cancel() }
        let addedKey = "pubky" + String(repeating: "r", count: 52)
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice", unresolvedFollowKey: "Bob", addedKey: "Carol"])
        let first = unprofiledRecord(key: contactProfileKey, label: "Label only")
        let second = unprofiledRecord(key: unresolvedFollowKey, label: nil)
        let added = unprofiledRecord(key: addedKey, label: nil)
        let load: @MainActor ([ContactRecord]) async throws -> Void = { records in
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
            await manager.waitForProfileRefreshForTesting()
        }

        try await load([first, second])
        try await load([first, second])
        try await load([second, first])
        XCTAssertEqual(changes, [[contactProfileKey, unresolvedFollowKey]], "Reloads and profile refreshes with the same keys announce nothing")

        try await load([first, second, added])
        XCTAssertEqual(changes.count, 2, "Adding a key announces once")
        XCTAssertEqual(changes.last, [contactProfileKey, unresolvedFollowKey, addedKey])

        try await load([first, added])
        XCTAssertEqual(changes.count, 3, "Removing a key announces once")
        XCTAssertEqual(changes.last, [contactProfileKey, addedKey])

        manager.reset()
        XCTAssertEqual(changes.last, [], "A reset empties the saved contacts")
        try await load([first, added])
        XCTAssertEqual(changes.count, 5, "The first load after a reset announces even the keys announced before it")
        XCTAssertEqual(changes.last, [contactProfileKey, addedKey])

        try await manager.loadContacts(
            for: "another-owner",
            fetchContactRecords: { [first, added] },
            fetchRemoteProfile: { try await lookups.fetch($0) }
        )
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(changes.count, 6, "Another owner's first load announces even the same keys")
    }

    func testImportAnnouncesTheSavedContactsChangeOnce() async throws {
        let manager = ContactsManager()
        var changes: [Set<String>] = []
        let subscription = manager.savedContactsChangedPublisher.sink { changes.append(Set($0.map(\.publicKey))) }
        defer { subscription.cancel() }
        let saved = contactRecord(key: contactProfileKey, name: "Saved")
        try await manager.loadContacts(for: "owner", fetchContactRecords: { [saved] }, fetchRemoteProfile: { _ in nil })
        XCTAssertEqual(changes.count, 1)

        let imported = ["e", "j", "k"].map { makeContact(publicKey: "pubky" + String(repeating: $0, count: 52)) }
        try await manager.importContacts(contacts: imported) { _, _ in }
        XCTAssertEqual(changes.count, 2, "An import announces its new contacts once")
        XCTAssertEqual(changes.last, Set([contactProfileKey] + imported.map(\.publicKey)))

        try await manager.importContacts(contacts: imported) { _, _ in }
        XCTAssertEqual(changes.count, 2, "An import that adds nothing announces nothing")
    }

    func testReloadThatPublishesNothingLeavesTheRunningProfileRefreshToFinish() async throws {
        let manager = ContactsManager()
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        await lookups.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        while await lookups.heldCount < 1 {
            await Task.yield()
        }

        let fetchStarted = expectation(description: "Reload started reading the saved records")
        let cancelledReload = Task {
            try await manager.loadContacts(
                for: "owner",
                fetchContactRecords: {
                    fetchStarted.fulfill()
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return records
                },
                fetchRemoteProfile: { try await lookups.fetch($0) }
            )
        }
        await fulfillment(of: [fetchStarted], timeout: 2)
        cancelledReload.cancel()
        _ = await cancelledReload.result
        do {
            try await manager.loadContacts(
                for: "owner",
                fetchContactRecords: { throw PubkyServiceError.sessionNotActive },
                fetchRemoteProfile: { try await lookups.fetch($0) }
            )
            XCTFail("Expected the failing reload to throw")
        } catch {}

        await lookups.release()
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"], "A reload that publishes nothing must not stop the refresh")
    }

    func testReloadKeepsARunningProfileRefreshThatCoversItsContacts() async throws {
        let manager = ContactsManager()
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        await lookups.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        while await lookups.heldCount < 1 {
            await Task.yield()
        }

        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        await lookups.release()
        await manager.waitForProfileRefreshForTesting()

        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"])
        let fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys, [contactProfileKey], "Reopening Contacts must not look the same contact up again")
    }

    /// Contacts used to look every saved contact up again on each load, so returning from a contact's screen re-resolved
    /// the whole list. A contact still without a resolved profile is looked up on every load.
    func testReloadLooksUpOnlyContactsWithoutAProfileResolvedInTheLastTenMinutes() async throws {
        let clock = TestClock()
        let manager = ContactsManager(currentDate: { clock.now() })
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only"), unprofiledRecord(key: unresolvedFollowKey, label: "No profile")]
        let load: @MainActor () async throws -> Void = {
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
            await manager.waitForProfileRefreshForTesting()
        }
        let lookupCounts: () async -> [String: Int] = {
            await lookups.fetchedKeys.reduce(into: [:]) { counts, key in counts[key, default: 0] += 1 }
        }

        try await load()
        var counts = await lookupCounts()
        XCTAssertEqual(counts, [contactProfileKey: 1, unresolvedFollowKey: 1])

        clock.advance(by: ContactsManager.contactProfileFreshness - 1)
        try await load()
        counts = await lookupCounts()
        XCTAssertEqual(counts, [contactProfileKey: 1, unresolvedFollowKey: 2], "Only the contact without a resolved profile is looked up again")
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice", "No profile"])

        clock.advance(by: 1)
        try await load()
        counts = await lookupCounts()
        XCTAssertEqual(counts, [contactProfileKey: 2, unresolvedFollowKey: 3], "A profile resolved ten minutes ago is looked up again")
    }

    /// Each resolved profile used to copy, sort and publish the whole list, 54 times per refresh of 61 contacts, even when
    /// the row already showed that profile.
    func testRefreshPublishesNothingForProfilesTheRowsAlreadyShow() async throws {
        let clock = TestClock()
        let manager = ContactsManager(currentDate: { clock.now() })
        let keys = ["e", "j", "k", "m", "c"].map { "pubky" + String(repeating: $0, count: 52) }
        let lookups = HeldProfileLookups(profiles: Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, "Name \($0)") }))
        let records = keys.map { unprofiledRecord(key: $0, label: nil) }
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(manager.contacts.map(\.displayName), (0 ..< 5).map { "Name \($0)" })

        clock.advance(by: ContactsManager.contactProfileFreshness)
        var publishes = 0
        let subscription = manager.$contacts.dropFirst().sink { _ in publishes += 1 }
        defer { subscription.cancel() }
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        await manager.waitForProfileRefreshForTesting()

        let fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys.count, 10, "Every profile was looked up again once ten minutes passed")
        XCTAssertEqual(publishes, 1, "Only the load publishes; lookups that find what the rows already show publish nothing")
    }

    func testRefreshAppliesManyResultsInFewPublishesAndEndsWithTheWholeListSorted() async throws {
        let manager = ContactsManager()
        let alphabet = Array("ybndrfg8ejkmcpqxot1uwisza345h769")
        let keys = (0 ..< 20).map { "pubky" + String(repeating: "q", count: 51) + String(alphabet[$0]) }
        let names = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, String(format: "Name %02d", 19 - $0)) })
        let lookups = HeldProfileLookups(profiles: names)
        await lookups.hold()
        let records = keys.enumerated().map { unprofiledRecord(key: $1, label: String(format: "Label %02d", $0)) }
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        while await lookups.heldCount < keys.count {
            await Task.yield()
        }

        var publishes = 0
        let subscription = manager.$contacts.dropFirst().sink { _ in publishes += 1 }
        defer { subscription.cancel() }
        await lookups.release()
        await manager.waitForProfileRefreshForTesting()

        XCTAssertLessThanOrEqual(publishes, 3, "20 resolved profiles are applied in a few batches, not one publish each")
        XCTAssertGreaterThanOrEqual(publishes, 1)
        XCTAssertEqual(manager.contacts.map(\.displayName), (0 ..< 20).map { String(format: "Name %02d", $0) })
    }

    func testBatchOvertakenByAResetIsDropped() async throws {
        let manager = ContactsManager()
        let heldKey = "pubky" + String(repeating: "r", count: 52)
        let lookups = PartlyHeldProfileLookups(
            profiles: [contactProfileKey: "Alice", unresolvedFollowKey: "Bob", heldKey: "Carol"],
            holding: [heldKey]
        )
        let records = [
            unprofiledRecord(key: contactProfileKey, label: "Label A"),
            unprofiledRecord(key: unresolvedFollowKey, label: "Label B"),
            unprofiledRecord(key: heldKey, label: "Label C"),
        ]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        try await waitUntil { manager.batchedProfileCountForTesting == 2 }
        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Label A", "Label B", "Label C"], "The two profiles wait for their batch")

        var published: [Set<String>] = []
        let subscription = manager.$contacts.dropFirst().sink { published.append(Set($0.map(\.displayName))) }
        defer { subscription.cancel() }
        manager.reset()
        let failing = HeldProfileLookups(profiles: [:])
        try await manager.loadContacts(for: "next-owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await failing.fetch($0) })
        try await Task.sleep(for: ContactsManager.contactRefreshBatchWindow * 2)

        XCTAssertFalse(published.contains { $0.contains("Alice") || $0.contains("Bob") }, "A batch from before the reset must never publish")
        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Label A", "Label B", "Label C"])
        await lookups.release()
        await manager.waitForProfileRefreshForTesting()
        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Label A", "Label B", "Label C"])
    }

    func testContactScreenGetsAProfileHeldForTheNextBatchAtOnce() async throws {
        let manager = ContactsManager()
        let heldKey = "pubky" + String(repeating: "r", count: 52)
        let lookups = PartlyHeldProfileLookups(publishedProfiles: [publishedContactProfile], holding: [heldKey])
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only"), unprofiledRecord(key: heldKey, label: "Held")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
        try await waitUntil { manager.batchedProfileCountForTesting == 1 }
        XCTAssertEqual(manager.contacts.first { $0.publicKey == contactProfileKey }?.displayName, "Label only")

        let interactive = ContactProfileFetchStub([.failure(profileTransportError)])
        await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }

        let row = manager.contacts.first { $0.publicKey == contactProfileKey }?.profile
        XCTAssertEqual(row?.name, "Alice", "The screen gets the profile its batch holds without waiting for the batch")
        XCTAssertEqual(row?.bio, "Hello", "An edit made now keeps the bio the refresh found")
        let attempts = await interactive.attempts
        XCTAssertEqual(attempts, 0, "A profile the refresh already found is not looked up again")
        await lookups.release()
        await manager.waitForProfileRefreshForTesting()
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the condition")
                return
            }
            await Task.yield()
        }
    }

    /// Like `waitUntil(timeout:_:)`, for a condition that may read an actor, failing with what it waited for.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting until \(description)", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    func testResetForgetsResolvedProfilesSoTheNextLoadLooksThemUpAgain() async throws {
        let clock = TestClock()
        let manager = ContactsManager(currentDate: { clock.now() })
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        let load: @MainActor (String) async throws -> Void = { owner in
            try await manager.loadContacts(for: owner, fetchContactRecords: { records }, fetchRemoteProfile: { try await lookups.fetch($0) })
            await manager.waitForProfileRefreshForTesting()
        }

        try await load("owner")
        try await load("owner")
        var fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys, [contactProfileKey], "A profile resolved moments ago is not looked up again")

        manager.reset()
        try await load("owner")
        fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys.count, 2, "A reset, as on sign-out, forgets the profiles resolved before it")

        try await load("another-owner")
        fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys.count, 3, "Another owner's load does not use the profiles resolved for the first owner")
    }

    func testOnlyALabelOnlyContactIsLookedUpOnTheInteractiveLaneAndOnlyOnce() async throws {
        let labelOnly = Bitkit.PubkyProfile.forDisplay(publicKey: contactProfileKey, name: "Label only", imageUrl: nil)
        let cases: [(name: String, outcome: Result<Bitkit.PubkyProfile?, Error>, row: Bitkit.PubkyProfile, names: [String])] = [
            ("lookup finds the profile", .success(publishedContactProfile), publishedContactProfile, ["Alice", "Bob"]),
            ("lookup fails", .failure(profileTransportError), labelOnly, ["Bob", "Label only"]),
        ]
        for testCase in cases {
            let manager = ContactsManager()
            let bulk = HeldProfileLookups(profiles: [:])
            await bulk.hold()
            let records = [unprofiledRecord(key: contactProfileKey, label: "Label only"), contactRecord(key: unresolvedFollowKey, name: "Bob")]
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
            let interactive = ContactProfileFetchStub([testCase.outcome])

            await manager.resolvePendingContactProfile(publicKey: unresolvedFollowKey) { try await interactive.fetch($0) }
            let storedAttempts = await interactive.attempts
            XCTAssertEqual(storedAttempts, 0, "\(testCase.name): a stored profile is not looked up")

            async let first: Void = manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }
            async let second: Void = manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }
            _ = await (first, second)
            await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }

            let attempts = await interactive.attempts
            XCTAssertEqual(attempts, 1, "\(testCase.name): concurrent callers share one lookup, and the contact is not looked up again")
            let row = manager.contacts.first { $0.publicKey == contactProfileKey }?.profile
            XCTAssertEqual(row?.name, testCase.row.name, testCase.name)
            XCTAssertEqual(row?.bio, testCase.row.bio, "\(testCase.name): an edit made now keeps the bio the lookup found")
            XCTAssertEqual(row?.imageUrl, testCase.row.imageUrl, testCase.name)
            XCTAssertEqual(row?.links.map(\.url), testCase.row.links.map(\.url), testCase.name)
            XCTAssertEqual(manager.contacts.map(\.displayName), testCase.names, testCase.name)
            await bulk.release()
            await manager.waitForProfileRefreshForTesting()
        }
    }

    func testEditSavesWithoutWaitingForTheQueuedBackgroundLookupWhenTheContactsOwnLookupFails() async throws {
        let manager = ContactsManager()
        let slots = PaykitPublicReadSlots()
        // Other reads hold every bulk slot, so the background lookup of the contact stays queued behind them.
        let otherReads = HeldProfileLookups(profiles: [:])
        await otherReads.hold()
        let bulkReads = (0 ..< 4).map { index in
            Task { _ = try? await slots.withSlot(.bulk) { try await otherReads.fetch("other\(index)") } }
        }
        while await otherReads.heldCount < 4 {
            await Task.yield()
        }
        let bulk = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(
            for: "owner",
            fetchContactRecords: { records },
            fetchRemoteProfile: { publicKey in try await slots.withSlot(.bulk) { try await bulk.fetch(publicKey) } }
        )

        // Opening the edit screen looks the label-only row up on the interactive lane, and that lookup fails.
        let interactive = ContactProfileFetchStub([.failure(profileTransportError)])
        let screenLookup: @Sendable (String) async throws -> Bitkit.PubkyProfile? = { publicKey in
            try await slots.withSlot(.interactive) { try await interactive.fetch(publicKey) }
        }
        let opened = expectation(description: "The failed lookup returned while the bulk lane was still full")
        let opening = Task {
            await manager.resolvePendingContactProfile(publicKey: contactProfileKey, fetchRemoteProfile: screenLookup)
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 2)

        // The user renames the row and saves while the bulk lane is still full.
        var form = ContactEditForm()
        try form.fill(from: XCTUnwrap(manager.contacts.first?.profile))
        form.name = "My Alice"
        let saved = expectation(description: "Save went ahead while the bulk lane was still full")
        let save = Task {
            await manager.resolvePendingContactProfile(publicKey: contactProfileKey, fetchRemoteProfile: screenLookup)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 2)
        try form.fill(from: XCTUnwrap(manager.contacts.first?.profile))

        XCTAssertEqual(form.name, "My Alice")
        XCTAssertEqual(form.bio, "", "Once the contact's own lookup fails, Save keeps the label-only row, as on master")
        XCTAssertNil(form.imageUrl)
        let attempts = await interactive.attempts
        XCTAssertEqual(attempts, 1, "Save waits for at most the one interactive lookup")

        await otherReads.release()
        for read in bulkReads {
            await read.value
        }
        await opening.value
        await save.value
        await manager.waitForProfileRefreshForTesting()
    }

    func testBackgroundResultForAContactAScreenTookOverIsDropped() async throws {
        // The background lookup of the contact finds its profile while the screen's own lookup still runs, or only once
        // that lookup failed, such as while a Save uploads an avatar.
        for arrivesWhileTheScreenLooksUp in [true, false] {
            let message = "arrivesWhileTheScreenLooksUp: \(arrivesWhileTheScreenLooksUp)"
            let manager = ContactsManager()
            let bulk = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
            await bulk.hold()
            let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
            while await bulk.heldCount < 1 {
                await Task.yield()
            }

            let interactive = HeldProfileLookups(profiles: [:])
            await interactive.hold()
            let screenLookup = Task {
                await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }
            }
            while await interactive.heldCount < 1 {
                await Task.yield()
            }
            if arrivesWhileTheScreenLooksUp {
                await bulk.release()
                await manager.waitForProfileRefreshForTesting()
                XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "Taken over when the screen's lookup started, \(message)")
            }
            await interactive.release()
            await screenLookup.value
            await bulk.release()
            await manager.waitForProfileRefreshForTesting()

            let row = manager.contacts.first?.profile
            XCTAssertEqual(row?.name, "Label only", "A background result for a contact a screen took over must not change its row, \(message)")
            XCTAssertEqual(row?.bio, "", message)
            XCTAssertNil(row?.imageUrl, message)
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { _ in throw profileTransportError })
            XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "Nor may the next load show it, \(message)")
            await manager.waitForProfileRefreshForTesting()
        }
    }

    func testInteractiveProfileLookupStartedBeforeResetIsIgnored() async throws {
        let manager = ContactsManager()
        let bulk = HeldProfileLookups(profiles: [:])
        await bulk.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
        let interactive = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        await interactive.hold()
        let lookup = Task {
            await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }
        }
        while await interactive.heldCount < 1 {
            await Task.yield()
        }

        manager.reset()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
        await interactive.release()
        await lookup.value
        await bulk.release()
        await manager.waitForProfileRefreshForTesting()

        XCTAssertEqual(manager.contacts.map(\.displayName), ["Label only"], "A lookup from before the reset must not update rows")
    }

    func testEditFormKeepsTheUsersChangesWhenTheContactsProfileArrives() {
        var form = ContactEditForm()
        form.fill(from: Bitkit.PubkyProfile.forDisplay(publicKey: contactProfileKey, name: "Label only", imageUrl: nil))
        form.name = "My Alice"
        form.tags = ["friend"]

        form.fill(from: Bitkit.PubkyProfile(
            publicKey: contactProfileKey,
            name: "Alice",
            bio: "Hello",
            imageUrl: "pubky://alice/avatar",
            links: [PubkyProfileLink(label: "Site", url: "https://alice.example")],
            tags: ["remote"],
            status: nil
        ))

        XCTAssertEqual(form.name, "My Alice")
        XCTAssertEqual(form.tags, ["friend"])
        XCTAssertEqual(form.bio, "Hello", "A field the user left alone takes the arriving profile")
        XCTAssertEqual(form.imageUrl, "pubky://alice/avatar")
        XCTAssertEqual(form.links.map(\.url), ["https://alice.example"])
    }

    func testTagChangesQueuedDuringTheContactsLookupKeepTheProfileItFindsAndEachOther() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }
        let savedLabels = SavedContactLabels()
        let manager = ContactsManager(
            fetchRemoteProfile: { _, _ in throw profileTransportError },
            saveContactLabel: { publicKey, label, _ in await savedLabels.save(publicKey, label: label) }
        )
        let bulk = HeldProfileLookups(profiles: [:])
        await bulk.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })

        // The contact's screen looks its label-only row up, and that lookup is held.
        let interactive = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
        await interactive.hold()
        let screenLookup = Task {
            await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }
        }
        while await interactive.heldCount < 1 {
            await Task.yield()
        }

        // The user adds two tags while it is still held.
        let shown = try XCTUnwrap(manager.contacts.first?.profile)
        let first = manager.updateContactTags(
            publicKey: contactProfileKey, shownProfile: shown, expectedIdentity: "owner", isSessionCurrent: { true }
        ) { $0 + ["friend"] }
        let second = manager.updateContactTags(
            publicKey: contactProfileKey, shownProfile: shown.withTags(["friend"]), expectedIdentity: "owner", isSessionCurrent: { true }
        ) { $0 + ["work"] }
        await interactive.release()
        await screenLookup.value
        try await first.value
        try await second.value

        let saved = try XCTUnwrap(ContactsManager.backupContactProfileOverrides()?[contactProfileKey])
        XCTAssertEqual(saved.tags, ["friend", "work"], "The second change saves over the first, so neither tag is lost")
        XCTAssertEqual(saved.name, "Alice", "The changes wait for the lookup, so they save over the profile it finds")
        XCTAssertEqual(saved.bio, "Hello")
        XCTAssertEqual(saved.image, "pubky://alice/avatar")
        XCTAssertEqual(saved.links.map(\.url), ["https://alice.example"])
        XCTAssertEqual(manager.contacts.first.map { PubkyProfileData.from(profile: $0.profile) }, saved, "The row shows what was saved")
        let labels = await savedLabels.labels
        XCTAssertEqual(labels, ["Alice", "Alice"], "Each change saves the contact once, under the name the lookup found")

        await bulk.release()
        await manager.waitForProfileRefreshForTesting()
    }

    /// The review regression: two tag changes wait for the contact's held lookup, the user signs out and signs in with
    /// another identity, and the lookup finishes only then. The next identity may have saved a contact with the same key,
    /// which the SDK would accept a save for, or not, which it rejects.
    func testTagChangesQueuedBeforeASignOutSaveNothingForTheNextIdentity() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }

        for nextIdentityHasContact in [true, false] {
            let message = nextIdentityHasContact ? "when the next identity saved the same contact" : "when it has no such contact"
            ContactsManager.restoreContactProfileOverrides(nil)
            let session = TestPubkySession()
            let store = SignedInContactStore(identity: "owner-a", savedKeys: [contactProfileKey])
            let interactive = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
            await interactive.hold()
            let manager = ContactsManager(
                fetchRemoteProfile: { publicKey, _ in try await interactive.fetch(publicKey) },
                saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) }
            )
            let bulk = HeldProfileLookups(profiles: [:])
            await bulk.hold()
            let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
            try await manager.loadContacts(for: "owner-a", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })

            let shown = try XCTUnwrap(manager.contacts.first?.profile)
            let first = manager.updateContactTags(
                publicKey: contactProfileKey, shownProfile: shown, expectedIdentity: "owner-a", isSessionCurrent: session.check()
            ) { $0 + ["friend"] }
            let second = manager.updateContactTags(
                publicKey: contactProfileKey, shownProfile: shown.withTags(["friend"]), expectedIdentity: "owner-a",
                isSessionCurrent: session.check()
            ) { $0 + ["work"] }
            // The first change takes the contact's lookup over, and the lookup is held.
            while await interactive.heldCount < 1 {
                await Task.yield()
            }

            // Signing out ends the session, AppScene resets Contacts, and the sign-out clears the overrides.
            session.change()
            manager.reset()
            ContactsManager.restoreContactProfileOverrides(nil)
            // Another identity signs in and loads its contacts, whose own lookups are held.
            session.change()
            await store.signIn(identity: "owner-b", savedKeys: nextIdentityHasContact ? [contactProfileKey] : [])
            let nextRecords = nextIdentityHasContact ? [unprofiledRecord(key: contactProfileKey, label: "Bob's label")] : []
            let nextBulk = HeldProfileLookups(profiles: [:])
            await nextBulk.hold()
            try await manager.loadContacts(for: "owner-b", fetchContactRecords: { nextRecords }, fetchRemoteProfile: { try await nextBulk.fetch($0) })

            // The cancelled read finishes anyway.
            await interactive.release()
            do {
                try await first.value
                try await second.value
            } catch {
                XCTFail("A tag change from before the sign-out must not report an error, so no toast shows, \(message): \(error)")
            }

            let saved = await store.savedLabels
            XCTAssertEqual(saved, [], "Neither change saves through the next identity's session, \(message)")
            XCTAssertNil(ContactsManager.backupContactProfileOverrides(), "Neither change writes back an override, \(message)")
            let lookups = await interactive.fetchedKeys
            XCTAssertEqual(lookups, [contactProfileKey], "The second change does not look the next identity's contact up, \(message)")
            XCTAssertEqual(manager.contacts.map(\.displayName), nextIdentityHasContact ? ["Bob's label"] : [], message)
            XCTAssertEqual(manager.contacts.map(\.profile.tags), nextIdentityHasContact ? [[]] : [], message)

            await bulk.release()
            await nextBulk.release()
            await manager.waitForProfileRefreshForTesting()
        }
    }

    /// Covers each half of a session change on its own: the sign-out starting before AppScene resets Contacts, and a reset
    /// with the same identity signing straight back in, whose own tag change must not wait behind the old one.
    func testQueuedTagChangeStopsOnceItsSessionEndsOrContactsReset() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }

        for resetsContacts in [false, true] {
            let message = resetsContacts ? "after a reset" : "once the session ends"
            ContactsManager.restoreContactProfileOverrides(nil)
            let session = TestPubkySession()
            let store = SignedInContactStore(identity: "owner", savedKeys: [contactProfileKey])
            let interactive = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
            await interactive.hold()
            let manager = ContactsManager(
                fetchRemoteProfile: { publicKey, _ in try await interactive.fetch(publicKey) },
                saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) }
            )
            let bulk = HeldProfileLookups(profiles: [:])
            await bulk.hold()
            let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })

            let shown = try XCTUnwrap(manager.contacts.first?.profile)
            let stale = manager.updateContactTags(
                publicKey: contactProfileKey,
                shownProfile: shown,
                expectedIdentity: "owner",
                isSessionCurrent: resetsContacts ? { true } : session.check()
            ) { $0 + ["friend"] }
            while await interactive.heldCount < 1 {
                await Task.yield()
            }

            var nextChange: Task<Void, Error>?
            var expectedLabels: [String] = []
            var expectedTags: [String]?
            if resetsContacts {
                manager.reset()
                let nextRecords = [contactRecord(key: contactProfileKey, name: "Alice")]
                try await manager.loadContacts(for: "owner", fetchContactRecords: { nextRecords }, fetchRemoteProfile: { _ in nil })
                let next = try XCTUnwrap(manager.contacts.first?.profile)
                let change = manager.updateContactTags(
                    publicKey: contactProfileKey, shownProfile: next, expectedIdentity: "owner", isSessionCurrent: { true }
                ) { $0 + ["new"] }
                let nextSaved = expectation(description: "The next session's change saves while the old lookup is still held")
                Task {
                    _ = await change.result
                    nextSaved.fulfill()
                }
                await fulfillment(of: [nextSaved], timeout: 2)
                nextChange = change
                expectedLabels = ["Alice"]
                expectedTags = ["new"]
            } else {
                session.change()
            }

            await interactive.release()
            do {
                try await stale.value
            } catch {
                XCTFail("A stale tag change must not report an error \(message): \(error)")
            }
            try await nextChange?.value

            let saved = await store.savedLabels
            XCTAssertEqual(saved, expectedLabels, "The stale change saves nothing \(message)")
            XCTAssertEqual(ContactsManager.backupContactProfileOverrides()?[contactProfileKey]?.tags, expectedTags, message)

            await bulk.release()
            await manager.waitForProfileRefreshForTesting()
        }
    }

    /// The save itself was admitted and waits for the SDK lock, but a sign-out and another identity's sign-in land before it
    /// gets it: after the last check before the save, before the SDK writes. The next identity may have saved a contact with
    /// the same key, which the SDK would accept a save for, or not. Either way the SDK refuses the save, since it is for the
    /// identity that signed out, so it writes nothing and nothing is published for the next identity.
    func testTagSaveThatASessionChangeOvertakesPublishesNothing() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }

        for nextIdentityHasContact in [true, false] {
            let message = nextIdentityHasContact ? "when the next identity saved the same contact" : "when it has no such contact"
            ContactsManager.restoreContactProfileOverrides(nil)
            let session = TestPubkySession()
            let store = SignedInContactStore(identity: "owner-a", savedKeys: [contactProfileKey])
            await store.hold()
            let manager = ContactsManager(saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) })
            let records = [contactRecord(key: contactProfileKey, name: "Alice")]
            try await manager.loadContacts(for: "owner-a", fetchContactRecords: { records }, fetchRemoteProfile: { _ in nil })

            let shown = try XCTUnwrap(manager.contacts.first?.profile)
            let change = manager.updateContactTags(
                publicKey: contactProfileKey, shownProfile: shown, expectedIdentity: "owner-a", isSessionCurrent: session.check()
            ) { $0 + ["friend"] }
            while await store.heldCount < 1 {
                await Task.yield()
            }

            session.change()
            manager.reset()
            ContactsManager.restoreContactProfileOverrides(nil)
            session.change()
            await store.signIn(identity: "owner-b", savedKeys: nextIdentityHasContact ? [contactProfileKey] : [])
            let nextRecords = [contactRecord(key: contactProfileKey, name: "Bob's Alice")]
            try await manager.loadContacts(for: "owner-b", fetchContactRecords: { nextRecords }, fetchRemoteProfile: { _ in nil })

            await store.release()
            do {
                try await change.value
            } catch {
                XCTFail("A save the sign-out overtook must not report an error \(message): \(error)")
            }

            let saved = await store.savedLabels
            XCTAssertEqual(saved, [], "Nothing is written to the next identity's contacts \(message)")
            let refused = await store.refusedIdentities
            XCTAssertEqual(refused, ["owner-a"], "The SDK refuses the save for the identity that signed out \(message)")
            XCTAssertNil(ContactsManager.backupContactProfileOverrides(), "No override is written back \(message)")
            XCTAssertEqual(manager.contacts.map(\.displayName), ["Bob's Alice"], "The next identity's row is unchanged \(message)")
            XCTAssertEqual(manager.contacts.map(\.profile.tags), [[]], message)
        }
    }

    /// Like a tag change, an edit's save that waits for the SDK lock while a sign-out and another identity's sign-in land is
    /// refused for the identity that signed out, writes nothing and reports nothing.
    func testContactEditThatASessionChangeOvertakesWhileItSavesWritesNothing() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }
        ContactsManager.restoreContactProfileOverrides(nil)
        let session = TestPubkySession()
        let store = SignedInContactStore(identity: "owner-a", savedKeys: [contactProfileKey])
        await store.hold()
        let manager = ContactsManager(saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) })
        let records = [contactRecord(key: contactProfileKey, name: "Alice")]
        try await manager.loadContacts(for: "owner-a", fetchContactRecords: { records }, fetchRemoteProfile: { _ in nil })

        let screen = ContactEditScreen(manager: manager, publicKey: contactProfileKey)
        screen.edit {
            $0.name = "My Alice"
            $0.tags = ["friend"]
        }
        let save = Task {
            try await manager.saveContactEdit(publicKey: contactProfileKey, expectedIdentity: "owner-a", isSessionCurrent: session.check()) {
                try await screen.makeEdit()
            }
        }
        while await store.heldCount < 1 {
            await Task.yield()
        }

        session.change()
        manager.reset()
        ContactsManager.restoreContactProfileOverrides(nil)
        session.change()
        await store.signIn(identity: "owner-b", savedKeys: [contactProfileKey])
        let nextRecords = [contactRecord(key: contactProfileKey, name: "Bob's Alice")]
        try await manager.loadContacts(for: "owner-b", fetchContactRecords: { nextRecords }, fetchRemoteProfile: { _ in nil })

        await store.release()
        var savedProfile: Bitkit.PubkyProfile?
        do {
            savedProfile = try await save.value
        } catch {
            XCTFail("An edit the sign-out overtook must not report an error, so no toast shows: \(error)")
        }

        XCTAssertNil(savedProfile, "Nothing is reported saved, so no toast shows and the screen does not navigate")
        let saved = await store.savedLabels
        XCTAssertEqual(saved, [], "Nothing is written to the next identity's contact")
        let refused = await store.refusedIdentities
        XCTAssertEqual(refused, ["owner-a"], "The SDK refuses the save for the identity that signed out")
        XCTAssertNil(ContactsManager.backupContactProfileOverrides(), "No override is written back")
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Bob's Alice"])
        XCTAssertEqual(manager.contacts.map(\.profile.tags), [[]])
    }

    /// The SDK refuses a save because another identity is signed in while the session check still holds, as it can for a
    /// sign-in the session check has not seen yet. A tag change and an edit treat the refusal as stale and drop it quietly.
    func testContactSaveTheSdkRefusesForAnotherIdentityIsDroppedQuietly() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }
        ContactsManager.restoreContactProfileOverrides(nil)
        let store = SignedInContactStore(identity: "owner-b", savedKeys: [contactProfileKey])
        let manager = ContactsManager(saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) })
        let records = [contactRecord(key: contactProfileKey, name: "Alice")]
        try await manager.loadContacts(for: "owner-a", fetchContactRecords: { records }, fetchRemoteProfile: { _ in nil })
        let shown = try XCTUnwrap(manager.contacts.first?.profile)

        let change = manager.updateContactTags(
            publicKey: contactProfileKey, shownProfile: shown, expectedIdentity: "owner-a", isSessionCurrent: { true }
        ) { $0 + ["friend"] }
        do {
            try await change.value
        } catch {
            XCTFail("A refused tag change must not report an error, so no toast shows: \(error)")
        }
        var savedProfile: Bitkit.PubkyProfile?
        do {
            savedProfile = try await manager.saveContactEdit(publicKey: contactProfileKey, expectedIdentity: "owner-a", isSessionCurrent: { true }) {
                ContactEdit(name: "My Alice", bio: "", imageUrl: nil, links: [], tags: ["friend"])
            }
        } catch {
            XCTFail("A refused edit must not report an error, so no toast shows: \(error)")
        }
        var uploadRefusedProfile: Bitkit.PubkyProfile?
        do {
            uploadRefusedProfile = try await manager.saveContactEdit(
                publicKey: contactProfileKey, expectedIdentity: "owner-a", isSessionCurrent: { true }
            ) { throw PubkyServiceError.identityChanged }
        } catch {
            XCTFail("An edit whose avatar upload was refused must not report an error, so no toast shows: \(error)")
        }

        XCTAssertNil(uploadRefusedProfile, "Nor is an edit whose avatar upload the SDK refused")
        XCTAssertNil(savedProfile, "Nothing is reported saved, so Edit Contact shows no toast and does not navigate")
        let refused = await store.refusedIdentities
        XCTAssertEqual(refused, ["owner-a", "owner-a"])
        let saved = await store.savedLabels
        XCTAssertEqual(saved, [])
        XCTAssertNil(ContactsManager.backupContactProfileOverrides(), "No override is written")
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"], "The row is unchanged")
        XCTAssertEqual(manager.contacts.map(\.profile.tags), [[]])
    }

    func testContactEditWaitsForTheContactsLookupAndSavesOverTheProfileItFinds() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }
        ContactsManager.restoreContactProfileOverrides(nil)
        let store = SignedInContactStore(identity: "owner", savedKeys: [contactProfileKey])
        let interactive = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
        await interactive.hold()
        let manager = ContactsManager(
            fetchRemoteProfile: { publicKey, _ in try await interactive.fetch(publicKey) },
            saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) }
        )
        let bulk = HeldProfileLookups(profiles: [:])
        await bulk.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })

        let screen = ContactEditScreen(manager: manager, publicKey: contactProfileKey)
        screen.edit { $0.tags = ["friend"] }
        let save = Task {
            try await manager.saveContactEdit(publicKey: contactProfileKey, expectedIdentity: "owner", isSessionCurrent: { true }) {
                try await screen.makeEdit()
            }
        }
        while await interactive.heldCount < 1 {
            await Task.yield()
        }
        XCTAssertEqual(screen.editsMade, 0, "Save builds the edit only once the contact's lookup is done")

        await interactive.release()
        let savedProfile = try await save.value

        XCTAssertEqual(screen.editsMade, 1)
        XCTAssertEqual(savedProfile?.name, "Alice", "A field the user left alone takes the profile the lookup found")
        XCTAssertEqual(savedProfile?.bio, "Hello")
        XCTAssertEqual(savedProfile?.imageUrl, "pubky://alice/avatar")
        XCTAssertEqual(savedProfile?.links.map(\.url), ["https://alice.example"])
        XCTAssertEqual(savedProfile?.tags, ["friend"], "The user's change is kept")
        let saved = await store.savedLabels
        XCTAssertEqual(saved, ["Alice"])
        XCTAssertEqual(ContactsManager.backupContactProfileOverrides()?[contactProfileKey], savedProfile.map { PubkyProfileData.from(profile: $0) })
        XCTAssertEqual(manager.contacts.first?.profile.tags, ["friend"], "The row shows what was saved")

        await bulk.release()
        await manager.waitForProfileRefreshForTesting()
    }

    /// The review regression for an edit: Save waits for the contact's held lookup, the user leaves, signs out and adopts
    /// another identity, and the lookup finishes only then. The next identity may have saved a contact with the same key,
    /// which the SDK would accept a save for, or not, which it rejects.
    func testContactEditSavedBeforeASignOutSavesNothingForTheNextIdentity() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }

        for nextIdentityHasContact in [true, false] {
            let message = nextIdentityHasContact ? "when the next identity saved the same contact" : "when it has no such contact"
            ContactsManager.restoreContactProfileOverrides(nil)
            let session = TestPubkySession()
            let store = SignedInContactStore(identity: "owner-a", savedKeys: [contactProfileKey])
            let interactive = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
            await interactive.hold()
            let manager = ContactsManager(
                fetchRemoteProfile: { publicKey, _ in try await interactive.fetch(publicKey) },
                saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) }
            )
            let bulk = HeldProfileLookups(profiles: [:])
            await bulk.hold()
            let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
            try await manager.loadContacts(for: "owner-a", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })

            // The user changes every field but the avatar and taps Save, which waits for the contact's held lookup.
            let screen = ContactEditScreen(manager: manager, publicKey: contactProfileKey)
            screen.edit {
                $0.name = "My Alice"
                $0.bio = "Met at the meetup"
                $0.links = [ProfileLinkInput(label: "Site", url: "https://old.example")]
                $0.tags = ["friend"]
            }
            let save = Task {
                try await manager.saveContactEdit(
                    publicKey: contactProfileKey, expectedIdentity: "owner-a", isSessionCurrent: session.check()
                ) {
                    try await screen.makeEdit()
                }
            }
            while await interactive.heldCount < 1 {
                await Task.yield()
            }

            // The user leaves and signs out, AppScene resets Contacts, and the sign-out clears the overrides.
            session.change()
            manager.reset()
            ContactsManager.restoreContactProfileOverrides(nil)
            // Another identity signs in and loads its contacts, whose own lookups are held.
            session.change()
            await store.signIn(identity: "owner-b", savedKeys: nextIdentityHasContact ? [contactProfileKey] : [])
            let nextRecords = nextIdentityHasContact ? [unprofiledRecord(key: contactProfileKey, label: "Bob's label")] : []
            let nextBulk = HeldProfileLookups(profiles: [:])
            await nextBulk.hold()
            try await manager.loadContacts(for: "owner-b", fetchContactRecords: { nextRecords }, fetchRemoteProfile: { try await nextBulk.fetch($0) })

            // The cancelled read finishes anyway.
            await interactive.release()
            var savedProfile: Bitkit.PubkyProfile?
            do {
                savedProfile = try await save.value
            } catch {
                XCTFail("An edit from before the sign-out must not report an error, so no toast shows, \(message): \(error)")
            }

            XCTAssertNil(savedProfile, "Nothing is reported saved, so no toast shows and the screen does not navigate, \(message)")
            XCTAssertEqual(screen.editsMade, 0, "The form is not filled from the next identity's contact, nor an avatar uploaded, \(message)")
            let saved = await store.savedLabels
            XCTAssertEqual(saved, [], "Nothing saves through the next identity's session, \(message)")
            XCTAssertNil(ContactsManager.backupContactProfileOverrides(), "No override is written back, \(message)")
            XCTAssertEqual(manager.contacts.map(\.displayName), nextIdentityHasContact ? ["Bob's label"] : [], message)
            XCTAssertEqual(manager.contacts.map(\.profile.bio), nextIdentityHasContact ? [""] : [], message)
            XCTAssertEqual(manager.contacts.map(\.profile.links.count), nextIdentityHasContact ? [0] : [], message)
            XCTAssertEqual(manager.contacts.map(\.profile.tags), nextIdentityHasContact ? [[]] : [], message)

            await bulk.release()
            await nextBulk.release()
            await manager.waitForProfileRefreshForTesting()
        }
    }

    /// Covers each half of a session change on its own: the session ending before AppScene resets Contacts, and a reset with
    /// the same identity signing straight back in. Each lands while Save waits for the contact's lookup or uploads the
    /// avatar, which then succeeds or fails.
    func testContactEditStopsOnceItsSessionEndsOrContactsResetWhileItWaits() async throws {
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        addTeardownBlock { ContactsManager.restoreContactProfileOverrides(savedOverrides) }

        for wait in ["lookup", "avatar upload", "failed avatar upload"] {
            for resetsContacts in [false, true] {
                let message = "\(resetsContacts ? "after a reset" : "once the session ends") during the \(wait)"
                ContactsManager.restoreContactProfileOverrides(nil)
                let session = TestPubkySession()
                let store = SignedInContactStore(identity: "owner", savedKeys: [contactProfileKey])
                let interactive = HeldProfileLookups(publishedProfiles: [publishedContactProfile])
                if wait == "lookup" {
                    await interactive.hold()
                }
                let manager = ContactsManager(
                    fetchRemoteProfile: { publicKey, _ in try await interactive.fetch(publicKey) },
                    saveContactLabel: { try await store.save($0, label: $1, expectedIdentity: $2) }
                )
                let bulk = HeldProfileLookups(profiles: [:])
                await bulk.hold()
                let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
                try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
                let endSession: @MainActor () async throws -> Void = {
                    if resetsContacts {
                        manager.reset()
                        try await manager.loadContacts(
                            for: "owner",
                            fetchContactRecords: { records },
                            fetchRemoteProfile: { try await bulk.fetch($0) }
                        )
                    } else {
                        session.change()
                    }
                }

                let screen = ContactEditScreen(manager: manager, publicKey: contactProfileKey)
                screen.edit {
                    $0.name = "My Alice"
                    $0.tags = ["friend"]
                }
                let save = Task {
                    try await manager.saveContactEdit(
                        publicKey: contactProfileKey,
                        expectedIdentity: "owner",
                        isSessionCurrent: resetsContacts ? { true } : session.check()
                    ) {
                        guard wait != "lookup" else { return try await screen.makeEdit() }
                        return try await screen.makeEdit {
                            try await endSession()
                            guard wait == "avatar upload" else { throw profileTransportError }
                            return "pubky://owner/new-avatar"
                        }
                    }
                }
                if wait == "lookup" {
                    while await interactive.heldCount < 1 {
                        await Task.yield()
                    }
                    try await endSession()
                    await interactive.release()
                }
                var savedProfile: Bitkit.PubkyProfile?
                do {
                    savedProfile = try await save.value
                } catch {
                    XCTFail("A stale edit must not report an error \(message): \(error)")
                }

                XCTAssertNil(savedProfile, message)
                XCTAssertEqual(screen.editsMade, wait == "lookup" ? 0 : 1, message)
                let saved = await store.savedLabels
                XCTAssertEqual(saved, [], "The stale edit saves nothing \(message)")
                XCTAssertNil(ContactsManager.backupContactProfileOverrides(), message)
                XCTAssertFalse(manager.contacts.map(\.displayName).contains("My Alice"), message)
                XCTAssertEqual(manager.contacts.map(\.profile.tags), [[]], message)

                await bulk.release()
                await manager.waitForProfileRefreshForTesting()
            }
        }
    }

    func testPreparingAnImportLooksFollowsUpOnTheInteractiveLane() async throws {
        let lanes = ProfileLookupLanes()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        let manager = ContactsManager(
            contactRecords: { records },
            fetchFollows: { _ in [contactProfileKey, unresolvedFollowKey] },
            fetchRemoteProfile: { try await lanes.fetch($0, priority: $1) }
        )

        let hasImportData = await manager.prepareImport(profile: nil, publicKey: "owner")

        XCTAssertTrue(hasImportData)
        let importLanes = await lanes.priorities
        XCTAssertEqual(importLanes, [.interactive, .interactive], "The user waits on the choice screen while the import is prepared")

        try await manager.loadContacts(for: "owner")
        await manager.waitForProfileRefreshForTesting()
        let allLanes = await lanes.priorities
        XCTAssertEqual(Array(allLanes.dropFirst(importLanes.count)), [.bulk], "The Contacts list still refreshes its profiles in the background")
    }

    func testContactsReloadShowsImportedProfilesAtOnceButStillLooksPlaceholdersUp() async throws {
        let published = Bitkit.PubkyProfile(
            publicKey: contactProfileKey, name: "Alice", bio: "Hello", imageUrl: "pubky://alice/avatar", links: [], status: nil
        )
        let manager = ContactsManager(
            fetchFollows: { _ in [contactProfileKey, unresolvedFollowKey] },
            fetchRemoteProfile: { publicKey, _ in
                guard publicKey == contactProfileKey else { throw profileTransportError }
                return published
            }
        )
        await manager.prepareImport(profile: nil, publicKey: "owner")
        let placeholderName = Bitkit.PubkyProfile.placeholder(publicKey: unresolvedFollowKey).name
        XCTAssertEqual(Set(manager.pendingImportContacts.map(\.displayName)), ["Alice", placeholderName])
        try await manager.importContacts(contacts: manager.pendingImportContacts) { _, _ in }

        let bulk = HeldProfileLookups(profiles: [:])
        await bulk.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Alice"), unprofiledRecord(key: unresolvedFollowKey, label: placeholderName)]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })

        let alice = try XCTUnwrap(manager.contacts.first { $0.publicKey == contactProfileKey })
        XCTAssertEqual(alice.profile.imageUrl, "pubky://alice/avatar", "An imported profile shows before the background refresh reaches it")
        XCTAssertEqual(alice.profile.bio, "Hello")
        let interactive = ContactProfileFetchStub([.failure(profileTransportError)])
        await manager.resolvePendingContactProfile(publicKey: unresolvedFollowKey) { try await interactive.fetch($0) }
        let attempts = await interactive.attempts
        XCTAssertEqual(attempts, 1, "A follow imported as a placeholder must still have its profile looked up before an edit")
        await bulk.release()
        await manager.waitForProfileRefreshForTesting()
    }

    func testImportFinishingAfterResetDoesNotRememberItsProfiles() async throws {
        let published = Bitkit.PubkyProfile(
            publicKey: contactProfileKey, name: "Alice", bio: "Hello", imageUrl: "pubky://alice/avatar", links: [], status: nil
        )
        let manager = ContactsManager()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { [] }, fetchRemoteProfile: { _ in nil })
        let saves = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        await saves.hold()
        let importTask = Task {
            try await manager.importContacts(contacts: [Bitkit.PubkyContact(publicKey: contactProfileKey, profile: published)]) { key, _ in
                _ = try await saves.fetch(key)
            }
        }
        while await saves.heldCount < 1 {
            await Task.yield()
        }

        manager.reset()
        try await manager.loadContacts(for: "owner", fetchContactRecords: { [] }, fetchRemoteProfile: { _ in nil })
        await saves.release()
        try await importTask.value

        let bulk = HeldProfileLookups(profiles: [:])
        await bulk.hold()
        let records = [unprofiledRecord(key: contactProfileKey, label: "Alice")]
        try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
        XCTAssertNil(manager.contacts.first?.profile.imageUrl, "An import from before the reset must not seed the next session's profiles")
        await bulk.release()
        await manager.waitForProfileRefreshForTesting()
    }

    func testImportThatAResetOvertakesStopsSavingAndReportsNothing() async throws {
        let prepared = (0 ..< 3).map { makeContact(publicKey: "pubky-contact-\($0)") }
        // The save running when the user signs out may land first or fail after the sign-out; later saves would fail.
        for heldSaveSucceeds in [true, false] {
            let manager = ContactsManager()
            try await manager.loadContacts(for: "owner", fetchContactRecords: { [] }, fetchRemoteProfile: { _ in nil })
            let saves = HeldProfileLookups(profiles: heldSaveSucceeds ? [prepared[0].publicKey: "Alice"] : [:])
            await saves.hold()
            let importTask = Task {
                try await manager.importContacts(contacts: prepared) { key, _ in
                    _ = try await saves.fetch(key)
                }
            }
            while await saves.heldCount < 1 {
                await Task.yield()
            }

            manager.reset()
            await saves.release()
            do {
                try await importTask.value
            } catch {
                XCTFail("An import a reset overtook must not report an error after the sign-out: \(error)")
            }

            let attempted = await saves.fetchedKeys
            XCTAssertEqual(attempted, [prepared[0].publicKey], "A reset stops the import before its next save")
            XCTAssertTrue(manager.contacts.isEmpty, "An import a reset overtook adds nothing to the cleared list")
        }
    }

    func testShouldDiscardPendingImportWhenLeavingImportFlow() {
        XCTAssertTrue(shouldDiscardPendingImport(currentRoute: .contactImportOverview, destination: .contacts))
        XCTAssertTrue(shouldDiscardPendingImport(currentRoute: .contactImportSelect, destination: nil))
    }

    func testShouldNotDiscardPendingImportWhenStayingInsideImportFlow() {
        XCTAssertFalse(shouldDiscardPendingImport(currentRoute: .contactImportOverview, destination: .contactImportSelect))
        XCTAssertFalse(shouldDiscardPendingImport(currentRoute: .contacts, destination: .profile))
    }

    func testFinishedImportOpensPayContactsOnlyWhileItsImportIsStillPending() {
        let manager = ContactsManager()
        manager.pendingImportProfile = makeProfile(publicKey: "pubky-owner")
        manager.pendingImportContacts = [makeContact(publicKey: contactProfileKey)]
        XCTAssertTrue(manager.completePendingImport(), "An import that finishes on the import screens opens Pay Contacts")
        XCTAssertFalse(manager.hasPendingImport)

        manager.pendingImportProfile = makeProfile(publicKey: "pubky-owner")
        manager.pendingImportContacts = [makeContact(publicKey: contactProfileKey)]
        XCTAssertTrue(shouldDiscardPendingImport(currentRoute: .contactImportOverview, destination: .settings))
        manager.clearPendingImport()
        XCTAssertFalse(manager.completePendingImport(), "An import that finishes after the user left must not pull them away")
    }

    /// Removing contacts left the running profile refresh looking them up, so it kept issuing reads for deleted contacts.
    func testRemovingAContactStopsItsQueuedProfileLookup() async throws {
        snapshotAppDefaults("pubkyContactProfileOverrides")
        let slot = PaykitSdkReadLimiter(maxConcurrent: 1)
        let blockingRead = try await holdTheOnlyReadSlot(slot)
        let removedKey = "pubky" + String(repeating: "r", count: 52)
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice", removedKey: "Removed"])
        let manager = ContactsManager(removeContactRecord: { _ in }, forgetRemovedContacts: { _ in })
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only"), unprofiledRecord(key: removedKey, label: "To remove")]
        try await manager.loadContacts(
            for: "owner",
            fetchContactRecords: { records },
            fetchRemoteProfile: { key in try await slot.withSlot(priority: .bulk) { try await lookups.fetch(key) } }
        )
        while slot.waiterCountForTesting < 2 {
            await Task.yield()
        }

        try await manager.removeContact(publicKey: removedKey)
        XCTAssertEqual(slot.waiterCountForTesting, 1, "The removed contact's lookup leaves the read queue at once")

        await blockingRead.release()
        await manager.waitForProfileRefreshForTesting()
        let fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys, [contactProfileKey], "No read is issued for the removed contact")
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Alice"])
    }

    func testDeletingAllContactsStopsTheRunningProfileRefresh() async throws {
        snapshotAppDefaults("pubkyContactProfileOverrides")
        let slot = PaykitSdkReadLimiter(maxConcurrent: 1)
        let blockingRead = try await holdTheOnlyReadSlot(slot)
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice", unresolvedFollowKey: "Bob"])
        let records = [unprofiledRecord(key: contactProfileKey, label: "First"), unprofiledRecord(key: unresolvedFollowKey, label: "Second")]
        let manager = ContactsManager(contactRecords: { records }, removeContactRecord: { _ in }, forgetRemovedContacts: { _ in })
        try await manager.loadContacts(
            for: "owner",
            fetchContactRecords: { records },
            fetchRemoteProfile: { key in try await slot.withSlot(priority: .bulk) { try await lookups.fetch(key) } }
        )
        while slot.waiterCountForTesting < 2 {
            await Task.yield()
        }

        try await manager.deleteAllContacts()
        XCTAssertEqual(slot.waiterCountForTesting, 0, "Every queued lookup leaves the read queue once all contacts are deleted")

        await blockingRead.release()
        await manager.waitForProfileRefreshForTesting()
        let fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys, [], "No read is issued for a deleted contact")
        XCTAssertTrue(manager.contacts.isEmpty)
    }

    /// Removing a contact stopped only the background refresh's lookup of it, so its screen's lookup stayed queued for a read
    /// slot and still read the profile of a contact that no longer existed.
    func testRemovingAContactStopsItsScreensQueuedProfileLookup() async throws {
        snapshotAppDefaults("pubkyContactProfileOverrides")
        let slot = PaykitSdkReadLimiter(maxConcurrent: 1)
        let blockingRead = try await holdTheOnlyReadSlot(slot)
        let lookups = HeldProfileLookups(profiles: [contactProfileKey: "Alice"])
        let manager = ContactsManager(removeContactRecord: { _ in }, forgetRemovedContacts: { _ in })
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        try await manager.loadContacts(
            for: "owner",
            fetchContactRecords: { records },
            fetchRemoteProfile: { key in try await slot.withSlot(priority: .bulk) { try await lookups.fetch(key) } }
        )
        await waitUntil("the background lookup queues for the read slot") { slot.waiterCountForTesting >= 1 }
        let screenLookup = Task {
            await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { key in
                try await slot.withSlot(priority: .interactive) { try await lookups.fetch(key) }
            }
        }
        await waitUntil("the screen's lookup queues for the read slot too") { slot.waiterCountForTesting >= 2 }

        try await manager.removeContact(publicKey: contactProfileKey)
        XCTAssertEqual(slot.waiterCountForTesting, 0, "The screen's lookup leaves the read queue at once, like the refresh's")

        await blockingRead.release()
        await screenLookup.value
        await manager.waitForProfileRefreshForTesting()
        let fetchedKeys = await lookups.fetchedKeys
        XCTAssertEqual(fetchedKeys, [], "No read is issued for the removed contact")
        XCTAssertTrue(manager.contacts.isEmpty)
    }

    /// The QA regression: a label-only contact is deleted while its screen's lookup is pending, then added again with a
    /// newer profile before that lookup returns. The lookup survived the deletion, so its old result replaced the re-added
    /// row and was remembered as resolved, keeping the obsolete profile on reloads for ten minutes.
    func testScreensLookupOfADeletedContactCannotReplaceTheProfileItWasAddedBackWith() async throws {
        snapshotAppDefaults("pubkyContactProfileOverrides")
        let newer = Bitkit.PubkyProfile(
            publicKey: contactProfileKey, name: "Alice Newer", bio: "Newer bio", imageUrl: "pubky://alice/newer", links: [], status: nil
        )
        let records = [unprofiledRecord(key: contactProfileKey, label: "Label only")]
        let deletions: [(name: String, delete: @MainActor (ContactsManager) async throws -> Void)] = [
            ("removing the contact", { try await $0.removeContact(publicKey: contactProfileKey) }),
            ("deleting all contacts", { try await $0.deleteAllContacts() }),
        ]
        for deletion in deletions {
            let manager = ContactsManager(contactRecords: { records }, removeContactRecord: { _ in }, forgetRemovedContacts: { _ in })
            let bulk = HeldProfileLookups(profiles: [:])
            await bulk.hold()
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await bulk.fetch($0) })
            let interactive = HeldProfileLookups(profiles: [contactProfileKey: "Alice Older"])
            await interactive.hold()
            let screenLookup = Task {
                await manager.resolvePendingContactProfile(publicKey: contactProfileKey) { try await interactive.fetch($0) }
            }
            await waitUntil("the screen's lookup is held, \(deletion.name)") { await interactive.heldCount >= 1 }

            try await deletion.delete(manager)
            // Add Contact saves through the SDK itself; an import adds the contact back with its fetched profile the same way.
            try await manager.importContacts(contacts: [PubkyContact(publicKey: contactProfileKey, profile: newer)]) { _, _ in }
            await interactive.release()
            await screenLookup.value

            let row = manager.contacts.first?.profile
            XCTAssertEqual(row?.name, "Alice Newer", "The deleted contact's lookup must not replace the re-added row, \(deletion.name)")
            XCTAssertEqual(row?.bio, "Newer bio", deletion.name)
            XCTAssertEqual(row?.imageUrl, newer.imageUrl, deletion.name)

            let reload = HeldProfileLookups(profiles: [:])
            try await manager.loadContacts(for: "owner", fetchContactRecords: { records }, fetchRemoteProfile: { try await reload.fetch($0) })
            XCTAssertEqual(
                manager.contacts.first?.profile.name,
                "Alice Newer",
                "Nor may it be remembered over the re-added profile, which a reload shows, \(deletion.name)"
            )
            let reloadedKeys = await reload.fetchedKeys
            XCTAssertEqual(reloadedKeys, [], "The re-added profile is still fresh, \(deletion.name)")
            await bulk.release()
            await manager.waitForProfileRefreshForTesting()
        }
    }

    /// Takes `slot`'s only read slot with another read and holds it until the returned lookups are released.
    private func holdTheOnlyReadSlot(_ slot: PaykitSdkReadLimiter) async throws -> HeldProfileLookups {
        let otherRead = HeldProfileLookups(profiles: [:])
        await otherRead.hold()
        Task { _ = try? await slot.withSlot(priority: .bulk) { try await otherRead.fetch("other") } }
        while await otherRead.heldCount < 1 {
            await Task.yield()
        }
        return otherRead
    }

    func testDeleteAllContactsThrowsWithoutActiveSession() async {
        let manager = ContactsManager()
        manager.contacts = [
            makeContact(publicKey: "pubkyaaa"),
            makeContact(publicKey: "pubkybbb"),
        ]

        do {
            try await manager.deleteAllContacts()
            XCTFail("Expected deleteAllContacts to throw without an active session")
        } catch {
            XCTAssertFalse(manager.contacts.isEmpty)
        }
    }

    func testFallbackRouteForMissingPendingImportUsesPayContacts() {
        XCTAssertEqual(fallbackRouteForMissingPendingImport(hasPendingImport: false), .payContacts)
        XCTAssertNil(fallbackRouteForMissingPendingImport(hasPendingImport: true))
    }

    func testResolvePastedPubkyRouteReturnsProfileForOwnKey() {
        enablePaykitUIForRouteTests()
        let ownPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(
            resolvePastedPubkyRoute(input: ownPublicKey, ownPublicKey: ownPublicKey, contacts: []),
            .profile
        )
    }

    func testResolvePastedPubkyRouteReturnsContactDetailForExistingContact() {
        enablePaykitUIForRouteTests()
        let contactKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(
            resolvePastedPubkyRoute(
                input: contactKey,
                ownPublicKey: "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg",
                contacts: [makeContact(publicKey: contactKey)]
            ),
            .contactDetail(publicKey: contactKey)
        )
    }

    func testResolvePastedPubkyRouteTrimsClipboardInput() {
        enablePaykitUIForRouteTests()
        let contactKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(
            resolvePastedPubkyRoute(
                input: "  \(contactKey)\n",
                ownPublicKey: nil,
                contacts: [makeContact(publicKey: contactKey)]
            ),
            .contactDetail(publicKey: contactKey)
        )
    }

    func testResolvePastedPubkyRouteReturnsAddContactForUnknownKey() {
        enablePaykitUIForRouteTests()
        let contactKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(
            resolvePastedPubkyRoute(
                input: contactKey,
                ownPublicKey: "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg",
                contacts: []
            ),
            .addContact(publicKey: contactKey)
        )
    }

    func testResolvePastedPubkyRouteReturnsNilForInvalidInput() {
        enablePaykitUIForRouteTests()

        XCTAssertNil(
            resolvePastedPubkyRoute(
                input: "not-a-pubky",
                ownPublicKey: nil,
                contacts: []
            )
        )
    }

    func testResolvePastedPubkyRouteReturnsNilWhenPaykitUIIsDisabled() {
        let contactKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertNil(
            resolvePastedPubkyRoute(
                input: contactKey,
                ownPublicKey: nil,
                contacts: [makeContact(publicKey: contactKey)]
            )
        )
    }

    private func enablePaykitUIForRouteTests() {
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
    }

    private func makeProfile(publicKey: String) -> Bitkit.PubkyProfile {
        Bitkit.PubkyProfile(
            publicKey: publicKey,
            name: "Alice",
            bio: "bio",
            imageUrl: nil,
            links: [],
            tags: [],
            status: nil
        )
    }

    private func makeContact(publicKey: String) -> Bitkit.PubkyContact {
        Bitkit.PubkyContact(publicKey: publicKey, profile: makeProfile(publicKey: publicKey))
    }
}

private let contactProfileKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
/// What the SDK returns both for a network failure and for a key with no pkarr record.
private let profileTransportError = PaykitError.Transport(code: "transport_error", context: "fetch profile")

private let unresolvedFollowKey = "pubky" + String(repeating: "y", count: 52)

private let publishedContactProfile = Bitkit.PubkyProfile(
    publicKey: contactProfileKey,
    name: "Alice",
    bio: "Hello",
    imageUrl: "pubky://alice/avatar",
    links: [PubkyProfileLink(label: "Site", url: "https://alice.example")],
    tags: [],
    status: nil
)

/// Answers profile lookups with the scripted profiles, failing for any other key like a key with no profile, and can hold
/// lookups until released.
private actor HeldProfileLookups {
    private let profiles: [String: Bitkit.PubkyProfile]
    private(set) var fetchedKeys: [String] = []
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int {
        held.count
    }

    init(profiles names: [String: String]) {
        profiles = Dictionary(uniqueKeysWithValues: names.map { publicKey, name in
            (publicKey, Bitkit.PubkyProfile(publicKey: publicKey, name: name, bio: "", imageUrl: nil, links: [], status: nil))
        })
    }

    init(publishedProfiles: [Bitkit.PubkyProfile]) {
        profiles = Dictionary(uniqueKeysWithValues: publishedProfiles.map { ($0.publicKey, $0) })
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func fetch(_ publicKey: String) async throws -> Bitkit.PubkyProfile? {
        fetchedKeys.append(publicKey)
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        guard let profile = profiles[publicKey] else { throw profileTransportError }
        return profile
    }
}

/// Answers profile lookups at once with the scripted profiles, failing for any other key, except for `holding`, whose
/// lookups wait until released.
private actor PartlyHeldProfileLookups {
    private let profiles: [String: Bitkit.PubkyProfile]
    private let heldKeys: Set<String>
    private var held: [CheckedContinuation<Void, Never>] = []

    init(profiles names: [String: String], holding heldKeys: Set<String>) {
        profiles = Dictionary(uniqueKeysWithValues: names.map { publicKey, name in
            (publicKey, Bitkit.PubkyProfile(publicKey: publicKey, name: name, bio: "", imageUrl: nil, links: [], status: nil))
        })
        self.heldKeys = heldKeys
    }

    init(publishedProfiles: [Bitkit.PubkyProfile], holding heldKeys: Set<String>) {
        profiles = Dictionary(uniqueKeysWithValues: publishedProfiles.map { ($0.publicKey, $0) })
        self.heldKeys = heldKeys
    }

    func release() {
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func fetch(_ publicKey: String) async throws -> Bitkit.PubkyProfile? {
        if heldKeys.contains(publicKey) {
            await withCheckedContinuation { held.append($0) }
        }
        guard let profile = profiles[publicKey] else { throw profileTransportError }
        return profile
    }
}

/// A clock the test moves by hand, for the time a contact profile was resolved.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current += interval
        lock.unlock()
    }
}

/// Records the read lane of each profile lookup, answering for `contactProfileKey` and failing for any other key.
private actor ProfileLookupLanes {
    private(set) var priorities: [PaykitPublicReadPriority] = []

    func fetch(_ publicKey: String, priority: PaykitPublicReadPriority) throws -> Bitkit.PubkyProfile? {
        priorities.append(priority)
        guard publicKey == contactProfileKey else { throw profileTransportError }
        return Bitkit.PubkyProfile(publicKey: publicKey, name: "Alice", bio: "", imageUrl: nil, links: [], status: nil)
    }
}

/// Answers each fetch with the next scripted outcome, repeating the last one once the script runs out.
private actor ContactProfileFetchStub {
    private(set) var attempts = 0
    private var outcomes: [Result<Bitkit.PubkyProfile?, Error>]

    init(_ outcomes: [Result<Bitkit.PubkyProfile?, Error>]) {
        self.outcomes = outcomes
    }

    func fetch(_: String) throws -> Bitkit.PubkyProfile? {
        attempts += 1
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try outcome.get()
    }
}

/// Stands in for `PubkyProfileManager.currentSession`: every sign-in and sign-out starts a new session.
@MainActor
private final class TestPubkySession {
    private var revision = 0

    func change() {
        revision += 1
    }

    /// True while the session that was current when this was called still is, as `ContactDetailView` builds it.
    func check() -> @MainActor () -> Bool {
        let started = revision
        return { self.revision == started }
    }
}

/// Stands in for `EditContactView`: the form the user edited, and the edit its Save builds once the contact's lookup is
/// done, by filling the form again from the contact's row and uploading a new avatar.
@MainActor
private final class ContactEditScreen {
    private(set) var form = ContactEditForm()
    private(set) var editsMade = 0
    private let manager: ContactsManager
    private let publicKey: String

    init(manager: ContactsManager, publicKey: String) {
        self.manager = manager
        self.publicKey = publicKey
        fillFromRow()
    }

    func edit(_ change: (inout ContactEditForm) -> Void) {
        change(&form)
    }

    func makeEdit(uploadAvatar: () async throws -> String? = { nil }) async throws -> ContactEdit {
        editsMade += 1
        fillFromRow()
        let uploadedImageUrl = try await uploadAvatar() ?? form.imageUrl
        return form.edit(imageUrl: uploadedImageUrl)
    }

    private func fillFromRow() {
        guard let row = manager.contacts.first(where: { $0.publicKey == publicKey }) else { return }
        form.fill(from: row.profile)
    }
}

private struct ContactNotSavedError: Error {}

/// Stands in for the SDK's contact storage of whichever identity is signed in. Like the SDK, it saves a label only for a
/// contact that identity has saved, and only while the identity the save is for is signed in, checked together with the
/// write. It can hold saves, as the SDK lock would, until released.
private actor SignedInContactStore {
    private var identity: String
    private var savedKeys: Set<String>
    private(set) var savedLabels: [String] = []
    /// The identity each save it refused was for.
    private(set) var refusedIdentities: [String] = []
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int {
        held.count
    }

    init(identity: String, savedKeys: Set<String>) {
        self.identity = identity
        self.savedKeys = savedKeys
    }

    func signIn(identity: String, savedKeys: Set<String>) {
        self.identity = identity
        self.savedKeys = savedKeys
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func save(_ publicKey: String, label: String, expectedIdentity: String) async throws {
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        guard expectedIdentity == identity else {
            refusedIdentities.append(expectedIdentity)
            throw PubkyServiceError.identityChanged
        }
        guard savedKeys.contains(publicKey) else { throw ContactNotSavedError() }
        savedLabels.append(label)
    }
}

/// Records the label of each contact save.
private actor SavedContactLabels {
    private(set) var labels: [String] = []

    func save(_: String, label: String) {
        labels.append(label)
    }
}

private actor SuspendedContactRecords {
    private var records: [ContactRecord]
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldPause = true

    var isPaused: Bool {
        continuation != nil
    }

    init(records: [ContactRecord]) {
        self.records = records
    }

    func load() async -> [ContactRecord] {
        let snapshot = records
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation = $0 }
        }
        return snapshot
    }

    func resume(with records: [ContactRecord]) {
        self.records = records
        continuation?.resume()
        continuation = nil
    }
}
