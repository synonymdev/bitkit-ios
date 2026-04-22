@testable import Bitkit
import XCTest

final class PubkyProfileManagerTests: XCTestCase {
    // MARK: - HomegateResponse Decoding

    private typealias HomegateResponse = PubkyProfileManager.HomegateResponse

    func testHomegateResponseDecodesCamelCase() throws {
        let json = """
        {"signupCode":"abc-123","homeserverPubky":"z6MkPubkyTestKey"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HomegateResponse.self, from: data)

        XCTAssertEqual(response.signupCode, "abc-123")
        XCTAssertEqual(response.homeserverPubky, "z6MkPubkyTestKey")
    }

    func testHomegateResponseRejectsIncompleteJson() {
        let json = """
        {"signupCode":"abc-123"}
        """
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(HomegateResponse.self, from: data))
    }

    func testHomegateResponseRejectsEmptyJson() {
        let json = "{}"
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(HomegateResponse.self, from: data))
    }

    func testHomegateResponseWithExtraFieldsDecodes() throws {
        let json = """
        {"signupCode":"abc","homeserverPubky":"z6Mk","extra":"ignored"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HomegateResponse.self, from: data)

        XCTAssertEqual(response.signupCode, "abc")
        XCTAssertEqual(response.homeserverPubky, "z6Mk")
    }

    // MARK: - Image Resolution

    func testResolvedImageUrlPrefersNewImage() {
        let resolved = PubkyProfileManager.resolvedImageUrl(
            newImageUrl: "pubky://new-avatar",
            existingImageUrl: "pubky://existing-avatar"
        )

        XCTAssertEqual(resolved, "pubky://new-avatar")
    }

    func testResolvedImageUrlFallsBackToExistingImage() {
        let resolved = PubkyProfileManager.resolvedImageUrl(
            newImageUrl: nil,
            existingImageUrl: "pubky://existing-avatar"
        )

        XCTAssertEqual(resolved, "pubky://existing-avatar")
    }

    func testResolvedImageUrlAllowsMissingAvatar() {
        let resolved = PubkyProfileManager.resolvedImageUrl(
            newImageUrl: nil,
            existingImageUrl: nil
        )

        XCTAssertNil(resolved)
    }

    // MARK: - Remote Profile Resolution

    func testResolveRemoteProfilePrefersBitkitProfile() async throws {
        let bitkitProfile = makeProfile(publicKey: "pubky_test", name: "Bitkit")
        let pubkyFallback = makeProfile(publicKey: "pubky_test", name: "Pubky")

        let resolved = try await PubkyProfileManager.resolveRemoteProfile(
            publicKey: "pubky_test",
            fetchBitkitProfile: { _ in bitkitProfile },
            fetchPubkyProfile: { _ in
                XCTFail("Expected bitkit profile to win before pubky fallback")
                return pubkyFallback
            }
        )

        XCTAssertEqual(resolved.name, "Bitkit")
    }

    func testResolveRemoteProfileFallsBackToPubkyProfile() async throws {
        let fallbackProfile = makeProfile(publicKey: "pubky_test", name: "Pubky")

        let resolved = try await PubkyProfileManager.resolveRemoteProfile(
            publicKey: "pubky_test",
            fetchBitkitProfile: { _ in nil },
            fetchPubkyProfile: { _ in fallbackProfile }
        )

        XCTAssertEqual(resolved.name, "Pubky")
    }

    func testResolveRemoteProfileThrowsWhenNoRemoteProfileExists() async {
        await XCTAssertThrowsErrorAsync {
            try await PubkyProfileManager.resolveRemoteProfile(
                publicKey: "pubky_missing",
                fetchBitkitProfile: { _ in nil },
                fetchPubkyProfile: { _ in throw PubkyServiceError.profileNotFound }
            )
        }
    }

    // MARK: - Session backup state

    func testSnapshotSessionBackupStatePrefersLocalSeedOverSessionSecret() throws {
        let store = makeKeychainStore(
            paykitSession: "session-secret",
            pubkySecretKey: "local-secret"
        )

        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { key in
            store[key.storageKey]
        }

        XCTAssertEqual(snapshot, PubkySessionBackupV1(kind: .localSeed, sessionSecret: nil))
    }

