@testable import Bitkit
import XCTest

@MainActor
final class ContactsManagerTests: XCTestCase {
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
        manager.pendingImportProfile = profile
        manager.pendingImportContacts = [contact]

        manager.clearPendingImport()

        XCTAssertEqual(manager.contacts, [contact])
        XCTAssertTrue(manager.hasLoaded)
        XCTAssertEqual(manager.loadErrorMessage, "still here")
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
        let ownPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        XCTAssertEqual(
            resolvePastedPubkyRoute(input: ownPublicKey, ownPublicKey: ownPublicKey, contacts: []),
            .profile
        )
    }

    func testResolvePastedPubkyRouteReturnsContactDetailForExistingContact() {
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

    func testResolvePastedPubkyRouteReturnsAddContactForUnknownKey() {
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
        XCTAssertNil(
            resolvePastedPubkyRoute(
                input: "not-a-pubky",
                ownPublicKey: nil,
                contacts: []
            )
        )
    }

    private func makeProfile(publicKey: String) -> PubkyProfile {
        PubkyProfile(
            publicKey: publicKey,
            name: "Alice",
            bio: "bio",
            imageUrl: nil,
            links: [],
            tags: [],
            status: nil
        )
    }

    private func makeContact(publicKey: String) -> PubkyContact {
        PubkyContact(publicKey: publicKey, profile: makeProfile(publicKey: publicKey))
    }
}
