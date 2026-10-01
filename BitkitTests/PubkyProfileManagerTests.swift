@testable import Bitkit
import class Paykit.PubkySessionAccess
import struct Paykit.PubkySessionBootstrapResult
import XCTest

final class PubkyProfileManagerTests: XCTestCase {
    private enum RingAdoptionTeardown {
        case reset
        case signOut
    }

    @MainActor
    func testFailedRestorationPreservesCachedProfile() async {
        let keys = ["pubky_profile_name", "pubky_profile_image_uri"]
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set("Existing profile", forKey: keys[0])
        defaults.set("pubky://existing/avatar", forKey: keys[1])
        let manager = RecoveryProfileManager()

        await manager.initialize { .restorationFailed }

        XCTAssertTrue(manager.isInitialized)
        XCTAssertTrue(manager.sessionRestorationFailed)
        XCTAssertEqual(manager.authState, .idle)
        XCTAssertNil(manager.publicKey)
        XCTAssertEqual(manager.cachedName, "Existing profile")
        XCTAssertEqual(manager.cachedImageUri, "pubky://existing/avatar")
        XCTAssertEqual(defaults.string(forKey: keys[0]), manager.cachedName)
        XCTAssertEqual(defaults.string(forKey: keys[1]), manager.cachedImageUri)

        manager.sessionRestorationFailed = false
        XCTAssertEqual(Header.profileDestination(for: manager, hasSeenIntro: true), .profile)
        await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) { .restored(publicKey: "existing-identity") }
        XCTAssertEqual(manager.publicKey, "existing-identity")
        XCTAssertEqual(manager.cachedName, "Existing profile")
        XCTAssertEqual(manager.cachedImageUri, "pubky://existing/avatar")
    }

    @MainActor
    func testProfileEntryPreservesSavedIdentityWithoutCachedMetadata() throws {
        snapshotAppDefaults("pubky_profile_name")
        UserDefaults.standard.removeObject(forKey: "pubky_profile_name")
        let savedReference = AdoptedPubkyReference.current
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey]
        let savedValues = try keys.map { try Keychain.load(key: $0) }
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, savedValues) {
                if let value { try? Keychain.upsert(key: key, data: value) }
                else { try? Keychain.delete(key: key) }
            }
        }
        for key in keys {
            try Keychain.delete(key: key)
        }
        AdoptedPubkyReference.current = nil
        let manager = RecoveryProfileManager()
        manager.isInitialized = true
        XCTAssertEqual(Header.profileDestination(for: manager, hasSeenIntro: false), .profileIntro)
        XCTAssertEqual(Header.profileDestination(for: manager, hasSeenIntro: true), .pubkyChoice)

        try Keychain.upsert(key: .pubkySecretKey, data: Data("saved-local-key".utf8))
        XCTAssertEqual(Header.profileDestination(for: manager, hasSeenIntro: true), .profile)
        try Keychain.delete(key: .pubkySecretKey)
        AdoptedPubkyReference.current = (SharedPubkyKeychain.ringSourceApp, "saved-ring-key")
        XCTAssertEqual(Header.profileDestination(for: manager, hasSeenIntro: true), .profile)
    }

    @MainActor
    func testPeriodicRecoveryRestoresIdentityWithoutConnectivityEvent() async {
        let manager = RecoveryProfileManager()
        await manager.initialize { .restorationFailed }
        manager.sessionRestorationFailed = false
        let attempts = SessionRecoveryAttempts()
        let recovered = expectation(description: "saved identity recovered")
        let recovery = Task {
            await manager.retrySessionRestoration(retryDelay: .milliseconds(1), hasStoredIdentity: { true }) {
                guard await attempts.next() >= 3 else { return .restorationFailed }
                return .restored(publicKey: "existing-identity")
            }
            recovered.fulfill()
        }
        defer { recovery.cancel() }
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(manager.publicKey, "existing-identity")
        XCTAssertEqual(manager.authState, .authenticated)
        XCTAssertFalse(manager.sessionRestorationFailed)
        XCTAssertNil(manager.initializationErrorMessage)
    }

    @MainActor
    func testPeriodicRecoveryStopsWithoutStoredIdentity() async {
        for initiallyStored in [false, true] {
            let manager = RecoveryProfileManager()
            var hasIdentity = initiallyStored
            var delays: [Duration] = []
            await manager.retrySessionRestoration(
                sleep: { delay in
                    delays.append(delay)
                    hasIdentity = false
                    if delays.count > 1 {
                        XCTFail("Retry must stop after credentials are removed")
                        throw CancellationError()
                    }
                },
                hasStoredIdentity: { hasIdentity },
                initializeSession: { .restorationFailed }
            )
            XCTAssertEqual(delays.count, initiallyStored ? 1 : 0)
        }
    }

    @MainActor
    func testPeriodicRecoveryBacksOffWithJitterAndResetsOnRestart() async {
        let manager = RecoveryProfileManager()
        for multiplier in [0.8, 1.0, 1.2] {
            var delays: [Duration] = []
            await manager.retrySessionRestoration(
                jitter: { multiplier },
                sleep: { delay in
                    delays.append(delay)
                    if delays.count == 8 { throw CancellationError() }
                },
                hasStoredIdentity: { true },
                initializeSession: { .restorationFailed }
            )
            let expected: [Double] = switch multiplier {
            case 0.8: [8, 16, 32, 64, 128, 144, 144, 144]
            case 1.0: [10, 20, 40, 80, 160, 180, 180, 180]
            default: [12, 24, 48, 96, 180, 180, 180, 180]
            }
            XCTAssertEqual(delays, expected.map { .seconds($0) })
        }
    }

    @MainActor
    func testCancelledRecoveryDoesNotRetryAfterPendingStartup() async {
        let manager = RecoveryProfileManager()
        let started = expectation(description: "startup started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let startup = Task {
            await manager.initialize {
                started.fulfill()
                for await _ in stream {}
                return .restorationFailed
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let retryStarted = expectation(description: "recovery waiting for startup")
        let recovery = Task {
            retryStarted.fulfill()
            await manager.retrySessionRestoration(hasStoredIdentity: { true }) {
                XCTFail("Cancelled foreground recovery must not start a session")
                return .restored(publicKey: "existing-identity")
            }
        }
        await fulfillment(of: [retryStarted], timeout: 2)
        recovery.cancel()
        continuation.finish()
        await startup.value
        await recovery.value
        XCTAssertNil(manager.publicKey)
    }

    @MainActor
    func testFailedRingAdoptionKeepsPreviousIdentityAndSession() async throws {
        let savedReference = AdoptedPubkyReference.current
        let savedSession = try Keychain.load(key: .paykitSession)
        defer {
            AdoptedPubkyReference.current = savedReference
            if let savedSession {
                try? Keychain.upsert(key: .paykitSession, data: savedSession)
            } else {
                try? Keychain.delete(key: .paykitSession)
            }
        }
        let oldReference = (sourceApp: SharedPubkyKeychain.ringSourceApp, pubky: "previous-ring-identity")
        for previousReference in [nil, oldReference] {
            AdoptedPubkyReference.current = previousReference
            try Keychain.upsert(key: .paykitSession, data: Data("previous-session".utf8))
            let manager = RecoveryProfileManager()
            manager.publicKey = "previous-identity"
            manager.authState = .authenticated
            do {
                _ = try await manager.adoptRingIdentity(
                    pubky: "new-identity",
                    loadSecret: { _, _ in String(repeating: "02", count: 32) },
                    signIn: { _ in throw PubkyServiceError.authFailed("activation failed") }
                )
                XCTFail("Expected identity activation to fail")
            } catch {
                XCTAssertEqual(error.localizedDescription, PubkyServiceError.authFailed("activation failed").localizedDescription)
            }
            XCTAssertEqual(manager.publicKey, "previous-identity")
            XCTAssertEqual(manager.authState, .authenticated)
            XCTAssertEqual(AdoptedPubkyReference.current?.sourceApp, previousReference?.sourceApp)
            XCTAssertEqual(AdoptedPubkyReference.current?.pubky, previousReference?.pubky)
            XCTAssertEqual(try Keychain.loadString(key: .paykitSession), "previous-session")
        }
    }

    @MainActor
    func testFailedRingAdoptionDoesNotRestoreIdentityAfterLocalReset() async throws {
        let savedReference = AdoptedPubkyReference.current
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey, .paykitSdkState]
        let savedCredentials = try keys.map { try Keychain.load(key: $0) }
        let defaults = UserDefaults.standard
        let preferenceKeys = [
            "pubky_profile_name", "pubky_profile_image_uri", "pubky_profile_setup_pending",
            PublicPaykitService.publishingEnabledKey, PrivatePaykitService.publishingEnabledKey,
            ContactPaymentsService.confirmedPreferenceKey, "publicPaykitBolt11", "publicPaykitBolt11PaymentHash", "publicPaykitBolt11ExpiresAt",
            PrivatePaykitService.cacheStateKey, PrivatePaykitService.cleanupPendingKey,
            PrivatePaykitService.deletedContactCleanupKeysKey, "privatePaykitAddressReservations",
        ]
        let savedPreferences = preferenceKeys.map { defaults.object(forKey: $0) }
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(preferenceKeys, savedPreferences) {
                defaults.set(value, forKey: key)
            }
            ContactsManager.restoreContactProfileOverrides(savedOverrides)
            for (key, value) in zip(keys, savedCredentials) {
                if let value {
                    try? Keychain.upsert(key: key, data: value)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        for key in keys {
            try Keychain.delete(key: key)
        }
        AdoptedPubkyReference.current = (SharedPubkyKeychain.ringSourceApp, "previous-ring-identity")
        let started = expectation(description: "Ring sign-in started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let manager = RecoveryProfileManager()
        let adoption = Task {
            do {
                _ = try await manager.adoptRingIdentity(
                    pubky: "pending-ring-identity",
                    loadSecret: { _, _ in String(repeating: "02", count: 32) },
                    signIn: { _ in
                        started.fulfill()
                        for await _ in stream {}
                        throw PubkyServiceError.authFailed("sign-in failed")
                    }
                )
                XCTFail("Expected sign-in failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, PubkyServiceError.authFailed("sign-in failed").localizedDescription)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await PubkyProfileManager.clearLocalState()
        XCTAssertNil(AdoptedPubkyReference.current)
        continuation.finish()
        await adoption.value

        XCTAssertNil(AdoptedPubkyReference.current)
        XCTAssertFalse(try PubkyProfileManager.hasStoredIdentity())
        await manager.restoreSessionIfNeeded(initializeSession: {
            XCTFail("Reset must not leave a Ring identity available for automatic recovery")
            return .restorationFailed
        })
    }

    @MainActor
    func testFailedRingAdoptionRestoresPreviousIdentityAfterFailedSignOut() async throws {
        let savedReference = AdoptedPubkyReference.current
        let savedSession = try Keychain.load(key: .paykitSession)
        let defaults = UserDefaults.standard
        let sharingKeys = [PublicPaykitService.publishingEnabledKey, PrivatePaykitService.publishingEnabledKey]
        let savedSharingPreferences = sharingKeys.map { defaults.object(forKey: $0) }
        defer {
            AdoptedPubkyReference.current = savedReference
            if let savedSession {
                try? Keychain.upsert(key: .paykitSession, data: savedSession)
            } else {
                try? Keychain.delete(key: .paykitSession)
            }
            for (key, value) in zip(sharingKeys, savedSharingPreferences) {
                defaults.set(value, forKey: key)
            }
        }
        sharingKeys.forEach { defaults.set(false, forKey: $0) }
        let previousReference = (sourceApp: SharedPubkyKeychain.ringSourceApp, pubky: "previous-ring-identity")
        AdoptedPubkyReference.current = previousReference
        try Keychain.upsert(key: .paykitSession, data: Data("previous-session".utf8))
        let adoptionStarted = expectation(description: "Ring sign-in started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let manager = RecoveryProfileManager()
        manager.publicKey = "previous-ring-identity"
        manager.authState = .authenticated
        let adoption = Task {
            do {
                _ = try await manager.adoptRingIdentity(
                    pubky: "pending-ring-identity",
                    loadSecret: { _, _ in String(repeating: "02", count: 32) },
                    signIn: { _ in
                        adoptionStarted.fulfill()
                        for await _ in stream {}
                        throw PubkyServiceError.authFailed("sign-in failed")
                    }
                )
                XCTFail("Expected sign-in failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, PubkyServiceError.authFailed("sign-in failed").localizedDescription)
            }
        }
        await fulfillment(of: [adoptionStarted], timeout: 2)

        do {
            try await manager.signOut(performSessionCleanup: {
                throw PubkyServiceError.authFailed("sign-out failed")
            })
            XCTFail("Expected sign-out failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, PubkyServiceError.authFailed("sign-out failed").localizedDescription)
        }
        XCTAssertEqual(AdoptedPubkyReference.current?.pubky, "pending-ring-identity")

        continuation.finish()
        await adoption.value

        XCTAssertEqual(AdoptedPubkyReference.current?.sourceApp, previousReference.sourceApp)
        XCTAssertEqual(AdoptedPubkyReference.current?.pubky, previousReference.pubky)
        XCTAssertEqual(try Keychain.loadString(key: .paykitSession), "previous-session")
        XCTAssertEqual(manager.publicKey, "previous-ring-identity")
        XCTAssertEqual(manager.authState, .authenticated)
    }

    @MainActor
    func testConcurrentRingAdoptionIsRejected() async throws {
        let savedReference = AdoptedPubkyReference.current
        defer { AdoptedPubkyReference.current = savedReference }
        AdoptedPubkyReference.current = nil
        let adoptionStarted = expectation(description: "Ring sign-in started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let manager = RecoveryProfileManager()
        let adoption = Task {
            do {
                _ = try await manager.adoptRingIdentity(
                    pubky: "first-ring-identity",
                    loadSecret: { _, _ in String(repeating: "02", count: 32) },
                    signIn: { _ in
                        adoptionStarted.fulfill()
                        for await _ in stream {}
                        throw PubkyServiceError.authFailed("sign-in failed")
                    }
                )
                XCTFail("Expected sign-in failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, PubkyServiceError.authFailed("sign-in failed").localizedDescription)
            }
        }
        await fulfillment(of: [adoptionStarted], timeout: 2)

        do {
            _ = try await manager.adoptRingIdentity(
                pubky: "first-ring-identity",
                loadSecret: { _, _ in String(repeating: "03", count: 32) },
                signIn: { _ in XCTFail("Concurrent Ring adoption must not sign in") }
            )
            XCTFail("Expected concurrent Ring adoption to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                PubkyServiceError.authFailed("Pubky Ring sign-in already in progress").localizedDescription
            )
        }

        continuation.finish()
        await adoption.value
        XCTAssertNil(AdoptedPubkyReference.current)
    }

    @MainActor
    func testRingAdoptionDropsLateProfileAfterSessionTeardown() async throws {
        let savedReference = AdoptedPubkyReference.current
        let keychainKeys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey, .paykitSdkState]
        let savedCredentials = try keychainKeys.map { try Keychain.load(key: $0) }
        let defaults = UserDefaults.standard
        let preferenceKeys = [
            "pubky_profile_name", "pubky_profile_image_uri", "pubky_profile_setup_pending",
            PublicPaykitService.publishingEnabledKey, PrivatePaykitService.publishingEnabledKey,
            ContactPaymentsService.confirmedPreferenceKey, "publicPaykitBolt11", "publicPaykitBolt11PaymentHash", "publicPaykitBolt11ExpiresAt",
            PrivatePaykitService.cacheStateKey, PrivatePaykitService.cleanupPendingKey,
            PrivatePaykitService.deletedContactCleanupKeysKey, "privatePaykitAddressReservations",
        ]
        let savedPreferences = preferenceKeys.map { defaults.object(forKey: $0) }
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(preferenceKeys, savedPreferences) {
                defaults.set(value, forKey: key)
            }
            ContactsManager.restoreContactProfileOverrides(savedOverrides)
            for (key, value) in zip(keychainKeys, savedCredentials) {
                if let value {
                    try? Keychain.upsert(key: key, data: value)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }

        for teardown in [RingAdoptionTeardown.signOut, .reset] {
            preferenceKeys.forEach { defaults.removeObject(forKey: $0) }
            AdoptedPubkyReference.current = nil
            let manager = RecoveryProfileManager()
            let profileFetchStarted = expectation(description: "Ring profile fetch started")
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let adoption = Task {
                try await manager.adoptRingIdentity(
                    pubky: "pending-ring-identity",
                    loadSecret: { _, _ in String(repeating: "02", count: 32) },
                    signIn: { _ in },
                    fetchProfile: { publicKey in
                        profileFetchStarted.fulfill()
                        for await _ in stream {}
                        return PubkyProfile(
                            publicKey: publicKey,
                            name: "Late profile",
                            bio: "",
                            imageUrl: "pubky://late/avatar",
                            links: [],
                            status: nil
                        )
                    }
                )
            }
            await fulfillment(of: [profileFetchStarted], timeout: 2)

            switch teardown {
            case .signOut:
                try await manager.signOut(performSessionCleanup: {})
            case .reset:
                await PubkyProfileManager.clearLocalState()
            }

            continuation.finish()
            do {
                _ = try await adoption.value
                XCTFail("Expected abandoned Ring adoption to stop")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertNil(manager.profile)
            XCTAssertNil(defaults.string(forKey: "pubky_profile_name"))
            XCTAssertNil(defaults.string(forKey: "pubky_profile_image_uri"))
            XCTAssertFalse(defaults.bool(forKey: "pubky_profile_setup_pending"))
        }
    }

    @MainActor
    func testRingAdoptionWithoutProfileStartsProfileSetup() async throws {
        let savedReference = AdoptedPubkyReference.current
        let defaults = UserDefaults.standard
        let savedPending = defaults.object(forKey: "pubky_profile_setup_pending")
        defer {
            AdoptedPubkyReference.current = savedReference
            defaults.set(savedPending, forKey: "pubky_profile_setup_pending")
        }
        AdoptedPubkyReference.current = nil
        defaults.removeObject(forKey: "pubky_profile_setup_pending")
        let manager = RecoveryProfileManager()

        let adoptedProfile = try await manager.adoptRingIdentity(
            pubky: "new-ring-identity",
            loadSecret: { _, _ in String(repeating: "02", count: 32) },
            signIn: { _ in },
            fetchProfile: { _ in nil }
        )

        XCTAssertNil(adoptedProfile)
        XCTAssertNotNil(manager.publicKey)
        XCTAssertEqual(manager.authState, .authenticated)
        XCTAssertTrue(manager.isProfileSetupPending)
    }

    @MainActor
    func testRecoveryWaitsForStartupAndCoalescesConnectivityEvents() async {
        let manager = RecoveryProfileManager()
        let started = expectation(description: "startup started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let startup = Task {
            await manager.initialize {
                started.fulfill()
                for await _ in stream {}
                throw PubkyServiceError.authFailed("offline")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(manager.isRestoringSession)
        let restored = expectation(description: "one recovery")
        restored.assertForOverFulfill = true
        let retries = (0 ..< 2).map { _ in
            Task {
                await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
                    restored.fulfill()
                    return .restored(publicKey: "existing-identity")
                }
            }
        }
        continuation.finish()
        await startup.value
        for retry in retries {
            await retry.value
        }
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertFalse(manager.isRestoringSession)
        XCTAssertEqual(manager.publicKey, "existing-identity")
        XCTAssertEqual(manager.authState, .authenticated)
        XCTAssertNil(manager.initializationErrorMessage)
    }

    @MainActor
    func testAutomaticRecoveryKeepsUsableStateWhileRetryFails() async {
        let manager = RecoveryProfileManager()
        manager.isInitialized = true
        let started = expectation(description: "recovery started")
        let (retryStream, retryContinuation) = AsyncStream<Void>.makeStream()
        let recovery = Task {
            await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
                started.fulfill()
                for await _ in retryStream {}
                throw PubkyServiceError.authFailed("offline")
            }
        }

        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(manager.isRestoringSession)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertNil(manager.initializationErrorMessage)
        XCTAssertFalse(manager.sessionRestorationFailed)

        retryContinuation.finish()
        await recovery.value
        XCTAssertFalse(manager.isRestoringSession)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertNil(manager.initializationErrorMessage)
        XCTAssertFalse(manager.sessionRestorationFailed)
    }

    @MainActor
    func testAutomaticRecoveryDoesNotRepeatFailureNotificationAndClearsStaleErrorOnSuccess() async {
        let manager = RecoveryProfileManager()
        manager.isInitialized = true

        for _ in 0 ..< 2 {
            await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) { .restorationFailed }
            XCTAssertTrue(manager.isInitialized)
            XCTAssertNil(manager.initializationErrorMessage)
            XCTAssertFalse(manager.sessionRestorationFailed)
        }

        manager.isInitialized = false
        manager.initializationErrorMessage = "offline"
        await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) { .restored(publicKey: "existing-identity") }
        XCTAssertTrue(manager.isInitialized)
        XCTAssertNil(manager.initializationErrorMessage)
        XCTAssertEqual(manager.publicKey, "existing-identity")
    }

    @MainActor
    func testRecoverySkipsMissingAndUnreadableIdentities() async {
        let manager = RecoveryProfileManager()
        await manager.restoreSessionIfNeeded(hasStoredIdentity: { false }) {
            XCTFail("No saved identity to restore")
            return .noSession
        }
        await manager.restoreSessionIfNeeded(hasStoredIdentity: { throw PubkyServiceError.authFailed("keychain unavailable") }) {
            XCTFail("Unreadable credentials must not be interpreted as an absent identity")
            return .noSession
        }
        XCTAssertNil(manager.publicKey)
    }

    @MainActor
    func testBackupReplacementSuppressesRecoveryAndDiscardsLateResult() async throws {
        let manager = RecoveryProfileManager()
        let started = expectation(description: "recovery started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let recovery = Task {
            await manager.initialize {
                started.fulfill()
                for await _ in stream {}
                return .restored(publicKey: "old-identity")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        try await PubkyProfileManager.restoreSessionBackupState(
            nil,
            deleteKeychainValue: { _ in },
            removeOwnSharedRecords: {},
            forgetSessionAccess: {
                continuation.finish()
                await recovery.value
                await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
                    XCTFail("Recovery must not run while replacing credentials")
                    return .restored(publicKey: "old-identity")
                }
            }
        )
        XCTAssertNil(manager.publicKey)
        XCTAssertEqual(manager.authState, .idle)
    }

    @MainActor
    func testIdentityRestorationPreservesCredentialsForRetry() async throws {
        for failedStep in ["load", "signIn", "profile"] {
            for failure in [PubkyServiceError.authFailed("offline") as Error, CancellationError()] {
                var storedKey: String? = "existing-key"
                var shouldFail = true
                var profilePublicKey: String?

                func complete() async throws {
                    try await PubkyProfileManager.completeIdentityCreation(
                        loadStoredSecretKey: {
                            if shouldFail, failedStep == "load" {
                                throw failure
                            }
                            return storedKey
                        },
                        signIn: {
                            XCTAssertEqual($0, "existing-key")
                            if shouldFail, failedStep == "signIn" {
                                throw failure
                            }
                            return "pubky_existing"
                        },
                        signUp: {
                            XCTFail("An existing identity must not be registered on another homeserver")
                            return "pubky_new"
                        },
                        createProfile: {
                            if shouldFail, failedStep == "profile" {
                                throw failure
                            }
                            profilePublicKey = $0
                        },
                        discardSessionAccess: {
                            storedKey = nil
                            XCTFail("Recovery must preserve the existing identity")
                        }
                    )
                }

                do {
                    try await complete()
                    XCTFail("Expected recovery to fail")
                } catch {
                    XCTAssertEqual(error is CancellationError, failure is CancellationError)
                    XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
                }
                XCTAssertNil(profilePublicKey)
                XCTAssertEqual(storedKey, "existing-key")

                shouldFail = false
                try await complete()
                XCTAssertEqual(profilePublicKey, "pubky_existing")
                XCTAssertEqual(storedKey, "existing-key")
            }
        }
    }

    @MainActor
    func testIdentityCreationWithoutLocalKeyKeepsSignupAndCleanup() async throws {
        for storedKey in [nil, ""] as [String?] {
            for failsToSaveProfile in [false, true] {
                var didSignUp = false
                var didDiscard = false
                var profilePublicKey: String?

                do {
                    try await PubkyProfileManager.completeIdentityCreation(
                        loadStoredSecretKey: { storedKey },
                        signIn: { _ in
                            XCTFail("No local identity exists to restore")
                            return "pubky_existing"
                        },
                        signUp: {
                            didSignUp = true
                            return "pubky_new"
                        },
                        createProfile: {
                            if failsToSaveProfile {
                                throw PubkyServiceError.authFailed("profile")
                            }
                            profilePublicKey = $0
                        },
                        discardSessionAccess: { didDiscard = true }
                    )
                    XCTAssertFalse(failsToSaveProfile)
                } catch {
                    XCTAssertTrue(failsToSaveProfile)
                }

                XCTAssertTrue(didSignUp)
                XCTAssertEqual(didDiscard, failsToSaveProfile)
                XCTAssertEqual(profilePublicKey, failsToSaveProfile ? nil : "pubky_new")
            }
        }
    }

    @MainActor
    func testCreateIdentityRecoversStalePendingSetupWithoutPublicKey() async {
        let defaults = UserDefaults.standard
        let previousPending = defaults.object(forKey: "pubky_profile_setup_pending")
        defer { defaults.set(previousPending, forKey: "pubky_profile_setup_pending") }
        defaults.set(true, forKey: "pubky_profile_setup_pending")
        let manager = KeyDerivationProbeProfileManager()

        do {
            try await manager.createIdentity(name: "Test", bio: "", links: [], loadStoredSecretKey: { nil })
            XCTFail("Expected key derivation probe to stop creation")
        } catch {
            XCTAssertTrue(manager.didDeriveKeys)
            XCTAssertFalse(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testSignupFinishesProfileSetupOnlyAfterActivation() async throws {
        let defaults = UserDefaults.standard
        let previousPending = defaults.object(forKey: "pubky_profile_setup_pending")
        let previousSharing = defaults.object(forKey: PrivatePaykitService.publishingEnabledKey)
        defer {
            defaults.set(previousPending, forKey: "pubky_profile_setup_pending")
            defaults.set(previousSharing, forKey: PrivatePaykitService.publishingEnabledKey)
        }

        for failingStep in [nil, "register", "authorize", "activate"] {
            defaults.set(true, forKey: "pubky_profile_setup_pending")
            let manager = PubkyProfileManager()
            let session = PubkySessionBootstrapResult(sessionAccess: PubkySessionAccess(noPointer: .init()), publicKey: "pubky_test")
            var events: [String] = []
            func perform(_ step: String) throws {
                XCTAssertFalse(manager.isProfileSetupPending)
                XCTAssertNil(manager.publicKey)
                events.append(step)
                if step == failingStep {
                    throw PubkyServiceError.authFailed(step)
                }
            }

            do {
                try await manager.completeSignupAuthenticationForTesting(
                    publicKey: "pubky_test",
                    registerIdentity: {
                        try perform("register")
                        return session
                    },
                    approveAuth: { try perform("authorize") },
                    activateIdentity: {
                        XCTAssertTrue($0.sessionAccess === session.sessionAccess)
                        try perform("activate")
                    }
                )
                XCTAssertNil(failingStep)
                XCTAssertEqual(events, ["register", "authorize", "activate"])
                XCTAssertTrue(manager.isProfileSetupPending)
                XCTAssertEqual(manager.publicKey, "pubky_test")
                XCTAssertEqual(manager.authState, .authenticated)
            } catch {
                XCTAssertEqual(events.last, failingStep)
                XCTAssertFalse(manager.isProfileSetupPending)
                XCTAssertNil(manager.publicKey)
                XCTAssertEqual(manager.authState, .idle)
            }
        }
    }

    @MainActor
    func testSignupRejectsOverlapAndAllowsRetryAfterFailure() async throws {
        let defaults = UserDefaults.standard
        let previousPending = defaults.object(forKey: "pubky_profile_setup_pending")
        let previousSharing = defaults.object(forKey: PrivatePaykitService.publishingEnabledKey)
        defer {
            defaults.set(previousPending, forKey: "pubky_profile_setup_pending")
            defaults.set(previousSharing, forKey: PrivatePaykitService.publishingEnabledKey)
        }

        let manager = PubkyProfileManager()
        let session = PubkySessionBootstrapResult(sessionAccess: PubkySessionAccess(noPointer: .init()), publicKey: "pubky_test")
        var shouldFailActivation = true
        var activationCount = 0

        func rejectConcurrentSignup() async {
            do {
                try await manager.completeSignupAuthenticationForTesting(
                    publicKey: "pubky_other",
                    registerIdentity: {
                        XCTFail("Concurrent signup must not register an identity")
                        return session
                    },
                    approveAuth: { XCTFail("Concurrent signup must not authorize an app") },
                    activateIdentity: { _ in XCTFail("Concurrent signup must not activate or clear credentials") }
                )
                XCTFail("Expected concurrent signup to be rejected")
            } catch {
                guard case PubkySignupError.inProgress = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        }

        func completeSignup() async throws {
            try await manager.completeSignupAuthenticationForTesting(
                publicKey: "pubky_test",
                registerIdentity: {
                    await rejectConcurrentSignup()
                    return session
                },
                approveAuth: { await rejectConcurrentSignup() },
                activateIdentity: { _ in
                    await rejectConcurrentSignup()
                    activationCount += 1
                    if shouldFailActivation {
                        throw CancellationError()
                    }
                }
            )
        }

        do {
            try await completeSignup()
            XCTFail("Expected activation failure")
        } catch is CancellationError {}
        XCTAssertNil(manager.publicKey)
        XCTAssertFalse(manager.isProfileSetupPending)

        shouldFailActivation = false
        try await completeSignup()
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(manager.publicKey, "pubky_test")
        XCTAssertEqual(manager.authState, .authenticated)
        XCTAssertTrue(manager.isProfileSetupPending)
    }

    @MainActor
    func testSignupTimeoutAndCancellationIgnoreLateApprovalAndAllowRetry() async throws {
        let defaults = UserDefaults.standard
        let previousPending = defaults.object(forKey: "pubky_profile_setup_pending")
        let previousSharing = defaults.object(forKey: PrivatePaykitService.publishingEnabledKey)
        defer {
            defaults.set(previousPending, forKey: "pubky_profile_setup_pending")
            defaults.set(previousSharing, forKey: PrivatePaykitService.publishingEnabledKey)
        }

        for cancelSignup in [false, true] {
            let manager = PubkyProfileManager()
            let session = PubkySessionBootstrapResult(sessionAccess: PubkySessionAccess(noPointer: .init()), publicKey: "pubky_first")
            let approvalStarted = expectation(description: "Approval started")
            let signupFinished = expectation(description: "Signup stops without waiting for approval")
            let approvalFinished = expectation(description: "Late approval returns")
            var approvalContinuation: CheckedContinuation<Void, Never>?
            defer { approvalContinuation?.resume() }

            let signup = Task { @MainActor in
                defer { signupFinished.fulfill() }
                do {
                    try await manager.completeSignupAuthenticationForTesting(
                        publicKey: "pubky_first",
                        registerIdentity: { session },
                        approveAuth: {
                            await withCheckedContinuation {
                                approvalContinuation = $0
                                approvalStarted.fulfill()
                            }
                            approvalFinished.fulfill()
                        },
                        activateIdentity: { _ in XCTFail("Abandoned signup must never activate") },
                        authorizationTimeout: cancelSignup ? .seconds(30) : .milliseconds(20)
                    )
                    XCTFail("Expected signup to stop")
                } catch {
                    if cancelSignup {
                        XCTAssertTrue(error is CancellationError)
                    } else {
                        XCTAssertEqual((error as? URLError)?.code, .timedOut)
                    }
                }
            }

            await fulfillment(of: [approvalStarted], timeout: 2)
            if cancelSignup {
                signup.cancel()
            }
            await fulfillment(of: [signupFinished], timeout: 2)
            XCTAssertNil(manager.publicKey)
            XCTAssertFalse(manager.isProfileSetupPending)

            var didActivateRetry = false
            try await manager.completeSignupAuthenticationForTesting(
                publicKey: "pubky_retry",
                registerIdentity: { session },
                approveAuth: {},
                activateIdentity: { _ in didActivateRetry = true }
            )
            XCTAssertTrue(didActivateRetry)

            approvalContinuation?.resume()
            approvalContinuation = nil
            await fulfillment(of: [approvalFinished], timeout: 2)
            await signup.value
            XCTAssertEqual(manager.publicKey, "pubky_retry")
            XCTAssertEqual(manager.authState, .authenticated)
            XCTAssertTrue(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testIsAuthenticatedRequiresPublicKey() {
        let manager = PubkyProfileManager()

        manager.authState = .authenticated

        XCTAssertFalse(manager.isAuthenticated)
    }

    @MainActor
    func testFailedSignOutMarksEnabledPaykitStateForReconciliation() {
        var publicPending = false
        var privatePending = false

        PubkyProfileManager.markPaykitReconciliationPendingAfterFailedSignOut(
            publicSharingEnabled: true,
            privateSharingEnabled: true,
            setPublicReconciliationPending: { publicPending = $0 },
            setPrivateReconciliationPending: { privatePending = $0 }
        )

        XCTAssertTrue(publicPending)
        XCTAssertTrue(privatePending)
    }

    @MainActor
    func testProfileDeletionQueuesRemovalRatherThanRepublish() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            var publicPending = false

            PubkyProfileManager.clearPaykitSharingAfterProfileDeletion(
                defaults: defaults,
                setPublicReconciliationPending: { publicPending = $0 }
            )

            XCTAssertTrue(publicPending)
            XCTAssertEqual(PublicPaykitService.pendingReconciliationMode(defaults: defaults), .removePublishedState)
            XCTAssertEqual(PrivatePaykitService.fullCleanupReconciliationMode(defaults: defaults), .removePublishedState)
        }
    }

    @MainActor
    func testDiscardAbandonedSessionForgetsLocalAccessWhenRevocationFails() async {
        let manager = PubkyProfileManager()
        var didRevokeSession = false
        var didForgetSession = false

        await manager.discardAbandonedSessionForTesting(
            revokeSessionAccess: {
                didRevokeSession = true
                throw PubkyServiceError.authFailed("offline")
            },
            forgetSessionAccess: {
                didForgetSession = true
            }
        )

        XCTAssertTrue(didRevokeSession)
        XCTAssertTrue(didForgetSession)
    }

    // MARK: - Profile load freshness

    @MainActor
    func testLoadProfileDropsAResultThatPredatesAProfileWrite() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(holdsRequests: true)
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

            let adoption = Task { try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA) }
            await stub.waitForRequests(1)
            let load = Task { await manager.loadProfile() }
            await stub.waitForRequests(2)

            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Written"), for: ringKeyA)
            await stub.release(request: 0)
            _ = try await adoption.value
            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Stale"), for: ringKeyA)
            await stub.release(request: 1)
            await load.value

            XCTAssertEqual(manager.profile?.name, "Written")
            XCTAssertEqual(manager.cachedName, "Written")
            XCTAssertFalse(manager.isLoadingProfile)
        }
    }

    @MainActor
    func testLoadProfileDropsAResultThatPredatesSignOutEvenForTheSameKey() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(
                profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Stale")],
                holdsRequests: true
            )
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            manager.publicKey = ringKeyA

            let load = Task { await manager.loadProfile() }
            await stub.waitForRequests(1)
            manager.clearAuthenticatedStateForTesting()
            manager.publicKey = ringKeyA
            await stub.release(request: 0)
            await load.value

            XCTAssertNil(manager.profile)
            XCTAssertNil(manager.cachedName)
        }
    }

    // MARK: - Cached profile preview

    @MainActor
    func testCachedProfilePreviewShowsOnlyForThePubkyItWasCachedFor() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            manager.publicKey = ringKeyA
            await manager.loadProfile()
            manager.isInitialized = true

            XCTAssertEqual(manager.cachedProfilePreview?.name, "Alice")
            manager.publicKey = bareRingKeyA
            XCTAssertEqual(manager.cachedProfilePreview?.name, "Alice", "The owner matches either key form")
            manager.publicKey = ringKeyB
            XCTAssertNil(manager.cachedProfilePreview, "Another pubky never shows this pubky's name")
            XCTAssertEqual(manager.cachedName, "Alice")

            let relaunched = PubkyProfileManager()
            relaunched.publicKey = ringKeyA
            XCTAssertNil(relaunched.cachedProfilePreview, "Nothing shows before initialization completes")
            relaunched.isInitialized = true
            XCTAssertEqual(relaunched.cachedProfilePreview?.name, "Alice", "The owner persists across launches")

            manager.clearAuthenticatedStateForTesting()
            XCTAssertNil(UserDefaults.standard.string(forKey: "pubky_profile_owner"))
        }
    }

    @MainActor
    func testCachedNameWithoutAnOwnerShowsNoPreviewUntilALoadRecordsOne() async {
        await withRestoredProfileDefaults {
            // Builds before the owner was stored cached only the name and avatar.
            UserDefaults.standard.set("Legacy", forKey: "pubky_profile_name")
            UserDefaults.standard.removeObject(forKey: "pubky_profile_owner")
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            manager.publicKey = ringKeyA
            manager.isInitialized = true

            XCTAssertEqual(manager.cachedName, "Legacy")
            XCTAssertNil(manager.cachedProfilePreview)

            await manager.loadProfile()
            XCTAssertEqual(manager.cachedProfilePreview?.name, "Alice")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "pubky_profile_owner"), ringKeyA)
        }
    }

    // MARK: - Pubky Ring choice rows

    @MainActor
    func testRingIdentityProfilesKeepFoundProfilesAndRetryMissesOnlyAfterForeground() async {
        let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
        let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

        await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice")
        XCTAssertNil(manager.ringIdentityProfiles[ringKeyB])

        await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
        let requestsAfterRevisit = await stub.requests
        XCTAssertEqual(requestsAfterRevisit.sorted(), [ringKeyA, ringKeyB].sorted(), "Neither a found profile nor a miss is looked up again")

        manager.forgetRingIdentityMisses()
        await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
        let requestsAfterForeground = await stub.requests
        XCTAssertEqual(requestsAfterForeground.count, 3)
        XCTAssertEqual(requestsAfterForeground.last, ringKeyB)
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice")
    }

    @MainActor
    func testRingIdentityLookupsInFlightAreNotStartedTwice() async {
        let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")], holdsRequests: true)
        let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

        let first = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
        await stub.waitForRequests(1)
        await manager.loadRingIdentityProfiles([bareRingKeyA, ringKeyA])

        await stub.release(request: 0)
        await first.value
        let requests = await stub.requests
        XCTAssertEqual(requests, [ringKeyA])
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice")
    }

    @MainActor
    func testCancelledRingIdentityLookupRecordsNoMissAndIsNotReused() async {
        let stub = RemoteProfileStub(holdsRequests: true)
        let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

        let abandoned = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
        await stub.waitForRequests(1)
        abandoned.cancel()
        await stub.release(request: 0)
        await abandoned.value

        let replacedAbandoned = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
        await stub.waitForRequests(2)
        replacedAbandoned.cancel()
        let current = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
        await stub.waitForRequests(3)

        await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Alice"), for: ringKeyA)
        await stub.release(request: 1)
        await replacedAbandoned.value
        XCTAssertNil(manager.ringIdentityProfiles[ringKeyA], "A replaced lookup's result is dropped")
        await stub.release(request: 2)
        await current.value
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice")
    }

    @MainActor
    func testRingIdentityLookupsInFlightListEachRowUntilItsLookupFinishes() async throws {
        let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")], holdsRequests: true)
        await stub.makeUnreachable(ringKeyC)
        let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
        let rows = Task { await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB, bareRingKeyC]) }
        await stub.waitForRequests(3)
        var running: Set = [ringKeyA, ringKeyB, ringKeyC]
        XCTAssertEqual(manager.ringIdentityLookupsInFlight, running, "Rows are listed under the normalized pubky")

        // A found profile, a miss and an offline error each end only their own row's lookup.
        let requests = await stub.requests
        for key in [ringKeyA, ringKeyB, ringKeyC] {
            try await stub.release(request: XCTUnwrap(requests.firstIndex(of: key)))
            running.remove(key)
            await waitUntil("only the finished row leaves the in-flight set") { manager.ringIdentityLookupsInFlight == running }
        }
        await rows.value
        XCTAssertTrue(manager.ringIdentityLookupsInFlight.isEmpty)
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice")
    }

    @MainActor
    func testStoppedRingIdentityLookupLeavesTheInFlightSetAndAReplacedOneKeepsTheNewerListed() async {
        let stub = RemoteProfileStub(holdsRequests: true)
        let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

        let abandoned = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
        await stub.waitForRequests(1)
        abandoned.cancel()
        await waitUntil("the stopped row leaves before its lookup ends") { manager.ringIdentityLookupsInFlight.isEmpty }

        let current = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
        await stub.waitForRequests(2)
        XCTAssertEqual(manager.ringIdentityLookupsInFlight, [ringKeyA])
        await stub.release(request: 0)
        await abandoned.value
        XCTAssertEqual(manager.ringIdentityLookupsInFlight, [ringKeyA], "A replaced lookup ending leaves the newer one listed")

        await stub.release(request: 1)
        await current.value
        XCTAssertTrue(manager.ringIdentityLookupsInFlight.isEmpty)
    }

    @MainActor
    func testClearingAuthenticatedStateDropsRingIdentityProfilesAndLookups() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
            await stub.setHoldsRequests(true)
            let inFlight = Task { await manager.loadRingIdentityProfiles([bareRingKeyC]) }
            await stub.waitForRequests(3)

            XCTAssertEqual(manager.ringIdentityLookupsInFlight, [ringKeyC])
            manager.publicKey = ringKeyA
            manager.clearAuthenticatedStateForTesting()
            XCTAssertTrue(manager.ringIdentityLookupsInFlight.isEmpty, "The reset drops a row lookup before its task ends")
            await stub.setProfile(makeProfile(publicKey: ringKeyC, name: "Carol"), for: ringKeyC)
            await stub.release(request: 2)
            await inFlight.value
            XCTAssertTrue(manager.ringIdentityProfiles.isEmpty)
            XCTAssertTrue(manager.ringIdentityLookupsInFlight.isEmpty)

            await stub.setHoldsRequests(false)
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 5, "The miss is forgotten along with the found profile")
        }
    }

    @MainActor
    func testAutomaticRecoveryWhileSignedOutKeepsRingIdentityProfilesAndLookups() async {
        let savedReference = AdoptedPubkyReference.current
        defer { AdoptedPubkyReference.current = savedReference }
        AdoptedPubkyReference.current = nil
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
            await stub.setHoldsRequests(true)
            let inFlight = Task { await manager.loadRingIdentityProfiles([bareRingKeyC]) }
            await stub.waitForRequests(3)

            for result in [PubkyProfileManager.SessionInitializationResult.noSession, .restorationFailed] {
                await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) { result }
            }
            XCTAssertNil(manager.publicKey)

            await stub.setProfile(makeProfile(publicKey: ringKeyC, name: "Carol"), for: ringKeyC)
            await stub.release(request: 2)
            await inFlight.value
            let cancelledRequests = await stub.cancelledRequests
            XCTAssertTrue(cancelledRequests.isEmpty, "Recovery while signed out stops no row lookup")
            XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice")
            XCTAssertEqual(manager.ringIdentityProfiles[ringKeyC]?.name, "Carol")

            await stub.setHoldsRequests(false)
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB, bareRingKeyC])
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 3, "Neither the found profiles nor the miss are looked up again")
        }
    }

    @MainActor
    func testRingAdoptionReusesTheFoundRowProfileAndClearsTheRows() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
            // Held from here on, so adoption only returns if it reads nothing remote itself.
            await stub.setHoldsRequests(true)

            let adopted = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)

            XCTAssertEqual(adopted?.name, "Alice")
            XCTAssertEqual(manager.profile?.name, "Alice")
            XCTAssertEqual(manager.cachedName, "Alice")
            XCTAssertEqual(manager.publicKey, ringKeyA)
            XCTAssertEqual(manager.authState, .authenticated)
            XCTAssertFalse(manager.isProfileSetupPending)
            XCTAssertTrue(manager.ringIdentityProfiles.isEmpty)

            await stub.waitForRequests(3)
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 3, "Adoption reuses the row's profile; only the background refresh reads it again")
            XCTAssertEqual(requests.last, ringKeyA)
            await stub.release(request: 2)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }
        }
    }

    @MainActor
    func testRingAdoptionReusesTheRowProfileWhateverFormTheAdoptedKeyTakes() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA])
            await stub.setHoldsRequests(true)

            let adopted = try await manager.completeRingAdoptionForTesting(publicKey: bareRingKeyA)

            XCTAssertEqual(adopted?.name, "Alice", "Rows are cached under the normalized pubky")
            XCTAssertFalse(manager.isProfileSetupPending)
            await stub.waitForRequests(2)
            await stub.release(request: 1)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }
            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyA, bareRingKeyA], "Only the background refresh reads again")
        }
    }

    @MainActor
    func testRingAdoptionRefreshUpdatesAReusedRowProfile() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA])
            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Alice Renamed"), for: ringKeyA)

            _ = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)
            await stub.waitForRequests(2)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }

            XCTAssertEqual(manager.profile?.name, "Alice Renamed")
            XCTAssertEqual(manager.cachedName, "Alice Renamed")
            XCTAssertFalse(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testRingAdoptionStartsProfileSetupWhenTheReusedRowProfileWasRemoved() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA])
            await stub.setProfile(nil, for: ringKeyA)

            let adopted = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)
            XCTAssertEqual(adopted?.name, "Alice", "Adoption reuses the row profile found earlier")
            await stub.waitForRequests(2)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }

            XCTAssertNil(manager.profile, "A definitive not-found undoes the reused profile")
            XCTAssertNil(manager.cachedName)
            XCTAssertNil(UserDefaults.standard.string(forKey: "pubky_profile_name"))
            XCTAssertNil(UserDefaults.standard.string(forKey: "pubky_profile_owner"))
            XCTAssertTrue(manager.isProfileSetupPending)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "pubky_profile_setup_pending"))
            XCTAssertEqual(manager.publicKey, ringKeyA)
            XCTAssertEqual(manager.authState, .authenticated)
        }
    }

    @MainActor
    func testRingAdoptionKeepsTheReusedRowProfileWhenItsRefreshFails() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA])
            await stub.makeUnreachable(ringKeyA)

            _ = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)
            await stub.waitForRequests(2)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }

            XCTAssertEqual(manager.profile?.name, "Alice", "An offline refresh keeps the adopted row profile")
            XCTAssertEqual(manager.cachedName, "Alice")
            XCTAssertFalse(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testRingAdoptionRefreshDropsANotFoundOnceTheIdentityChanged() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA])
            await stub.setProfile(nil, for: ringKeyA)
            await stub.setHoldsRequests(true)

            _ = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)
            await stub.waitForRequests(2)
            manager.clearAuthenticatedStateForTesting()
            await stub.release(request: 1)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }

            XCTAssertFalse(manager.isProfileSetupPending, "A refresh for an identity no longer in use decides nothing")
        }
    }

    @MainActor
    func testAdoptingStopsOnlyTheOtherRowLookupsAndAFailedAdoptReloadsTheRows() async {
        let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")], holdsRequests: true)
        let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
        let rows = Task { await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB]) }
        await stub.waitForRequests(2)

        var rowReloads = 0
        do {
            // No Pubky Ring secret is stored under test, so signing in fails.
            _ = try await PubkyChoiceView.adoptRingIdentity(bareRingKeyA, pubkyProfile: manager) { rowReloads += 1 }
            XCTFail("Expected adopting without a Pubky Ring key to fail")
        } catch {}
        XCTAssertEqual(rowReloads, 1, "A failed adopt reloads the rows")
        XCTAssertEqual(manager.ringIdentityLookupsInFlight, [ringKeyA], "The other row leaves before its lookup ends; the tapped row stays")

        await stub.release(request: 0)
        await stub.release(request: 1)
        await rows.value
        let requests = await stub.requests
        let cancelledRequests = await stub.cancelledRequests
        XCTAssertEqual(cancelledRequests, Set(requests.indices.filter { requests[$0] == ringKeyB }), "Only the other row's lookup stops")
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice", "The tapped row's lookup still lands")
        XCTAssertTrue(manager.ringIdentityLookupsInFlight.isEmpty)

        await stub.setHoldsRequests(false)
        await stub.setProfile(makeProfile(publicKey: ringKeyB, name: "Bob"), for: ringKeyB)
        await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
        let reloadRequests = await stub.requests
        XCTAssertEqual(reloadRequests.count, 3)
        XCTAssertEqual(reloadRequests.last, ringKeyB, "The stopped row recorded no miss, so reloading looks it up again")
        XCTAssertEqual(manager.ringIdentityProfiles[ringKeyB]?.name, "Bob")
    }

    @MainActor
    func testRingAdoptionAfterARowMissStillFetchesTheProfile() async throws {
        try await withRestoredProfileDefaults {
            // A row miss can mean offline, so it never stands in for the fetch that decides profile setup.
            let stub = RemoteProfileStub()
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyB])
            await stub.setProfile(makeProfile(publicKey: ringKeyB, name: "Bob"), for: ringKeyB)

            let adopted = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyB)

            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyB, ringKeyB])
            XCTAssertEqual(adopted?.name, "Bob")
            XCTAssertEqual(manager.profile?.name, "Bob")
            XCTAssertFalse(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testRingAdoptionFetchesWhenTheRowProfileIsForAnotherKey() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyC: makeProfile(publicKey: ringKeyB, name: "Other")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyC])

            _ = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyC)

            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyC, ringKeyC])
        }
    }

    @MainActor
    func testRingAdoptionWithoutARowProfileKeepsFetchAndSetupLogic() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub()
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

            let adopted = try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)

            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyA])
            XCTAssertNil(adopted)
            XCTAssertNil(manager.profile)
            XCTAssertEqual(manager.publicKey, ringKeyA)
            XCTAssertTrue(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testRingAdoptionWaitsForTheTappedRowLookupInsteadOfFetchingAgain() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(holdsRequests: true)
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            let rows = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
            await stub.waitForRequests(1)

            let adoption = Task { try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA) }
            await waitUntil("adoption reaches the row lookup") { manager.publicKey == ringKeyA }
            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Alice"), for: ringKeyA)
            await stub.release(request: 0)
            await rows.value
            // A fetch of adoption's own would answer with this instead.
            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Alice Refetched"), for: ringKeyA)

            let adopted = try await adoption.value
            XCTAssertEqual(adopted?.name, "Alice", "Adoption reuses the tapped row's lookup that was still in flight")
            XCTAssertFalse(manager.isProfileSetupPending)

            await stub.waitForRequests(2)
            await stub.release(request: 1)
            await waitUntil("the background refresh finishes") { !manager.isLoadingProfile }
            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyA, ringKeyA], "Only the background refresh reads again")
        }
    }

    @MainActor
    func testRingAdoptionFetchesWhenTheTappedRowLookupInFlightMisses() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(holdsRequests: true)
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            let rows = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
            await stub.waitForRequests(1)

            let adoption = Task { try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA) }
            await waitUntil("adoption reaches the row lookup") { manager.publicKey == ringKeyA }
            await stub.release(request: 0)
            await rows.value
            // A row miss can mean offline, so the fresh fetch still decides profile setup.
            await stub.waitForRequests(2)
            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Alice"), for: ringKeyA)
            await stub.release(request: 1)

            let adopted = try await adoption.value
            XCTAssertEqual(adopted?.name, "Alice")
            XCTAssertFalse(manager.isProfileSetupPending)
            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyA, ringKeyA])
        }
    }

    @MainActor
    func testRingAdoptionDoesNotWaitForAStoppedRowLookup() async throws {
        try await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")], holdsRequests: true)
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            let rows = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
            await stub.waitForRequests(1)
            rows.cancel()

            let adoption = Task { try await manager.completeRingAdoptionForTesting(publicKey: ringKeyA) }
            await stub.waitForRequests(2)
            await stub.release(request: 1)
            let adopted = try await adoption.value
            XCTAssertEqual(adopted?.name, "Alice")

            await stub.release(request: 0)
            await rows.value
        }
    }

    @MainActor
    func testProfileDestinationKeepsTheChoiceScreenWhileARingAdoptionSignsIn() async throws {
        let savedReference = AdoptedPubkyReference.current
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey]
        let savedCredentials = try keys.map { try Keychain.load(key: $0) }
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, savedCredentials) {
                if let value { try? Keychain.upsert(key: key, data: value) }
                else { try? Keychain.delete(key: key) }
            }
        }
        try await withRestoredProfileDefaults {
            for key in keys {
                try Keychain.delete(key: key)
            }
            AdoptedPubkyReference.current = nil
            UserDefaults.standard.removeObject(forKey: "pubky_profile_name")
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")], holdsRequests: true)
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            let rows = Task { await manager.loadRingIdentityProfiles([bareRingKeyA]) }
            await stub.waitForRequests(1)
            XCTAssertEqual(ProfileDestinationView.destination(for: manager, hasSeenIntro: true), .pubkyChoice)

            let signInStarted = expectation(description: "Ring sign-in started")
            let (signInGate, openSignIn) = AsyncStream<Void>.makeStream()
            defer { openSignIn.finish() }
            let adoption = Task {
                try await manager.adoptRingIdentity(
                    pubky: bareRingKeyA,
                    loadSecret: { _, _ in String(repeating: "02", count: 32) },
                    signIn: { _ in
                        signInStarted.fulfill()
                        for await _ in signInGate {}
                        throw PubkyServiceError.authFailed("sign-in failed")
                    }
                )
            }
            await fulfillment(of: [signInStarted], timeout: 2)
            await stub.release(request: 0)
            await rows.value

            XCTAssertEqual(manager.ringIdentityProfiles[ringKeyA]?.name, "Alice", "The row lookup lands while sign-in is suspended")
            XCTAssertTrue(manager.hasExistingIdentity, "The adopted reference is written before sign-in finishes")
            XCTAssertTrue(manager.isAdoptingRingIdentity)
            XCTAssertEqual(ProfileDestinationView.destination(for: manager, hasSeenIntro: true), .pubkyChoice)

            openSignIn.finish()
            await XCTAssertThrowsErrorAsync { try await adoption.value }
            XCTAssertFalse(manager.isAdoptingRingIdentity)
            XCTAssertEqual(
                ProfileDestinationView.destination(for: manager, hasSeenIntro: true),
                .pubkyChoice,
                "A failed adopt returns to the choice screen"
            )
        }
    }

    // MARK: - HomegateResponse Decoding

    private typealias HomegateResponse = PubkyProfileManager.HomegateResponse

    func testHomegateResponseDecodesCamelCase() throws {
        let json = """
        {"signupCode":"abc-123","homeserverPubky":"z6MkPubkyTestKey"}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(HomegateResponse.self, from: data)

        XCTAssertEqual(response.signupCode, "abc-123")
        XCTAssertEqual(response.homeserverPubky, "z6MkPubkyTestKey")
    }

    func testHomegateResponseRejectsIncompleteJson() throws {
        let json = """
        {"signupCode":"abc-123"}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(HomegateResponse.self, from: data))
    }

    func testHomegateResponseRejectsEmptyJson() throws {
        let json = "{}"
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(HomegateResponse.self, from: data))
    }

    func testHomegateResponseWithExtraFieldsDecodes() throws {
        let json = """
        {"signupCode":"abc","homeserverPubky":"z6Mk","extra":"ignored"}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
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

    func testIsMissingBitkitProfileStorageErrorRecognizes404DeleteFailure() {
        let error = AppError(
            message: "App Error",
            debugMessage: #"BitkitCore.PubkyError.WriteFailed(reason: "delete failed: Request failed: Server responded with an error: 404 Not Found - Not Found")"#
        )

        XCTAssertTrue(PubkyProfileManager.isMissingBitkitProfileStorageError(error))
    }

    func testIsMissingBitkitProfileStorageErrorRejectsNonMissingErrors() {
        let error = AppError(
            message: "App Error",
            debugMessage: #"BitkitCore.PubkyError.AuthFailed(reason: "Request failed: HTTP transport error")"#
        )

        XCTAssertFalse(PubkyProfileManager.isMissingBitkitProfileStorageError(error))
    }

    func testIsSessionRefreshableErrorRecognizesSessionTransportFailure() {
        let error = AppError(
            message: "App Error",
            debugMessage: #"BitkitCore.PubkyError.AuthFailed(reason: "Request failed: HTTP transport error: error sending request for url (https://example.com/session)")"#
        )

        XCTAssertTrue(PubkyProfileManager.isSessionRefreshableError(error))
    }

    func testRefreshSessionIfPossibleRefreshesSessionFromLocalSecret() async {
        let error = AppError(
            message: "App Error",
            debugMessage: #"BitkitCore.PubkyError.AuthFailed(reason: "Request failed: HTTP transport error: error sending request for url (https://example.com/session)")"#
        )
        let refreshed = await PubkyProfileManager.refreshSessionIfPossible(
            after: error,
            loadKeychainString: { key in
                switch key {
                case .pubkySecretKey:
                    return "local-secret"
                default:
                    return nil
                }
            },
            signInWithSecretKey: { secretKey in
                XCTAssertEqual(secretKey, "local-secret")
                return "fresh-session"
            },
            publicKeyFromSecretKey: { secretKey in
                XCTAssertEqual(secretKey, "local-secret")
                return "pubky_fresh"
            }
        )

        XCTAssertTrue(refreshed)
    }

    func testRefreshSessionIfPossibleReturnsFalseWithoutLocalSecret() async {
        let error = AppError(
            message: "App Error",
            debugMessage: #"BitkitCore.PubkyError.AuthFailed(reason: "Request failed: HTTP transport error: error sending request for url (https://example.com/session)")"#
        )

        let refreshed = await PubkyProfileManager.refreshSessionIfPossible(
            after: error,
            loadKeychainString: { _ in nil },
            signInWithSecretKey: { _ in
                XCTFail("Expected refresh to stop when no local secret key exists")
                return "fresh-session"
            },
            publicKeyFromSecretKey: { _ in
                XCTFail("No public key should be derived without a local secret")
                return "pubky_unused"
            }
        )

        XCTAssertFalse(refreshed)
    }

    // MARK: - Session backup state

    func testSnapshotSessionBackupStatePrefersLocalSeedOverSessionSecret() throws {
        let store = makeKeychainStore(
            paykitSession: "session-secret",
            pubkySecretKey: "local-secret"
        )

        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { key in
            return store[key.storageKey]
        }

        XCTAssertEqual(snapshot, PubkySessionBackupV1(kind: .localSeed))
    }

    func testSnapshotSessionBackupStateReturnsNilWithoutALocalSeed() throws {
        let store = makeKeychainStore(paykitSession: "session-secret")

        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { key in
            return store[key.storageKey]
        }

        XCTAssertNil(snapshot)
    }

    func testSnapshotSessionBackupStateReturnsNilWhenNoPubkyCredentialsExist() throws {
        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { _ in nil }

        XCTAssertNil(snapshot)
    }

    func testSnapshotSessionBackupStateReturnsNilForAnAdoptedIdentity() throws {
        let store = makeKeychainStore(paykitSession: "session-secret")

        let snapshot = try PubkyProfileManager.snapshotSessionBackupState(
            loadKeychainString: { store[$0.storageKey] },
            adopted: ("app.pubkyring", "ring-pubky")
        )

        XCTAssertNil(snapshot)
    }

    func testHasStoredIdentityCountsAnAdoptedReference() throws {
        XCTAssertTrue(try PubkyProfileManager.hasStoredIdentity(adopted: ("app.pubkyring", "ring-pubky")))
    }

    // MARK: - Active secret key

    func testActiveSecretKeyHexPrefersTheLocalSecret() {
        let store = makeKeychainStore(pubkySecretKey: "local-secret")

        let secretKeyHex = PubkyProfileManager.activeSecretKeyHex(
            loadKeychainString: { store[$0.storageKey] },
            adopted: ("app.pubkyring", "ring-pubky"),
            loadSharedSecret: { _, _ in
                XCTFail("The local secret key must win over an adopted one")
                return "ring-secret"
            }
        )

        XCTAssertEqual(secretKeyHex, "local-secret")
    }

    func testActiveSecretKeyHexFallsBackToTheAdoptedSecret() {
        let secretKeyHex = PubkyProfileManager.activeSecretKeyHex(
            loadKeychainString: { _ in nil },
            adopted: ("app.pubkyring", "ring-pubky"),
            loadSharedSecret: { sourceApp, pubky in
                XCTAssertEqual(sourceApp, "app.pubkyring")
                XCTAssertEqual(pubky, "ring-pubky")
                return "ring-secret"
            }
        )

        XCTAssertEqual(secretKeyHex, "ring-secret")
    }

    func testActiveSecretKeyHexReturnsNilWithoutAnySecret() {
        let secretKeyHex = PubkyProfileManager.activeSecretKeyHex(
            loadKeychainString: { _ in nil },
            adopted: nil,
            loadSharedSecret: { _, _ in
                XCTFail("No adopted reference exists to load a secret for")
                return "ring-secret"
            }
        )

        XCTAssertNil(secretKeyHex)
    }

    func testResolveSessionInitializationRestoresSavedSessionWithoutReSigningIn() async {
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
            publicKeyFromSecretKey: { _ in
                XCTFail("Public key should not be derived after successful saved-session import")
                return "pubky_unused"
            }
        )

        XCTAssertEqual(result, .restored(publicKey: "pubky_saved"))
    }

    func testResolveSessionInitializationSignsInWhenOnlySecretKeyExists() async {
        let result = await PubkyProfileManager.resolveSessionInitialization(
            savedSessionSecret: nil,
            storedSecretKeyHex: "local-secret",
            importSession: { _ in
                XCTFail("Re-signed local sessions should not be re-imported")
                return "pubky_unused"
            },
            signInWithSecretKey: { secretKey in
                XCTAssertEqual(secretKey, "local-secret")
                return "new-session"
            },
            publicKeyFromSecretKey: { secretKey in
                XCTAssertEqual(secretKey, "local-secret")
                return "pubky_test"
            }
        )

        XCTAssertEqual(result, .restored(publicKey: "pubky_test"))
    }

    func testResolveSessionInitializationReportsFailedRestorationWhenReSignInFails() async {
        let result = await PubkyProfileManager.resolveSessionInitialization(
            savedSessionSecret: "stale-session",
            storedSecretKeyHex: "local-secret",
            importSession: { _ in
                throw PubkyServiceError.authFailed("stale session")
            },
            signInWithSecretKey: { _ in
                throw PubkyServiceError.authFailed("sign in failed")
            },
            publicKeyFromSecretKey: { _ in
                XCTFail("No public key should be derived when re-sign-in fails")
                return "pubky_unused"
            }
        )

        XCTAssertEqual(result, .restorationFailed)
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
            publicKeyFromSecretKey: { _ in
                XCTFail("No public key should be derived without credentials")
                return "pubky_unused"
            }
        )

        XCTAssertEqual(result, .noSession)
    }

    func testRestoreSessionBackupStateClearsCredentialsWhenBackupHasNoPubkyState() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "local-secret"
        )
        var didRemoveSharedRecords = false

        try await PubkyProfileManager.restoreSessionBackupState(
            nil,
            loadKeychainString: { key in
                return store[key.storageKey]
            },
            persistKeychainString: { key, value in
                store[key.storageKey] = value
            },
            deleteKeychainValue: { key in
                store.removeValue(forKey: key.storageKey)
            },
            removeOwnSharedRecords: { didRemoveSharedRecords = true },
            forgetSessionAccess: {},
            signInWithSecretKey: { _ in
                XCTFail("Missing pubky state should not sign in")
                return "unused-session"
            }
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
        XCTAssertTrue(didRemoveSharedRecords)
    }

    func testRestoreSessionBackupStateClearsCredentialsWhenForgetFailsWithoutBackup() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "stale-local-secret"
        )
        var didRemoveSharedRecords = false

        try await PubkyProfileManager.restoreSessionBackupState(
            nil,
            loadKeychainString: { store[$0.storageKey] },
            persistKeychainString: { store[$0.storageKey] = $1 },
            deleteKeychainValue: { store.removeValue(forKey: $0.storageKey) },
            removeOwnSharedRecords: { didRemoveSharedRecords = true },
            forgetSessionAccess: { throw PubkyServiceError.authFailed("offline") },
            signInWithSecretKey: { _ in
                XCTFail("Missing pubky state should not sign in")
                return "unused-session"
            }
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
        XCTAssertTrue(didRemoveSharedRecords)
    }

    func testRestoreSessionBackupStateForLegacyExternalSessionClearsCredentials() async throws {
        let json = #"{"kind":"externalSession","sessionSecret":"external-session"}"#
        let backup = try JSONDecoder().decode(PubkySessionBackupV1.self, from: XCTUnwrap(json.data(using: .utf8)))
        XCTAssertNil(backup.kind)

        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "local-secret"
        )
        var didRemoveSharedRecords = false

        try await PubkyProfileManager.restoreSessionBackupState(
            backup,
            loadKeychainString: { store[$0.storageKey] },
            persistKeychainString: { store[$0.storageKey] = $1 },
            deleteKeychainValue: { store.removeValue(forKey: $0.storageKey) },
            removeOwnSharedRecords: { didRemoveSharedRecords = true },
            forgetSessionAccess: {},
            signInWithSecretKey: { _ in
                XCTFail("A legacy external session should not sign in")
                return "unused-session"
            }
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
        XCTAssertTrue(didRemoveSharedRecords)
    }

    func testRestoreSessionBackupStateForLocalSeedDerivesSecretAndClearsSession() async throws {
        var store = makeKeychainStore(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            paykitSession: "stale-session"
        )

        try await PubkyProfileManager.restoreSessionBackupState(
            PubkySessionBackupV1(kind: .localSeed),
            loadKeychainString: { key in
                if case .bip39Passphrase = key {
                    XCTFail("Pubky key derivation should not read the wallet passphrase")
                }
                return store[key.storageKey]
            },
            persistKeychainString: { key, value in
                store[key.storageKey] = value
            },
            deleteKeychainValue: { key in
                store.removeValue(forKey: key.storageKey)
            },
            forgetSessionAccess: {},
            signInWithSecretKey: { secretKey in
                XCTAssertFalse(secretKey.isEmpty)
                store[KeychainEntryType.pubkySecretKey.storageKey] = secretKey
                store[KeychainEntryType.paykitSession.storageKey] = "fresh-session"
                return "fresh-session"
            }
        )

        XCTAssertEqual(store[KeychainEntryType.paykitSession.storageKey], "fresh-session")
        XCTAssertFalse(store[KeychainEntryType.pubkySecretKey.storageKey, default: ""].isEmpty)
    }

    func testRestoreSessionBackupStateForLocalSeedKeepsSecretWhenSignInFails() async throws {
        var store = makeKeychainStore(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            paykitSession: "stale-session"
        )

        do {
            try await PubkyProfileManager.restoreSessionBackupState(
                PubkySessionBackupV1(kind: .localSeed),
                loadKeychainString: { key in
                    if case .bip39Passphrase = key {
                        XCTFail("Pubky key derivation should not read the wallet passphrase")
                    }
                    return store[key.storageKey]
                },
                persistKeychainString: { key, value in
                    store[key.storageKey] = value
                },
                deleteKeychainValue: { key in
                    store.removeValue(forKey: key.storageKey)
                },
                forgetSessionAccess: {},
                signInWithSecretKey: { _ in
                    throw PubkyServiceError.authFailed("offline")
                }
            )
            XCTFail("Expected sign-in failure")
        } catch {
            XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
            XCTAssertFalse(store[KeychainEntryType.pubkySecretKey.storageKey, default: ""].isEmpty)
        }
    }

    // MARK: - Metadata backup payload

    func testMetadataBackupV1RoundTripsPubkySession() throws {
        let payload = MetadataBackupV1(
            version: 1,
            createdAt: 123,
            tagMetadata: [],
            cache: makeAppCacheData(),
            pubkySession: PubkySessionBackupV1(kind: .localSeed),
            pubkyContactProfileOverrides: nil
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
            pubkySession: nil,
            pubkyContactProfileOverrides: nil
        )

        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let jsonWithoutPubkySession = json.filter { $0.key != "pubkySession" }
        let dataWithoutPubkySession = try JSONSerialization.data(withJSONObject: jsonWithoutPubkySession)
        let decoded = try JSONDecoder().decode(MetadataBackupV1.self, from: dataWithoutPubkySession)

        XCTAssertNil(decoded.pubkySession)
        XCTAssertEqual(decoded.cache.dismissedSuggestions, [])
    }

    func testMetadataBackupV1RoundTripsHwWalletNames() throws {
        let payload = MetadataBackupV1(
            version: 1,
            createdAt: 123,
            tagMetadata: [],
            cache: makeAppCacheData(),
            pubkySession: nil,
            pubkyContactProfileOverrides: nil,
            hwWalletNames: ["trezor:standard": "Cold Storage"]
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MetadataBackupV1.self, from: encoded)

        XCTAssertEqual(decoded.hwWalletNames, ["trezor:standard": "Cold Storage"])
    }

    /// The envelope is shared with bitkit-android, which wrote it without this field before it
    /// existed — and still omits it when no wallet is named.
    func testMetadataBackupV1DecodesWithoutHwWalletNamesField() throws {
        let payload = MetadataBackupV1(
            version: 1,
            createdAt: 123,
            tagMetadata: [],
            cache: makeAppCacheData(),
            pubkySession: nil,
            pubkyContactProfileOverrides: nil
        )

        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["hwWalletNames"], "a nil map must not be written as an explicit null")

        let decoded = try JSONDecoder().decode(MetadataBackupV1.self, from: encoded)
        XCTAssertNil(decoded.hwWalletNames)
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

    /// Profile commits and clears write these keys to the standard defaults.
    @MainActor
    private func withRestoredProfileDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let keys = ["pubky_profile_name", "pubky_profile_image_uri", "pubky_profile_owner", "pubky_profile_setup_pending"]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previousValues) {
                defaults.set(value, forKey: key)
            }
        }

        try await body()
    }

    /// Fails the test instead of hanging it when `condition` does not hold before the deadline.
    @MainActor
    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting until \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "PubkyProfileManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try body(defaults)
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

private let bareRingKeyA = String(repeating: "y", count: 52)
private let bareRingKeyB = String(repeating: "b", count: 52)
private let bareRingKeyC = String(repeating: "n", count: 52)
private let ringKeyA = "pubky\(bareRingKeyA)"
private let ringKeyB = "pubky\(bareRingKeyB)"
private let ringKeyC = "pubky\(bareRingKeyC)"

/// Stands in for the remote profile lookup. While holding, each request waits for its own `release(request:)` and then
/// answers from the profiles set at that moment; a key with no profile fails as not found and an unreachable key fails as
/// offline. A request held, or a wait for requests, that outlasts the deadline fails the test and moves on instead of
/// hanging the suite.
private actor RemoteProfileStub {
    private static let deadline: Duration = .seconds(5)

    private(set) var requests: [String] = []
    /// Indexes of the requests whose task was cancelled by the time they answered.
    private(set) var cancelledRequests: Set<Int> = []
    private var profiles: [String: PubkyProfile]
    private var unreachableKeys: Set<String> = []
    private var isHolding: Bool
    private var heldRequests: [Int: CheckedContinuation<Void, Never>] = [:]
    private var requestWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    init(profiles: [String: PubkyProfile] = [:], holdsRequests: Bool = false) {
        self.profiles = profiles
        isHolding = holdsRequests
    }

    func resolve(_ key: String) async throws -> PubkyProfile {
        let index = requests.count
        requests.append(key)
        for (id, waiter) in requestWaiters where waiter.count <= requests.count {
            requestWaiters[id] = nil
            waiter.continuation.resume()
        }

        if isHolding {
            await withCheckedContinuation { continuation in
                heldRequests[index] = continuation
                failAfterDeadline { await $0.expireHeldRequest(index) }
            }
        }
        if Task.isCancelled {
            cancelledRequests.insert(index)
        }
        guard !unreachableKeys.contains(key) else { throw URLError(.notConnectedToInternet) }
        guard let profile = profiles[key] else { throw PubkyServiceError.profileNotFound }
        return profile
    }

    func makeUnreachable(_ key: String) {
        unreachableKeys.insert(key)
    }

    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        guard requests.count < count else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            requestWaiters[id] = (count, continuation)
            failAfterDeadline { await $0.expireRequestWaiter(id, file: file, line: line) }
        }
    }

    func setProfile(_ profile: PubkyProfile?, for key: String) {
        profiles[key] = profile
    }

    func setHoldsRequests(_ holds: Bool) {
        isHolding = holds
    }

    func release(request index: Int) {
        heldRequests.removeValue(forKey: index)?.resume()
    }

    private func failAfterDeadline(_ expire: @escaping @Sendable (RemoteProfileStub) async -> Void) {
        Task {
            try? await Task.sleep(for: Self.deadline)
            await expire(self)
        }
    }

    private func expireHeldRequest(_ index: Int) {
        guard let continuation = heldRequests.removeValue(forKey: index) else { return }
        XCTFail("Request \(index) was never released")
        continuation.resume()
    }

    private func expireRequestWaiter(_ id: UUID, file: StaticString, line: UInt) {
        guard let waiter = requestWaiters.removeValue(forKey: id) else { return }
        XCTFail("Timed out waiting for \(waiter.count) requests; saw \(requests.count)", file: file, line: line)
        waiter.continuation.resume()
    }
}

@MainActor
private class KeyDerivationProbeProfileManager: PubkyProfileManager {
    var didDeriveKeys = false

    override func deriveKeys() async throws -> (String, String) {
        didDeriveKeys = true
        throw PubkyServiceError.authFailed("key derivation probe")
    }
}

@MainActor
private final class RecoveryProfileManager: PubkyProfileManager {
    override func loadProfile() async {}
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

private actor SessionRecoveryAttempts {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