    func testSnapshotSessionBackupStateUsesExternalSessionWhenNoLocalSeed() throws {
        let store = makeKeychainStore(paykitSession: "external-session")

        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { key in
            store[key.storageKey]
        }

        XCTAssertEqual(snapshot, PubkySessionBackupV1(kind: .externalSession, sessionSecret: "external-session"))
    }

    func testSnapshotSessionBackupStateReturnsNilWhenNoPubkyCredentialsExist() throws {
        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { _ in nil }

        XCTAssertNil(snapshot)
    }

    func testResolveSessionInitializationRestoresSavedSessionWithoutReSigningIn() async {
        var persistedSession: String?

        let result = await PubkyProfileManager.resolveSessionInitialization(
            savedSessionSecret: "saved-session",
            storedSecretKeyHex: "local-secret",
            importSession: { secret in
                XCTAssertEqual(secret, "saved-session")
                return "pubky_saved"
            },
            signInWithSecretKey: { _ in
                XCTFail("Expected saved session import to succeed without re-sign-in")
                return "new-session"
            },
            persistSessionSecret: { persistedSession = $0 },
            deleteSessionSecret: {
                XCTFail("Session should not be deleted after successful import")
            }
        )

        XCTAssertEqual(result, .restored(publicKey: "pubky_saved"))
        XCTAssertNil(persistedSession)
    }

    func testResolveSessionInitializationSignsInWhenOnlySecretKeyExists() async {
        var persistedSession: String?

        let result = await PubkyProfileManager.resolveSessionInitialization(
            savedSessionSecret: nil,
            storedSecretKeyHex: "local-secret",
            importSession: { secret in
                XCTAssertEqual(secret, "new-session")
                return "pubky_test"
            },
            signInWithSecretKey: { secretKey in
                XCTAssertEqual(secretKey, "local-secret")
                return "new-session"
            },
            persistSessionSecret: { persistedSession = $0 },
            deleteSessionSecret: {
                XCTFail("Session should not be deleted after successful re-sign-in")
            }
        )

        XCTAssertEqual(result, .restored(publicKey: "pubky_test"))
        XCTAssertEqual(persistedSession, "new-session")
    }

    func testResolveSessionInitializationDeletesSavedSessionWhenReSignInFails() async {
        var deletedSavedSession = false

        let result = await PubkyProfileManager.resolveSessionInitialization(
            savedSessionSecret: "stale-session",
            storedSecretKeyHex: "local-secret",
            importSession: { _ in
                throw PubkyServiceError.authFailed("stale session")
            },
            signInWithSecretKey: { _ in
                throw PubkyServiceError.authFailed("sign in failed")
            },
            persistSessionSecret: { _ in
                XCTFail("No session should be persisted when re-sign-in fails")
            }, deleteSessionSecret: {
                deletedSavedSession = true
            }
        )

        XCTAssertEqual(result, .restorationFailed)
        XCTAssertTrue(deletedSavedSession)
    }

    func testResolveSessionInitializationReturnsNoSessionWhenNoCredentialsExist() async {
        let result = await PubkyProfileManager.resolveSessionInitialization(
            savedSessionSecret: nil,
            storedSecretKeyHex: nil,
            importSession: { _ in
                XCTFail("No session should be imported without credentials")
                return "pubky_unused"
            },
            signInWithSecretKey: { _ in
                XCTFail("No sign-in should occur without credentials")
                return "unused-session"
            },
            persistSessionSecret: { _ in
                XCTFail("No session should be persisted without credentials")
            }, deleteSessionSecret: {
                XCTFail("No saved session exists to delete")
            }
        )

        XCTAssertEqual(result, .noSession)
    }

