@testable import Bitkit
import XCTest

private actor SharedPubkyTestEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

final class SharedPubkyIdentityTests: XCTestCase {
    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func testFixtureMatchesRingSecretAndPubkyWireFormats() throws {
        let (_, bare, secret) = try identityFixture()

        XCTAssertEqual(secret.count, 64)
        XCTAssertNotNil(secret.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(bare.count, 52)
        XCTAssertEqual(SharedPubkyKeyFormat.normalizedBare(bare), bare)
    }

    func testReferenceCanonicalizesPrefixedPubkyToBareWireFormat() throws {
        let (prefixed, bare, _) = try identityFixture()

        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: prefixed)

        XCTAssertEqual(reference.pubky, bare)
        XCTAssertFalse(reference.pubky.hasPrefix("pubky"))
        XCTAssertEqual(reference.pubky.count, 52)
        XCTAssertEqual(
            SharedPubkyIdentityVault.account(source: .ring, pubky: reference.pubky),
            "app.pubkyring:\(bare)"
        )
    }

    func testSharedWireFormatRejectsOverlongPubky() throws {
        let (_, bare, _) = try identityFixture()

        XCTAssertNil(SharedPubkyKeyFormat.normalizedBare("\(bare)y"))
        XCTAssertNil(SharedPubkyKeyFormat.normalizedBare("pubky\(bare)y"))
    }

