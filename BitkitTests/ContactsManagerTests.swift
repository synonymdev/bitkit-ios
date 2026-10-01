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

    /// General Settings used to await this in its `.task`, so leaving mid-load surfaced the cancellation as an error toast.
    func testCancelledLoadContactsIfNeededLeavesTheLoadToAnUncancelledCaller() async throws {
        let record = contactRecord(key: "pubky" + String(repeating: "y", count: 52), name: "Contact")
        let source = SuspendedContactRecords(records: [record])
        let manager = ContactsManager(contactRecords: { await source.load() })
        let screenLoad = Task { try await manager.loadContactsIfNeeded(for: "owner") }
        while await !(source.isPaused) {
            await Task.yield()
        }
        let enable = Task { try await manager.loadContactsIfNeeded(for: "owner") }
        await Task.yield()
        screenLoad.cancel()
        await source.resume(with: [record])

        let screenResult = await screenLoad.result
        XCTAssertThrowsError(try screenResult.get()) { XCTAssertTrue($0 is CancellationError, "Expected cancellation, got \($0)") }
        try await enable.value
        XCTAssertTrue(manager.hasLoaded)
        XCTAssertEqual(manager.contacts.map(\.publicKey), [record.publicKey])
        XCTAssertNil(manager.loadErrorMessage)
        XCTAssertFalse(manager.isLoading)
    }

    func testLoadContactsIfNeededFinishesAfterTheContactsScreenLoadItWaitedOnIsCancelled() async throws {
        let record = contactRecord(key: "pubky" + String(repeating: "y", count: 52), name: "Contact")
        let source = SuspendedContactRecords(records: [record])
        let manager = ContactsManager(contactRecords: { await source.load() })
        let contactsScreenLoad = Task { try await manager.loadContacts(for: "owner") }
        while await !(source.isPaused) {
            await Task.yield()
        }
        let enable = Task { try await manager.loadContactsIfNeeded(for: "owner") }
        await Task.yield()
        contactsScreenLoad.cancel()
        await source.resume(with: [record])

        try await contactsScreenLoad.value
        try await enable.value
        XCTAssertTrue(manager.hasLoaded)
        XCTAssertEqual(manager.contacts.map(\.publicKey), [record.publicKey])
        XCTAssertNil(manager.loadErrorMessage)
        XCTAssertFalse(manager.isLoading)
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

        let profile = try await ContactsManager.resolveContactProfile(
            publicKey: contactProfileKey,
            includePlaceholder: true,
            fetchRemoteProfile: { try await stub.fetch($0) }
        )

        XCTAssertEqual(profile.name, Bitkit.PubkyProfile.placeholder(publicKey: contactProfileKey).name)
        let attempts = await stub.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testUserInitiatedContactProfileLookupRetriesTransportErrorOnce() async throws {
        let stub = ContactProfileFetchStub([.failure(profileTransportError), .success(makeProfile(publicKey: contactProfileKey))])

        let profile = try await ContactsManager.resolveContactProfile(
            publicKey: contactProfileKey,
            includePlaceholder: true,
            retryTransient: true,
            fetchRemoteProfile: { try await stub.fetch($0) }
        )

        XCTAssertEqual(profile.name, "Alice")
        let attempts = await stub.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testUserInitiatedContactProfileLookupFallsBackToPlaceholderAfterOneRetry() async throws {
        let stub = ContactProfileFetchStub([.failure(profileTransportError)])

        let profile = try await ContactsManager.resolveContactProfile(
            publicKey: contactProfileKey,
            includePlaceholder: true,
            retryTransient: true,
            fetchRemoteProfile: { try await stub.fetch($0) }
        )

        XCTAssertEqual(profile.name, Bitkit.PubkyProfile.placeholder(publicKey: contactProfileKey).name)
        let attempts = await stub.attempts
        XCTAssertEqual(attempts, 2)
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

    func testImportSavesPreparedProfilesAndKeepsUnresolvedFollowsAsPlaceholders() async throws {
        let manager = ContactsManager()
        let placeholderName = Bitkit.PubkyProfile.placeholder(publicKey: unresolvedFollowKey).name
        await manager.discoverRemoteContacts(
            publicKey: "owner",
            fetchFollows: { _ in [contactProfileKey, unresolvedFollowKey] },
            fetchRemoteProfile: { key in
                guard key == contactProfileKey else { throw profileTransportError }
                return Bitkit.PubkyProfile(publicKey: key, name: "Alice", bio: "", imageUrl: nil, links: [], status: nil)
            }
        )
        XCTAssertEqual(Set(manager.pendingImportContacts.map(\.displayName)), ["Alice", placeholderName])
        let stub = ImportStub()

        try await manager.importContacts(
            manager.pendingImportContacts,
            discoverReceiverPaths: { await stub.discover($0) },
            saveContact: { try await stub.save($0, label: $1, receiverPaths: $2) }
        )

        let discoveredKeys = await stub.discoveredKeys
        XCTAssertEqual(discoveredKeys, [contactProfileKey], "Only resolved follows run receiver discovery")
        let saves = await stub.saves
        XCTAssertEqual(saves[contactProfileKey]?.label, "Alice")
        XCTAssertEqual(saves[contactProfileKey]?.receiverPaths, [PaykitReceiverPath.wallet, PaykitReceiverPath.server])
        XCTAssertEqual(saves[unresolvedFollowKey]?.label, placeholderName)
        XCTAssertEqual(saves[unresolvedFollowKey]?.receiverPaths, [PaykitReceiverPath.wallet])
        XCTAssertEqual(Set(manager.contacts.map(\.displayName)), ["Alice", placeholderName])
    }

    func testImportSkipsOnlyContactsWhoseSaveFails() async throws {
        let alice = makeContact(publicKey: contactProfileKey)
        let other = makeContact(publicKey: unresolvedFollowKey)
        let manager = ContactsManager()
        let stub = ImportStub()
        await stub.failSaves(for: [unresolvedFollowKey])

        try await manager.importContacts(
            [alice, other],
            discoverReceiverPaths: { await stub.discover($0) },
            saveContact: { try await stub.save($0, label: $1, receiverPaths: $2) }
        )

        XCTAssertEqual(manager.contacts.map(\.publicKey), [contactProfileKey])

        let failingManager = ContactsManager()
        await stub.failSaves(for: [contactProfileKey, unresolvedFollowKey])
        do {
            try await failingManager.importContacts(
                [alice, other],
                discoverReceiverPaths: { await stub.discover($0) },
                saveContact: { try await stub.save($0, label: $1, receiverPaths: $2) }
            )
            XCTFail("Expected an import whose every save failed to throw")
        } catch {
            XCTAssertTrue(failingManager.contacts.isEmpty)
        }
    }

    func testImportSavesNothingMoreAfterReset() async throws {
        let manager = ContactsManager()
        let stub = ImportStub()
        await stub.holdDiscovery()
        let contactsToImport = [makeContact(publicKey: contactProfileKey), makeContact(publicKey: unresolvedFollowKey)]
        let importTask = Task {
            try await manager.importContacts(
                contactsToImport,
                discoverReceiverPaths: { await stub.discover($0) },
                saveContact: { try await stub.save($0, label: $1, receiverPaths: $2) }
            )
        }
        while await stub.heldDiscoveryCount < 2 {
            await Task.yield()
        }

        manager.reset()
        await stub.releaseDiscovery()

        let result = await importTask.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "Expected cancellation, got \($0)") }
        let saves = await stub.saves
        XCTAssertTrue(saves.isEmpty)
        XCTAssertTrue(manager.contacts.isEmpty)
    }

    func testShouldDiscardPendingImportWhenLeavingImportFlow() {
        XCTAssertTrue(shouldDiscardPendingImport(currentRoute: .contactImportOverview, destination: .contacts))
        XCTAssertTrue(shouldDiscardPendingImport(currentRoute: .contactImportSelect, destination: nil))
    }

    func testShouldNotDiscardPendingImportWhenStayingInsideImportFlow() {
        XCTAssertFalse(shouldDiscardPendingImport(currentRoute: .contactImportOverview, destination: .contactImportSelect))
        XCTAssertFalse(shouldDiscardPendingImport(currentRoute: .contacts, destination: .profile))
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

/// Answers profile lookups with the scripted names, failing for any other key like a key with no profile, and can hold
/// lookups until released.
private actor HeldProfileLookups {
    private let profiles: [String: String]
    private(set) var fetchedKeys: [String] = []
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int {
        held.count
    }

    init(profiles: [String: String]) {
        self.profiles = profiles
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
        guard let name = profiles[publicKey] else { throw profileTransportError }
        return Bitkit.PubkyProfile(publicKey: publicKey, name: name, bio: "", imageUrl: nil, links: [], status: nil)
    }
}

/// Records an import's receiver discovery and saves, and can fail saves or hold discovery until released.
private actor ImportStub {
    private(set) var discoveredKeys: [String] = []
    private(set) var saves: [String: (label: String, receiverPaths: [String])] = [:]
    private var failingSaveKeys: Set<String> = []
    private var isHoldingDiscovery = false
    private var heldDiscoveries: [CheckedContinuation<Void, Never>] = []

    var heldDiscoveryCount: Int {
        heldDiscoveries.count
    }

    func failSaves(for keys: Set<String>) {
        failingSaveKeys = keys
    }

    func holdDiscovery() {
        isHoldingDiscovery = true
    }

    func releaseDiscovery() {
        isHoldingDiscovery = false
        heldDiscoveries.forEach { $0.resume() }
        heldDiscoveries.removeAll()
    }

    func discover(_ publicKey: String) async -> [String] {
        discoveredKeys.append(publicKey)
        if isHoldingDiscovery {
            await withCheckedContinuation { heldDiscoveries.append($0) }
        }
        return [PaykitReceiverPath.wallet, PaykitReceiverPath.server]
    }

    func save(_ publicKey: String, label: String, receiverPaths: [String]) throws {
        if failingSaveKeys.contains(publicKey) {
            throw PubkyServiceError.sessionNotActive
        }
        saves[publicKey] = (label, receiverPaths)
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