    func testRestoreSessionBackupStateForExternalSessionClearsLocalSecret() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "local-secret"
        )
        var didForceSignOut = false

        try await PubkyProfileManager.restoreSessionBackupState(
            PubkySessionBackupV1(kind: .externalSession, sessionSecret: "external-session"),
            loadKeychainString: { key in
                store[key.storageKey]
            },
            persistKeychainString: { key, value in
                store[key.storageKey] = value
            },
            deleteKeychainValue: { key in
                store.removeValue(forKey: key.storageKey)
            },
            forceSignOut: {
                didForceSignOut = true
            }
        )

        XCTAssertTrue(didForceSignOut)
        XCTAssertEqual(store[KeychainEntryType.paykitSession.storageKey], "external-session")
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
    }

    func testRestoreSessionBackupStateClearsCredentialsWhenBackupHasNoPubkyState() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "local-secret"
        )

        try await PubkyProfileManager.restoreSessionBackupState(
            nil,
            loadKeychainString: { key in
                store[key.storageKey]
            },
            persistKeychainString: { key, value in
                store[key.storageKey] = value
            },
            deleteKeychainValue: { key in
                store.removeValue(forKey: key.storageKey)
            },
            forceSignOut: {}
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
    }

    func testRestoreSessionBackupStateForLocalSeedDerivesSecretAndClearsSession() async throws {
        var store = makeKeychainStore(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            paykitSession: "stale-session"
        )

        try await PubkyProfileManager.restoreSessionBackupState(
            PubkySessionBackupV1(kind: .localSeed, sessionSecret: nil),
            loadKeychainString: { key in
                store[key.storageKey]
            },
            persistKeychainString: { key, value in
                store[key.storageKey] = value
            },
            deleteKeychainValue: { key in
                store.removeValue(forKey: key.storageKey)
            },
            forceSignOut: {}
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertFalse(store[KeychainEntryType.pubkySecretKey.storageKey, default: ""].isEmpty)
    }

    // MARK: - Metadata backup payload

    func testMetadataBackupV1RoundTripsPubkySession() throws {
        let payload = MetadataBackupV1(
            version: 1,
            createdAt: 123,
            tagMetadata: [],
            cache: makeAppCacheData(),
            pubkySession: PubkySessionBackupV1(kind: .externalSession, sessionSecret: "session-secret")
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MetadataBackupV1.self, from: encoded)

        XCTAssertEqual(decoded.version, payload.version)
        XCTAssertEqual(decoded.createdAt, payload.createdAt)
        XCTAssertEqual(decoded.pubkySession, payload.pubkySession)
        XCTAssertEqual(decoded.cache.hasSeenProfileIntro, payload.cache.hasSeenProfileIntro)
    }

    func testMetadataBackupV1DecodesWithoutPubkySessionField() throws {
        let payload = MetadataBackupV1(
            version: 1,
            createdAt: 123,
            tagMetadata: [],
            cache: makeAppCacheData(),
            pubkySession: nil
        )

        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let legacyJson = json.filter { $0.key != "pubkySession" }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJson)
        let decoded = try JSONDecoder().decode(MetadataBackupV1.self, from: legacyData)

        XCTAssertNil(decoded.pubkySession)
        XCTAssertEqual(decoded.cache.dismissedSuggestions, [])
    }

    // MARK: - Profile Link Input Model

    func testProfileLinkInputHasUniqueIds() {
        let link1 = ProfileLinkInput(label: "Website", url: "https://example.com")
        let link2 = ProfileLinkInput(label: "Website", url: "https://example.com")

        XCTAssertNotEqual(link1.id, link2.id)
    }

    private func makeProfile(publicKey: String, name: String) -> PubkyProfile {
        PubkyProfile(
            publicKey: publicKey,
            name: name,
            bio: "bio",
            imageUrl: nil,
            links: [],
            tags: [],
            status: nil
        )
    }

    private func makeKeychainStore(
        mnemonic: String? = nil,
        paykitSession: String? = nil,
        pubkySecretKey: String? = nil
    ) -> [String: String] {
        var store: [String: String] = [:]

        if let mnemonic {
            store[KeychainEntryType.bip39Mnemonic(index: 0).storageKey] = mnemonic
        }

        if let paykitSession {
            store[KeychainEntryType.paykitSession.storageKey] = paykitSession
        }

        if let pubkySecretKey {
            store[KeychainEntryType.pubkySecretKey.storageKey] = pubkySecretKey
        }

        return store
    }

    private func makeAppCacheData() -> AppCacheData {
        AppCacheData(
            hasSeenContactsIntro: false,
            hasSeenProfileIntro: true,
            hasSeenNotificationsIntro: false,
            hasSeenQuickpayIntro: false,
            hasSeenShopIntro: false,
            hasSeenTransferIntro: false,
            hasSeenTransferToSpendingIntro: false,
            hasSeenTransferToSavingsIntro: false,
            hasSeenWidgetsIntro: false,
            hasDismissedWidgetsOnboardingHint: false,
            appUpdateIgnoreTimestamp: 0,
            backupIgnoreTimestamp: 0,
            highBalanceIgnoreCount: 0,
            highBalanceIgnoreTimestamp: 0,
            dismissedSuggestions: [],
            lastUsedTags: []
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
