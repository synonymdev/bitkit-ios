@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    private let externalAuthURL =
        "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
        "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
        "&cid=paykit.test&cpk=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"

    func testIdentityReadFailurePreservesSavedStateAndSession() async throws {
        let savedState = try Keychain.load(key: .paykitSdkState)
        let savedSession = try Keychain.load(key: .paykitSession)
        defer {
            for (key, data) in [(KeychainEntryType.paykitSdkState, savedState), (.paykitSession, savedSession)] {
                if let data { try? Keychain.upsert(key: key, data: data) }
                else { try? Keychain.delete(key: key) }
            }
        }
        let state = Data("saved contacts and identity".utf8)
        let session = Data("saved grant".utf8)
        for failure in [
            PaykitError.Identity(code: "identity_error", context: "restore Pubky grant session from platform provider"),
            PaykitError.Storage(code: "storage_error", context: "unavailable"),
        ] {
            try Keychain.upsert(key: .paykitSdkState, data: state)
            try Keychain.upsert(key: .paykitSession, data: session)
            let sdk = IdentityReadFailureSdk(noPointer: .init())
            sdk.failure = failure
            let service = PaykitSdkService(sdkFactory: { sdk })

            do {
                _ = try await service.signIn(secretKeyHex: "unused")
                XCTFail("An unreadable stored identity must stop activation")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: failure))
            }
            XCTAssertEqual(try Keychain.load(key: .paykitSdkState), state)
            XCTAssertEqual(try Keychain.load(key: .paykitSession), session)
        }
    }

    @MainActor
    func testCanceledAuthActivationBlocksRecoveryUntilDiscardFinishes() async throws {
        let keys: [KeychainEntryType] = [
            .paykitSdkState, .paykitSession, .pubkySecretKey, .paykitReceiverNoiseSecretKey,
            .bip39Mnemonic(index: 0), .bip39Passphrase(index: 0),
        ]
        let saved = try keys.map { try Keychain.load(key: $0) }
        defer {
            for (key, data) in zip(keys, saved) {
                if let data {
                    try? Keychain.upsert(key: key, data: data)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }

        let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        try Keychain.upsert(key: .bip39Mnemonic(index: 0), data: Data(mnemonic.utf8))
        try Keychain.delete(key: .bip39Passphrase(index: 0))
        let noiseBytes = try PaykitReceiverNoiseKeyDerivation.deriveFromWalletSeed(
            mnemonic: mnemonic, passphrase: nil, network: Env.networkName, receiverPath: PaykitReceiverPath.wallet
        )
        try Keychain.upsert(key: .paykitReceiverNoiseSecretKey, data: noiseBytes)
        try? Keychain.delete(key: .paykitSdkState)
        try? Keychain.delete(key: .paykitSession)
        try? Keychain.delete(key: .pubkySecretKey)

        let session = CacheActivationSession(noPointer: .init())
        session.noiseBytes = noiseBytes
        let authRequest = CanceledActivationAuthRequest(noPointer: .init())
        authRequest.result = PubkySessionBootstrapResult(sessionAccess: session, publicKey: "pubky_test")
        let bootstrap = CanceledActivationBootstrap(noPointer: .init())
        bootstrap.request = authRequest
        let sdk = CanceledActivationSdk(noPointer: .init())
        let activationStarted = expectation(description: "activation started after credentials persisted")
        let (activationStream, activationContinuation) = AsyncStream<Void>.makeStream()
        sdk.initializeOperation = {
            activationStarted.fulfill()
            for await _ in activationStream {}
        }
        let discardStarted = expectation(description: "abandoned session discard started")
        let (discardStream, discardContinuation) = AsyncStream<Void>.makeStream()
        sdk.signOutOperation = {
            discardStarted.fulfill()
            for await _ in discardStream {}
        }
        let service = PaykitSdkService(sdkFactory: { sdk }, bootstrapFactory: { _, _ in bootstrap })
        _ = try await service.startAuth()

        let manager = UnavailableProfileManager()
        manager.isInitialized = true
        manager.setActiveAuthAttemptIDForTesting(UUID())
        manager.authState = .authenticating
        let authentication = Task {
            try await manager.completeAuthenticationForTesting(
                completeAuthWithActivationBoundary: { willActivate in
                    try await service.completeAuth(willActivate: willActivate)
                },
                currentPublicKey: { try? await service.currentPublicKey() },
                discardSessionAccess: { sessionSecret in
                    await service.discardCompletedAuthSession(sessionSecret: sessionSecret)
                }
            )
        }

        await fulfillment(of: [activationStarted], timeout: 2)
        XCTAssertEqual(try Keychain.loadString(key: .paykitSession), "new-session")
        manager.setActiveAuthAttemptIDForTesting(nil)
        manager.authState = .idle
        await service.cancelAuth()

        let recoveryCount = TestAsyncCallCounter()
        await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
            await recoveryCount.increment()
            return .restored(publicKey: "existing-identity")
        }
        let countDuringActivation = await recoveryCount.value
        XCTAssertEqual(countDuringActivation, 0)

        activationContinuation.finish()
        await fulfillment(of: [discardStarted], timeout: 2)
        await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
            await recoveryCount.increment()
            return .restored(publicKey: "existing-identity")
        }
        let countDuringDiscard = await recoveryCount.value
        XCTAssertEqual(countDuringDiscard, 0)

        discardContinuation.finish()
        do {
            _ = try await authentication.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await manager.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
            await recoveryCount.increment()
            return .restored(publicKey: "existing-identity")
        }
        let countAfterDiscard = await recoveryCount.value
        XCTAssertEqual(countAfterDiscard, 1)
        XCTAssertEqual(manager.publicKey, "existing-identity")
        XCTAssertNil(try Keychain.load(key: .paykitSession))
    }

    @MainActor
    func testIdentityActivationSeparatesCacheAndPreservesSameOwnerOrLegacyBackup() async throws {
        let defaults = UserDefaults.standard
        let metadataKeys = ["pubky_profile_name", "pubky_profile_image_uri"]
        let savedMetadata = metadataKeys.map { defaults.object(forKey: $0) }
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        let credentialKeys: [KeychainEntryType] = [
            .paykitSdkState, .paykitSession, .pubkySecretKey, .paykitReceiverNoiseSecretKey,
            .bip39Mnemonic(index: 0), .bip39Passphrase(index: 0),
        ]
        let savedCredentials = try credentialKeys.map { try Keychain.load(key: $0) }
        defer {
            for (key, value) in zip(metadataKeys, savedMetadata) {
                defaults.set(value, forKey: key)
            }
            ContactsManager.restoreContactProfileOverrides(savedOverrides)
            for (key, data) in zip(credentialKeys, savedCredentials) {
                if let data { try? Keychain.upsert(key: key, data: data) }
                else { try? Keychain.delete(key: key) }
            }
        }
        let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        try Keychain.upsert(key: .bip39Mnemonic(index: 0), data: Data(mnemonic.utf8))
        try Keychain.delete(key: .bip39Passphrase(index: 0))
        let noiseBytes = try PaykitReceiverNoiseKeyDerivation.deriveFromWalletSeed(
            mnemonic: mnemonic, passphrase: nil, network: Env.networkName, receiverPath: PaykitReceiverPath.wallet
        )
        try Keychain.upsert(key: .paykitReceiverNoiseSecretKey, data: noiseBytes)
        let originalKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let differentKey = "5" + String(originalKey.dropFirst())
        let overrides = [originalKey: PubkyProfileData(name: "Private label", bio: "", image: nil, links: [], tags: [])]
        for previousKey in [originalKey, "pubky\(originalKey)", differentKey, nil] {
            for restoreOnStartup in [false, true] {
                defaults.set("Original profile", forKey: metadataKeys[0])
                defaults.set("pubky://original/avatar", forKey: metadataKeys[1])
                ContactsManager.restoreContactProfileOverrides(overrides)
                let manager = UnavailableProfileManager()
                await manager.initialize { .restorationFailed }
                let sdk = CacheActivationSdk(noPointer: .init())
                sdk.previousKey = previousKey
                let service = PaykitSdkService(sdkFactory: { sdk }) { _, _ in CacheActivationBootstrap(noPointer: .init()) }
                let session = CacheActivationSession(noPointer: .init())
                session.noiseBytes = noiseBytes
                let result = PubkySessionBootstrapResult(sessionAccess: session, publicKey: "pubky\(originalKey)")

                if restoreOnStartup {
                    try await service.activateRegisteredIdentity(result)
                    await manager.initialize { .restored(publicKey: "pubky\(originalKey)") }
                } else {
                    manager.setActiveAuthAttemptIDForTesting(UUID())
                    try await manager.completeAuthenticationForTesting(
                        completeAuth: {
                            try await service.activateRegisteredIdentity(result)
                            return "new-session"
                        },
                        currentPublicKey: { "pubky\(originalKey)" },
                        discardSessionAccess: { _ in XCTFail("Activation must succeed") }
                    )
                }

                XCTAssertEqual(manager.publicKey, "pubky\(originalKey)")
                if previousKey == differentKey {
                    XCTAssertNil(manager.displayName)
                    XCTAssertNil(manager.displayImageUri)
                    XCTAssertNil(defaults.string(forKey: metadataKeys[0]))
                    XCTAssertNil(defaults.string(forKey: metadataKeys[1]))
                    XCTAssertNil(ContactsManager.backupContactProfileOverrides())
                } else {
                    XCTAssertEqual(manager.displayName, "Original profile")
                    XCTAssertEqual(manager.displayImageUri, "pubky://original/avatar")
                    XCTAssertEqual(ContactsManager.backupContactProfileOverrides(), overrides)
                }
            }
        }
    }

    func testSessionRecoveryCannotReactivateCredentialsAfterForget() async throws {
        let keys: [KeychainEntryType] = [
            .paykitSdkState, .paykitSession, .pubkySecretKey, .paykitReceiverNoiseSecretKey,
            .bip39Mnemonic(index: 0), .bip39Passphrase(index: 0),
        ]
        let saved = try keys.map { try Keychain.load(key: $0) }
        defer {
            for (key, data) in zip(keys, saved) {
                if let data {
                    try? Keychain.upsert(key: key, data: data)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        let secret = String(repeating: "01", count: 32)
        let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        try Keychain.upsert(key: .bip39Mnemonic(index: 0), data: Data(mnemonic.utf8))
        try Keychain.delete(key: .bip39Passphrase(index: 0))
        let noise = try PaykitReceiverNoiseKeyDerivation.deriveFromWalletSeed(
            mnemonic: mnemonic, passphrase: nil, network: Env.networkName, receiverPath: PaykitReceiverPath.wallet
        )
        try Keychain.upsert(key: .paykitSession, data: Data("saved-session".utf8))
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secret.utf8))
        try Keychain.upsert(key: .paykitReceiverNoiseSecretKey, data: noise)
        let started = expectation(description: "import started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let bootstrap = RecoveryBootstrap(noPointer: .init())
        bootstrap.importSessionOperation = {
            started.fulfill()
            for await _ in stream {}
            throw PubkyServiceError.authFailed("expired session")
        }
        let session = CacheActivationSession(noPointer: .init())
        session.noiseBytes = noise
        bootstrap.result = try PubkySessionBootstrapResult(
            sessionAccess: session, publicKey: PubkyProfileManager.publicKeyFromSecretKey(secret)
        )
        let sdk = RecoverySdk(noPointer: .init())
        let forgotEarly = expectation(description: "forget cannot interleave with recovery")
        forgotEarly.isInverted = true
        sdk.onForget = { forgotEarly.fulfill() }
        let service = PaykitSdkService(sdkFactory: { sdk }, bootstrapFactory: { _, _ in bootstrap })
        let recovery = Task { try await service.restorePersistedSession() }
        await fulfillment(of: [started], timeout: 2)
        let forget = Task { try await service.forgetSessionAccess() }
        await fulfillment(of: [forgotEarly], timeout: 0.1)
        sdk.onForget = {}
        continuation.finish()
        let result = try await recovery.value
        try await forget.value
        XCTAssertEqual(result, .restored(publicKey: bootstrap.result.publicKey))
        XCTAssertNil(try Keychain.load(key: .paykitSession))
        XCTAssertNil(try Keychain.load(key: .pubkySecretKey))
        let afterForget = try await service.restorePersistedSession()
        XCTAssertEqual(afterForget, .noSession)
    }

    func testClientIDUsesBitkitOwnedDomain() {
        let expectedClientID = Env.network == .bitcoin ? "bitkit.to" : "staging.bitkit.to"

        XCTAssertEqual(PaykitSdkService.clientID, expectedClientID)
    }

    func testProductionUsesDefaultPubkyClient() {
        let config = PaykitSdkService.makePubkyClientConfig(localTestnetHost: nil)

        XCTAssertNil(config.localTestnetHost)
    }

    func testLocalE2EUsesLocalPubkyTestnet() {
        let config = PaykitSdkService.makePubkyClientConfig(localTestnetHost: "192.0.2.1")

        XCTAssertEqual(config.localTestnetHost, "192.0.2.1")
    }

    func testApprovalBootstrapUsesExternalRequesterClientID() async throws {
        var configuredClientID: String?
        let service = PaykitSdkService { clientID, _ in
            configuredClientID = clientID
            return PubkySessionBootstrap(noPointer: .init())
        }

        _ = try await service.approvalBootstrap(
            authUrl: externalAuthURL,
            approvedClientID: "paykit.test"
        )

        XCTAssertEqual(configuredClientID, "paykit.test")
    }

    func testApprovalBootstrapRejectsMismatchedClientID() async {
        var didCreateBootstrap = false
        let service = PaykitSdkService { _, _ in
            didCreateBootstrap = true
            return PubkySessionBootstrap(noPointer: .init())
        }

        do {
            _ = try await service.approvalBootstrap(
                authUrl: externalAuthURL,
                approvedClientID: "different.test"
            )
            XCTFail("Expected a mismatched client ID to be rejected")
        } catch {}

        XCTAssertFalse(didCreateBootstrap)
    }

    func testStoredSessionCanBeDeferredDuringSdkInitialization() {
        let error = PaykitError.Identity(code: "identity_error", context: "restore Pubky grant session from platform provider")

        XCTAssertTrue(PaykitSdkService.shouldDeferStaleSession(error: error, hasStoredSession: true))
    }

    func testMissingSessionOrUnrelatedIdentityFailureIsNotDeferred() {
        let staleSession = PaykitError.Identity(code: "identity_error", context: "restore Pubky grant session from platform provider")
        let unrelatedError = PaykitError.Identity(code: "identity_error", context: "local Pubky secret key does not match session public key")

        XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: staleSession, hasStoredSession: false))
        XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: unrelatedError, hasStoredSession: true))
    }

    func testSessionAccessTeardownAttemptsBothCredentialsWithSessionFirst() {
        var attemptedKeys: [String] = []

        XCTAssertThrowsError(
            try PubkySessionAccessTeardown.clear { key in
                attemptedKeys.append(key.storageKey)
                if key.storageKey == KeychainEntryType.paykitSession.storageKey {
                    throw KeychainError.failedToDelete
                }
            }
        )

        XCTAssertEqual(
            attemptedKeys,
            [KeychainEntryType.paykitSession.storageKey, KeychainEntryType.pubkySecretKey.storageKey]
        )
    }

    func testFailedAuthActivationDiscardsOnlyItsPersistedSession() async {
        for shouldPersist in [false, true] {
            for activationError in [PubkyServiceError.sessionNotActive as Error, CancellationError()] {
                var storedSession = "previous-session"
                var revoked = false
                do {
                    _ = try await PaykitSdkService.completeAuthActivation(
                        sessionSecret: "new-session",
                        activate: {
                            if shouldPersist { storedSession = "new-session" }
                            throw activationError
                        },
                        discardSessionAccess: { session in
                            _ = await PaykitSdkService.discardAuthSession(
                                sessionSecret: session,
                                storedSessionSecret: { storedSession },
                                revoke: { revoked = true },
                                forget: { XCTFail("Revocation succeeded") }
                            )
                        }
                    )
                    XCTFail("Expected activation to fail")
                } catch {
                    XCTAssertEqual(error is CancellationError, activationError is CancellationError)
                    XCTAssertEqual(revoked, shouldPersist)
                }
            }
        }
    }

    func testLateAuthCleanupPreservesNewerSession() async {
        let matched = await PaykitSdkService.discardAuthSession(
            sessionSecret: "canceled-session",
            storedSessionSecret: { "newer-session" },
            revoke: { XCTFail("Must not revoke the newer session") },
            forget: { XCTFail("Must not forget the newer session") }
        )

        XCTAssertFalse(matched)
    }

    func testAuthCleanupForgetsMatchingSessionWhenRevocationFails() async {
        var didForget = false
        let matched = await PaykitSdkService.discardAuthSession(
            sessionSecret: "canceled-session",
            storedSessionSecret: { "canceled-session" },
            revoke: { throw PubkyServiceError.sessionNotActive },
            forget: { didForget = true }
        )

        XCTAssertTrue(matched)
        XCTAssertTrue(didForget)
    }

    func testFailedCleanupPreservesOriginalActivationError() async {
        do {
            _ = try await PaykitSdkService.completeAuthActivation(
                sessionSecret: "new-session",
                activate: { throw CancellationError() },
                discardSessionAccess: { session in
                    _ = await PaykitSdkService.discardAuthSession(
                        sessionSecret: session,
                        storedSessionSecret: { "new-session" },
                        revoke: { throw PubkyServiceError.sessionNotActive },
                        forget: { throw PubkyServiceError.sessionNotActive }
                    )
                }
            )
            XCTFail("Expected activation cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private final class IdentityReadFailureSdk: PaykitSdk, @unchecked Sendable {
    var failure: Error = PubkyServiceError.sessionNotActive

    override func identityStatus() async throws -> IdentityStatus? {
        throw failure
    }
}

@MainActor
private final class UnavailableProfileManager: PubkyProfileManager {
    override func loadProfile() async {}
}

private final class CacheActivationSdk: PaykitSdk, @unchecked Sendable {
    var previousKey: String?

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: previousKey, liveSessionAvailable: false)
    }

    override func initialize() async throws -> InitializationReport {
        InitializationReport(identity: IdentityStatus(publicKey: previousKey, liveSessionAvailable: false))
    }
}

