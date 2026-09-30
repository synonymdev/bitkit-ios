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
                if let value { try Keychain.upsert(key: key, data: value) }
                else { try Keychain.delete(key: key) }
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

    func testImportPreservesSavedContactsOnFailureAndRetriesMissingContacts() async throws {
        let manager = ContactsManager()
        let alice = makeContact(publicKey: "pubky-alice")
        let bob = makeContact(publicKey: "pubky-bob")
        var saved: [String] = []
        do {
            try await manager.importContacts(contacts: [alice, bob]) { key, _ in
                if key == bob.publicKey { throw CocoaError(.fileWriteUnknown) }
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
                if key == prepared[1].publicKey { throw CancellationError() }
            }
            XCTFail("Import should propagate cancellation")
        } catch is CancellationError {
            XCTAssertEqual(attempted, Array(prepared.prefix(2)).map(\.publicKey))
            XCTAssertTrue(manager.contacts.isEmpty)
        }
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
