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
            saveContactLabel: { await savedLabels.save($0, label: $1) }
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
        let first = manager.updateContactTags(publicKey: contactProfileKey, shownProfile: shown) { $0 + ["friend"] }
        let second = manager.updateContactTags(publicKey: contactProfileKey, shownProfile: shown.withTags(["friend"])) { $0 + ["work"] }
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