private final class CanceledActivationSdk: PaykitSdk, @unchecked Sendable {
    var initializeOperation: () async -> Void = {}
    var signOutOperation: () async -> Void = {}

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: nil, liveSessionAvailable: false)
    }

    override func initialize() async throws -> InitializationReport {
        await initializeOperation()
        return InitializationReport(identity: IdentityStatus(publicKey: nil, liveSessionAvailable: false))
    }

    override func signOut() async throws -> IdentityStatus {
        await signOutOperation()
        try? Keychain.delete(key: .paykitSession)
        return IdentityStatus(publicKey: nil, liveSessionAvailable: false)
    }
}

private final class CanceledActivationBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    var request: Paykit.PubkyAuthRequest!

    override func startSignInAuth(capabilities _: String) async throws -> Paykit.PubkyAuthRequest {
        request
    }

    override func republishIdentity(publicKey _: String) async throws -> Bool {
        true
    }
}

private final class CanceledActivationAuthRequest: Paykit.PubkyAuthRequest, @unchecked Sendable {
    var result: PubkySessionBootstrapResult!

    override func authorizationUrl() async throws -> String {
        "pubkyauth://test"
    }

    override func complete(
        localSecretKey _: PubkyLocalSecretKey?,
        receiverNoiseSecretKey _: ReceiverNoiseSecretKey,
        requiredCapabilities _: String
    ) async throws -> PubkySessionBootstrapResult {
        result
    }
}

