@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    private let externalAuthURL =
        "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
        "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
        "&cid=paykit.test&cpk=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"

    func testRegisteredIdentityCannotActivateAfterWalletWipe() async throws {
        let keys: [KeychainEntryType] = [.paykitSession]
        let saved = try keys.map { try Keychain.load(key: $0) }
        defer {
            for (key, data) in zip(keys, saved) {
                if let data { try? Keychain.upsert(key: key, data: data) }
                else { try? Keychain.delete(key: key) }
            }
        }
        let bootstrap = CacheActivationBootstrap(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { CacheActivationSdk(noPointer: .init()) }) { _, _ in bootstrap }
        let identity = try await service.registerIdentity(
            secretKeyHex: String(repeating: "01", count: 32), homeserverPublicKey: "test", signupCode: nil
        )

        try await service.withWalletWipe { try Keychain.delete(key: .paykitSession) }
        do {
            try await service.activateRegisteredIdentity(identity)
            XCTFail("Registration from the wiped wallet must not persist a session")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        XCTAssertNil(try Keychain.load(key: .paykitSession))
        let freshIdentity = try await service.registerIdentity(
            secretKeyHex: String(repeating: "02", count: 32), homeserverPublicKey: "test", signupCode: nil
        )
        XCTAssertNotEqual(identity.walletGeneration, freshIdentity.walletGeneration)
    }

    func testPaykitKeyForAuthorizationPreservesPerIdentityGenerationHighWater() async throws {
        let secrets = [String(repeating: "11", count: 32), String(repeating: "12", count: 32)]
        let roots = try secrets.map { try PaykitSdkService.localSecretKey(fromHex: $0) }
        let publicKeys = try roots.map { try Paykit.pubkyPublicKeyFromSecret(localSecretKey: $0) }
        let keys = publicKeys.map { KeychainEntryType.paykitKeyGeneration(publicKey: $0) }
        let savedValues = try keys.map { try Keychain.load(key: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, savedValues) {
                if let value {
                    try Keychain.upsert(key: key, data: value)
                } else {
                    try Keychain.delete(key: key)
                }
            }
        }
        for key in keys {
            try Keychain.delete(key: key)
        }

        let steps: [(identity: Int, generation: UInt64?, readFails: Bool, expectedGeneration: UInt64?, highWater: [UInt64?])] = [
            (0, nil, false, 1, [1, nil]),
            (0, 3, false, 3, [3, nil]),
            (0, 3, false, 3, [3, nil]),
            (0, 2, false, nil, [3, nil]),
            (0, nil, false, nil, [3, nil]),
            (0, nil, true, nil, [3, nil]),
            (1, nil, false, 1, [3, 1]),
            (0, 4, false, 4, [4, 1]),
            (0, 3, false, nil, [4, 1]),
        ]
        for (index, step) in steps.enumerated() {
            let sdk = CacheActivationSdk(noPointer: .init())
            sdk.registry = step.generation.map {
                PaykitAppRegistry(keyGeneration: $0, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
            }
            sdk.registryError = step.readFails ? PaykitError.Storage(code: "registry_unavailable", context: "registry read failed") : nil
            let service = PaykitSdkService(sdkFactory: { sdk })
            let previousValues = try keys.map { try Keychain.load(key: $0) }

            do {
                let key = try await service.paykitKeyForAuthorization(secretKeyHex: secrets[step.identity])
                if let generation = step.expectedGeneration {
                    XCTAssertEqual(key.keyGeneration(), generation, "Step \(index)")
                    XCTAssertEqual(
                        key.exportBytes(),
                        try roots[step.identity].derivePaykitIdentitySecretKey(keyGeneration: generation).exportBytes(),
                        "Step \(index)"
                    )
                } else {
                    XCTFail("Step \(index) must reject an unavailable or stale registry")
                }
            } catch {
                XCTAssertNil(step.expectedGeneration, "Step \(index): \(error)")
                switch error {
                case let PaykitError.Storage(code, _):
                    XCTAssertTrue(step.readFails, "Step \(index)")
                    XCTAssertEqual(code, "registry_unavailable")
                case let PaykitError.Identity(code, _):
                    XCTAssertFalse(step.readFails, "Step \(index)")
                    XCTAssertEqual(code, "stale_paykit_key_generation")
                default:
                    XCTFail("Unexpected error at step \(index): \(error)")
                }
            }

            XCTAssertEqual(sdk.registryPublicKeys, [publicKeys[step.identity]], "Step \(index)")
            let persistedValues = try keys.map { try Keychain.load(key: $0) }
            XCTAssertEqual(
                try persistedValues.map { try $0.map { try JSONDecoder().decode(UInt64.self, from: $0) } },
                step.highWater,
                "Step \(index)"
            )
            if step.expectedGeneration == nil {
                XCTAssertEqual(persistedValues, previousValues, "Rejected authorization must preserve the high-water entries")
            }
        }
    }

    func testIdentityReadFailurePreservesSavedCredentials() async throws {
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey]
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
        let secret = Data(String(repeating: "01", count: 32).utf8)
        let session = Data("saved grant".utf8)
        for failure in [
            PaykitError.Identity(code: "identity_error", context: "restore Pubky grant session from platform provider"),
            PaykitError.Storage(code: "storage_error", context: "unavailable"),
        ] {
            try Keychain.upsert(key: .pubkySecretKey, data: secret)
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
            XCTAssertEqual(try Keychain.load(key: .pubkySecretKey), secret)
            XCTAssertEqual(try Keychain.load(key: .paykitSession), session)
        }
    }

    @MainActor
    func testIdentityActivationSeparatesCacheAndPreservesSameOwnerOrLegacyBackup() async throws {
        let defaults = UserDefaults.standard
        let metadataKeys = ["pubky_profile_name", "pubky_profile_image_uri"]
        let savedMetadata = metadataKeys.map { defaults.object(forKey: $0) }
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        let savedReference = AdoptedPubkyReference.current
        let secret = String(repeating: "01", count: 32)
        let publicKey = try PubkyProfileManager.publicKeyFromSecretKey(secret)
        let credentialKeys: [KeychainEntryType] = [
            .paykitSession, .pubkySecretKey, .paykitKeyGeneration(publicKey: publicKey),
        ]
        let savedCredentials = try credentialKeys.map { try Keychain.load(key: $0) }
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(metadataKeys, savedMetadata) {
                defaults.set(value, forKey: key)
            }
            ContactsManager.restoreContactProfileOverrides(savedOverrides)
            for (key, data) in zip(credentialKeys, savedCredentials) {
                if let data {
                    try? Keychain.upsert(key: key, data: data)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        AdoptedPubkyReference.current = nil
        try Keychain.delete(key: .paykitKeyGeneration(publicKey: publicKey))
        let originalKey = String(publicKey.dropFirst("pubky".count))
        let differentKey = try PubkyProfileManager.publicKeyFromSecretKey(String(repeating: "02", count: 32))
        let overrides = [originalKey: PubkyProfileData(name: "Private label", bio: "", image: nil, links: [], tags: [])]
        for previousKey in [originalKey, "pubky\(originalKey)", differentKey, nil] {
            defaults.set("Original profile", forKey: metadataKeys[0])
            defaults.set("pubky://original/avatar", forKey: metadataKeys[1])
            ContactsManager.restoreContactProfileOverrides(overrides)
            let manager = UnavailableProfileManager()
            await manager.initialize { .restorationFailed }
            let sdk = CacheActivationSdk(noPointer: .init())
            sdk.previousKey = previousKey
            let service = PaykitSdkService(sdkFactory: { sdk }) { _, _ in CacheActivationBootstrap(noPointer: .init()) }
            let session = CacheActivationSession(noPointer: .init())
            session.localSecretKey = try PaykitSdkService.localSecretKey(fromHex: secret)
            let result = PubkySessionBootstrapResult(sessionAccess: session, publicKey: publicKey, capability: .privateLinkCapable)

            try await service.activateRegisteredIdentity(.init(result: result, walletGeneration: 0))
            await manager.initialize { .restored(publicKey: "pubky\(originalKey)") }

            XCTAssertEqual(manager.publicKey, "pubky\(originalKey)")
            XCTAssertEqual(try Keychain.loadString(key: .paykitSession), "new-session")
            XCTAssertEqual(try Keychain.loadString(key: .pubkySecretKey), secret)
            XCTAssertEqual(sdk.activationEvents, ["registry", "initialize"])
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

    @MainActor
    func testFailedIdentityActivationPreservesPreviousCredentialsAndMetadata() async throws {
        let defaults = UserDefaults.standard
        let metadataKeys = ["pubky_profile_name", "pubky_profile_image_uri"]
        let savedMetadata = metadataKeys.map { defaults.object(forKey: $0) }
        let savedOverrides = ContactsManager.backupContactProfileOverrides()
        let savedReference = AdoptedPubkyReference.current
        let oldSecret = String(repeating: "01", count: 32)
        let differentSecret = String(repeating: "02", count: 32)
        let previousKey = try PubkyProfileManager.publicKeyFromSecretKey(oldSecret)
        let differentKey = try PubkyProfileManager.publicKeyFromSecretKey(differentSecret)
        let keys: [KeychainEntryType] = [
            .paykitSession, .pubkySecretKey,
            .paykitKeyGeneration(publicKey: previousKey), .paykitKeyGeneration(publicKey: differentKey),
        ]
        let saved = try keys.map { try Keychain.load(key: $0) }
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(metadataKeys, savedMetadata) {
                defaults.set(value, forKey: key)
            }
            ContactsManager.restoreContactProfileOverrides(savedOverrides)
            for (key, data) in zip(keys, saved) {
                if let data {
                    try? Keychain.upsert(key: key, data: data)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        AdoptedPubkyReference.current = nil
        try Keychain.delete(key: .paykitKeyGeneration(publicKey: previousKey))
        try Keychain.delete(key: .paykitKeyGeneration(publicKey: differentKey))
        let sharedPubky = try SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: oldSecret)
        let savedSharedSecret = SharedPubkyKeychain.loadSecret(sourceApp: SharedPubkyKeychain.ownSourceApp, pubky: sharedPubky)
        defer {
            if let savedSharedSecret {
                SharedPubkyKeychain.publishOwn(pubky: sharedPubky, secretKeyHex: savedSharedSecret)
            } else {
                SharedPubkyKeychain.removeOwn(pubky: sharedPubky)
            }
        }
        SharedPubkyKeychain.publishOwn(pubky: sharedPubky, secretKeyHex: oldSecret)
        let overrides = [previousKey: PubkyProfileData(name: "Private label", bio: "", image: nil, links: [], tags: [])]
        for newSecret in [oldSecret, differentSecret] {
            for failingStep in ["registry", "initialize"] {
                defaults.set("Original profile", forKey: metadataKeys[0])
                defaults.set("pubky://original/avatar", forKey: metadataKeys[1])
                ContactsManager.restoreContactProfileOverrides(overrides)
                try Keychain.upsert(key: .paykitSession, data: Data("previous-session".utf8))
                try Keychain.upsert(key: .pubkySecretKey, data: Data(oldSecret.utf8))
                let sdk = CacheActivationSdk(noPointer: .init())
                sdk.previousKey = previousKey
                let failure = PubkyServiceError.authFailed("\(failingStep) unavailable")
                sdk.registryError = failingStep == "registry" ? failure : nil
                sdk.initializationError = failingStep == "initialize" ? failure : nil
                let service = PaykitSdkService(sdkFactory: { sdk }) { _, _ in CacheActivationBootstrap(noPointer: .init()) }
                let session = CacheActivationSession(noPointer: .init())
                session.localSecretKey = try PaykitSdkService.localSecretKey(fromHex: newSecret)
                let newKey = try PubkyProfileManager.publicKeyFromSecretKey(newSecret)

                do {
                    try await service.activateRegisteredIdentity(.init(
                        result: .init(sessionAccess: session, publicKey: newKey, capability: .privateLinkCapable), walletGeneration: 0
                    ))
                    XCTFail("Expected activation to fail after staging the new session")
                } catch {
                    XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
                }
                XCTAssertEqual(SharedPubkyKeychain.loadSecret(sourceApp: SharedPubkyKeychain.ownSourceApp, pubky: sharedPubky), oldSecret)
                XCTAssertEqual(try Keychain.loadString(key: .paykitSession), "previous-session")
                XCTAssertEqual(try Keychain.loadString(key: .pubkySecretKey), oldSecret)
                XCTAssertEqual(sdk.activationEvents, failingStep == "registry" ? ["registry"] : ["registry", "initialize"])
                let relaunched = UnavailableProfileManager()
                XCTAssertEqual(relaunched.displayName, "Original profile")
                XCTAssertEqual(relaunched.displayImageUri, "pubky://original/avatar")
                XCTAssertEqual(ContactsManager.backupContactProfileOverrides(), overrides)
            }
        }
    }

    func testSessionRecoveryCannotReactivateCredentialsAfterForget() async throws {
        let savedReference = AdoptedPubkyReference.current
        let secret = String(repeating: "01", count: 32)
        let publicKey = try PubkyProfileManager.publicKeyFromSecretKey(secret)
        let keys: [KeychainEntryType] = [
            .paykitSession, .pubkySecretKey, .paykitKeyGeneration(publicKey: publicKey),
        ]
        let saved = try keys.map { try Keychain.load(key: $0) }
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, data) in zip(keys, saved) {
                if let data {
                    try? Keychain.upsert(key: key, data: data)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        AdoptedPubkyReference.current = nil
        try Keychain.delete(key: .paykitKeyGeneration(publicKey: publicKey))
        try Keychain.upsert(key: .paykitSession, data: Data("saved-session".utf8))
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secret.utf8))
        let started = expectation(description: "import started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let bootstrap = RecoveryBootstrap(noPointer: .init())
        bootstrap.importSessionOperation = {
            started.fulfill()
            for await _ in stream {}
            throw PubkyServiceError.authFailed("expired session")
        }
        let session = CacheActivationSession(noPointer: .init())
        session.localSecretKey = try PaykitSdkService.localSecretKey(fromHex: secret)
        bootstrap.result = PubkySessionBootstrapResult(
            sessionAccess: session, publicKey: publicKey, capability: .privateLinkCapable
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
    var registry: PaykitAppRegistry?
    var registryPublicKeys: [String] = []
    var registryError: Error?
    var initializationError: Error?
    var activationEvents: [String] = []

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: previousKey, capability: .signedOut)
    }

    override func paykitAppRegistry(publicKey: String) async throws -> PaykitAppRegistry? {
        activationEvents.append("registry")
        registryPublicKeys.append(publicKey)
        if let registryError {
            throw registryError
        }
        return registry
    }

    override func initialize() async throws -> IdentityStatus {
        activationEvents.append("initialize")
        if let initializationError {
            throw initializationError
        }
        return IdentityStatus(publicKey: previousKey, capability: .signedOut)
    }
}

private final class CacheActivationBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    override func signUp(
        localSecretKey _: PubkyLocalSecretKey,
        homeserverPublicKey _: String,
        signupCode _: String?,
        requiredCapabilities _: String
    ) async throws -> PubkySessionBootstrapResult {
        PubkySessionBootstrapResult(
            sessionAccess: CacheActivationSession(noPointer: .init()),
            publicKey: "pubky_test",
            capability: .privateLinkCapable
        )
    }

    override func republishIdentity(publicKey _: String) async throws -> Bool {
        true
    }
}

private final class CacheActivationSession: PubkySessionAccess, @unchecked Sendable {
    var localSecretKey: PubkyLocalSecretKey?

    override func exportSessionSecret() -> String {
        "new-session"
    }

    override func exportLocalSecretKey() -> PubkyLocalSecretKey? {
        localSecretKey
    }

    override func exportPaykitIdentitySecretKey() -> PaykitIdentitySecretKey? {
        nil
    }
}

private final class RecoverySdk: PaykitSdk, @unchecked Sendable {
    var onForget: () -> Void = {}

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: nil, capability: .signedOut)
    }

    override func paykitAppRegistry(publicKey _: String) async throws -> PaykitAppRegistry? {
        nil
    }

    override func initialize() async throws -> IdentityStatus {
        IdentityStatus(publicKey: nil, capability: .signedOut)
    }

    override func backupStateRevision() async throws -> String {
        "unchanged"
    }

    override func forgetSessionAccess() async throws -> IdentityStatus {
        onForget()
        try Keychain.delete(key: .paykitSession)
        try Keychain.delete(key: .pubkySecretKey)
        return IdentityStatus(publicKey: nil, capability: .signedOut)
    }
}

private final class RecoveryBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    var importSessionOperation: () async throws -> Void = {}
    var result: PubkySessionBootstrapResult!

    override func importSession(
        sessionSecret _: String, localSecretKey _: PubkyLocalSecretKey?,
        requiredCapabilities _: String
    ) async throws -> PubkySessionBootstrapResult {
        try await importSessionOperation()
        return result
    }

    override func signIn(
        localSecretKey _: PubkyLocalSecretKey, requiredCapabilities _: String
    ) async throws -> PubkySessionBootstrapResult {
        result
    }

    override func republishIdentity(publicKey _: String) async throws -> Bool {
        true
    }
}