    func testDiscoveryFiltersMalformedAndOtherSourceAccountsWithoutLoadingPayloads() throws {
        let (_, bare, _) = try identityFixture()
        let accounts = [
            "app.pubkyring:\(bare)",
            "app.pubkyring:\(bare)",
            "to.bitkit:\(bare)",
            "app.pubkyring:not-a-pubky",
            "app.pubkyring:\(bare)y",
            "unexpected:\(bare)",
        ]

        let references = SharedPubkyIdentityVault.references(accounts: accounts, source: .ring)

        XCTAssertEqual(references, try [SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)])
    }

    func testBitkitOwnedDeletionCandidatesPreserveRingOwnedAccount() throws {
        let (_, bare, _) = try identityFixture()
        let accounts = [
            SharedPubkyIdentityVault.account(source: .ring, pubky: bare),
            SharedPubkyIdentityVault.account(source: .bitkit, pubky: bare),
            "to.bitkit:malformed-but-owned",
        ]

        let exactDeletionAccounts = SharedPubkyIdentityVault.ownedAccounts(
            accounts: accounts,
            source: .bitkit
        )

        XCTAssertEqual(
            exactDeletionAccounts,
            ["to.bitkit:\(bare)", "to.bitkit:malformed-but-owned"].sorted()
        )
        XCTAssertFalse(exactDeletionAccounts.contains("app.pubkyring:\(bare)"))
    }

    func testReconciliationRemovesStaleBitkitMirrorAndPreservesRingMirror() throws {
        let (_, bare, _) = try identityFixture()
        let staleBare = String(repeating: "y", count: 52)
        let currentAccount = SharedPubkyIdentityVault.account(source: .bitkit, pubky: bare)
        let staleAccount = SharedPubkyIdentityVault.account(source: .bitkit, pubky: staleBare)
        let ringAccount = SharedPubkyIdentityVault.account(source: .ring, pubky: staleBare)
        var accounts = [currentAccount, staleAccount, ringAccount]
        var deletedAccounts: [String] = []

        try SharedPubkyIdentityVault.pruneStaleBitkitIdentities(
            keeping: currentAccount,
            listAccounts: { accounts },
            deleteAccount: { account in
                deletedAccounts.append(account)
                accounts.removeAll { $0 == account }
            }
        )

        XCTAssertEqual(deletedAccounts, [staleAccount])
        XCTAssertEqual(accounts.sorted(), [currentAccount, ringAccount].sorted())
    }

    func testOrphanCleanupDeletesSharedMirrorBeforePrivateAndRNKeychains() throws {
        var events: [String] = []

        try OrphanedKeychainCleanup.perform(
            hasNativeKeychain: true,
            hasOrphanedRNKeychain: true,
            deleteBitkitSharedIdentities: { events.append("shared") },
            wipePrivateKeychain: { events.append("private") },
            cleanupRNKeychain: { events.append("rn") }
        )

        XCTAssertEqual(events, ["shared", "private", "rn"])
    }

    func testOrphanCleanupPreservesPrivateStateWhenSharedMirrorDeletionFails() {
        var events: [String] = []

        XCTAssertThrowsError(try OrphanedKeychainCleanup.perform(
            hasNativeKeychain: true,
            hasOrphanedRNKeychain: true,
            deleteBitkitSharedIdentities: {
                events.append("shared")
                throw SharedPubkyIdentityError.unavailable
            },
            wipePrivateKeychain: { events.append("private") },
            cleanupRNKeychain: { events.append("rn") }
        ))

        XCTAssertEqual(events, ["shared"])
    }

    func testCredentialValidationAcceptsMatchingSecret() throws {
        let (_, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)
        let record = SharedPubkyIdentityRecordV1(
            sourceApp: .ring,
            pubky: bare,
            secretKey: secret
        )

        XCTAssertNoThrow(try SharedPubkyIdentityVault.validate(
            record: record,
            expected: reference,
            derivePublicKey: { try PubkyProfileManager.publicKeyFromSecretKey($0) }
        ))
    }

    func testCredentialValidationRejectsClaimedKeyMismatch() throws {
        let (_, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)
        let record = SharedPubkyIdentityRecordV1(
            sourceApp: .ring,
            pubky: bare,
            secretKey: secret
        )
        let differentBare = String(repeating: "y", count: 52)

        XCTAssertThrowsError(try SharedPubkyIdentityVault.validate(
            record: record,
            expected: reference,
            derivePublicKey: { _ in "pubky\(differentBare)" }
        )) { error in
            XCTAssertEqual(error as? SharedPubkyIdentityError, .secretDoesNotMatchPublicKey)
        }
    }

    func testCredentialValidationRejectsNoncanonicalSecretEncoding() throws {
        let (_, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)
        let record = SharedPubkyIdentityRecordV1(
            sourceApp: .ring,
            pubky: bare,
            secretKey: secret.uppercased()
        )

        XCTAssertThrowsError(try SharedPubkyIdentityVault.validate(
            record: record,
            expected: reference,
            derivePublicKey: { _ in "pubky\(bare)" }
        )) { error in
            XCTAssertEqual(error as? SharedPubkyIdentityError, .invalidRecord)
        }
    }

    func testSharedSessionRestoreKeepsBareReferenceAtWireBoundary() async throws {
        let (prefixed, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)

        let result = await PubkyProfileManager.resolveSharedSessionInitialization(
            reference: reference,
            savedSessionSecret: "saved-session",
            sharedSecretKey: secret,
            importSession: { session in
                XCTAssertEqual(session, "saved-session")
                return prefixed
            },
            signInWithSharedSecret: { _ in
                XCTFail("A valid persisted session should not require the shared credential")
                return "unused"
            },
            currentPublicKey: {
                XCTFail("A valid persisted session should not re-query SDK identity")
                return nil
            }
        )

        XCTAssertEqual(result, .restored(publicKey: prefixed))
    }

    func testSharedSessionRestoreUsesCredentialWithoutClassifyingItAsLocal() async throws {
        let (prefixed, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)
        var receivedSecret: String?

        let result = await PubkyProfileManager.resolveSharedSessionInitialization(
            reference: reference,
            savedSessionSecret: nil,
            sharedSecretKey: secret,
            importSession: { _ in
                XCTFail("No persisted session exists")
                return "unused"
            },
            signInWithSharedSecret: { value in
                receivedSecret = value
                return "fresh-session"
            },
            currentPublicKey: { prefixed }
        )

        XCTAssertEqual(receivedSecret, secret)
        XCTAssertEqual(result, .restored(publicKey: prefixed))
    }

    func testSharedIdentityAdoptionPersistsReferenceBeforeSession() async throws {
        let (prefixed, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)
        var events: [String] = []

        let result = try await PubkyProfileManager.establishSharedIdentitySession(
            reference: reference,
            secretKey: secret,
            saveReference: { saved in
                XCTAssertEqual(saved, reference)
                events.append("reference")
            },
            signIn: { receivedSecret in
                XCTAssertEqual(receivedSecret, secret)
                events.append("session")
                return "fresh-session"
            },
            currentPublicKey: { prefixed },
            clearSession: {
                XCTFail("Successful adoption should not clear its session")
            },
            deleteReference: {
                XCTFail("Successful adoption should not delete its reference")
            }
        )

        XCTAssertEqual(result, prefixed)
        XCTAssertEqual(events, ["reference", "session"])
    }

    func testSharedIdentityAdoptionRollsBackReferenceAndSessionOnFailure() async throws {
        let (_, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)
        var events: [String] = []

        do {
            _ = try await PubkyProfileManager.establishSharedIdentitySession(
                reference: reference,
                secretKey: secret,
                saveReference: { _ in events.append("reference") },
                signIn: { _ in
                    events.append("session")
                    throw PubkyServiceError.authFailed("offline")
                },
                currentPublicKey: { nil },
                clearSession: { events.append("clear-session") },
                deleteReference: { events.append("delete-reference") }
            )
            XCTFail("Expected failed sign-in to roll back")
        } catch {
            XCTAssertEqual(
                events,
                ["reference", "session", "clear-session", "delete-reference"]
            )
        }
    }

    func testSharedIdentityCleanupClearsSessionBeforeReference() async throws {
        var events: [String] = []

        try await PubkyProfileManager.clearSharedIdentitySession(
            clearSession: { events.append("session") },
            deleteReference: { events.append("reference") }
        )

        XCTAssertEqual(events, ["session", "reference"])
    }

    func testSharedIdentityCleanupKeepsReferenceWhenSessionDeletionFails() async {
        var events: [String] = []

        do {
            try await PubkyProfileManager.clearSharedIdentitySession(
                clearSession: {
                    events.append("session")
                    throw KeychainError.failedToDelete
                },
                deleteReference: { events.append("reference") }
            )
            XCTFail("Expected session deletion failure")
        } catch {
            XCTAssertEqual(events, ["session"])
        }
    }

    func testIdentityLifecycleTransactionsDoNotInterleave() async {
        let events = SharedPubkyTestEventLog()
        let firstStarted = expectation(description: "first lifecycle transaction started")

        async let first: Void = PubkyProfileManager.withIdentityLifecycleLock {
            await events.append("first-start")
            firstStarted.fulfill()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await events.append("first-end")
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        async let second: Void = PubkyProfileManager.withIdentityLifecycleLock {
            await events.append("second")
        }

        _ = await (first, second)
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["first-start", "first-end", "second"])
    }

    func testActiveIdentityRejectsLocalAndSharedProvenanceCoexistence() throws {
        let (prefixed, bare, secret) = try identityFixture()
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .ring, pubky: bare)

        XCTAssertThrowsError(try PubkyProfileManager.resolveActiveIdentitySecretKey(
            expectedPublicKey: prefixed,
            reference: reference,
            localSecret: secret,
            isSourceAvailable: true,
            loadSharedCredential: { _ in
                XCTFail("A provenance conflict must fail before reading shared credentials")
                return secret
            }
        )) { error in
            XCTAssertEqual(error as? SharedPubkyIdentityError, .provenanceConflict)
        }
    }

    func testActiveOwnedIdentityMustMatchExpectedPublicKey() throws {
        let (_, _, secret) = try identityFixture()
        let differentPublicKey = "pubky\(String(repeating: "y", count: 52))"

        XCTAssertThrowsError(try PubkyProfileManager.resolveActiveIdentitySecretKey(
            expectedPublicKey: differentPublicKey,
            reference: nil,
            localSecret: secret,
            isSourceAvailable: false,
            loadSharedCredential: { _ in secret }
        )) { error in
            XCTAssertEqual(error as? SharedPubkyIdentityError, .provenanceConflict)
        }
    }

    func testBorrowedSessionNeverPersistsExportedLocalSecret() throws {
        let (_, _, secret) = try identityFixture()
        let exportedLocalSecret = try PaykitSdkService.localSecretKey(fromHex: secret)

        XCTAssertNil(try PaykitSdkService.localSecretKeyHexForPersistence(
            exportedLocalSecret,
            shouldStoreLocalSecret: false
        ))
        XCTAssertEqual(
            try PaykitSdkService.localSecretKeyHexForPersistence(
                exportedLocalSecret,
                shouldStoreLocalSecret: true
            ),
            secret
        )
        XCTAssertThrowsError(try PaykitSdkService.localSecretKeyHexForPersistence(
            nil,
            shouldStoreLocalSecret: true
        ))
    }

    private func identityFixture() throws -> (prefixed: String, bare: String, secret: String) {
        let secret = try PubkyService.derivePubkySecretKey(mnemonic: mnemonic)
        let prefixed = try PubkyProfileManager.publicKeyFromSecretKey(secret)
        let bare = try XCTUnwrap(SharedPubkyKeyFormat.normalizedBare(prefixed))
        return (prefixed, bare, secret)
    }
}