private final class CacheActivationBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    override func republishIdentity(publicKey _: String) async throws -> Bool {
        true
    }
}

private final class CacheActivationSession: PubkySessionAccess, @unchecked Sendable {
    var noiseBytes = Data()

    override func exportSessionSecret() -> String {
        "new-session"
    }

    override func exportLocalSecretKey() -> PubkyLocalSecretKey? {
        nil
    }

    override func exportReceiverNoiseSecretKey() -> ReceiverNoiseSecretKey {
        let key = CacheActivationNoiseKey(noPointer: .init())
        key.bytes = noiseBytes
        return key
    }
}

private final class CacheActivationNoiseKey: ReceiverNoiseSecretKey, @unchecked Sendable {
    var bytes = Data()

    override func exportBytes() -> Data {
        bytes
    }
}

private final class RecoverySdk: PaykitSdk, @unchecked Sendable {
    var onForget: () -> Void = {}

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: nil, liveSessionAvailable: false)
    }

    override func initialize() async throws -> InitializationReport {
        InitializationReport(identity: IdentityStatus(publicKey: nil, liveSessionAvailable: false))
    }

    override func backupStateRevision() async throws -> String {
        "unchanged"
    }

    override func forgetSessionAccess() async throws -> IdentityStatus {
        onForget()
        try Keychain.delete(key: .paykitSession)
        try Keychain.delete(key: .pubkySecretKey)
        return IdentityStatus(publicKey: nil, liveSessionAvailable: false)
    }
}

private final class RecoveryBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    var importSessionOperation: () async throws -> Void = {}
    var result: PubkySessionBootstrapResult!

    override func importSession(
        sessionSecret _: String, localSecretKey _: PubkyLocalSecretKey?,
        receiverNoiseSecretKey _: ReceiverNoiseSecretKey, requiredCapabilities _: String
    ) async throws -> PubkySessionBootstrapResult {
        try await importSessionOperation()
        return result
    }

    override func signIn(
        localSecretKey _: PubkyLocalSecretKey, receiverNoiseSecretKey _: ReceiverNoiseSecretKey, requiredCapabilities _: String
    ) async throws -> PubkySessionBootstrapResult {
        result
    }

    override func republishIdentity(publicKey _: String) async throws -> Bool {
        true
    }
}

private actor TestAsyncCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
