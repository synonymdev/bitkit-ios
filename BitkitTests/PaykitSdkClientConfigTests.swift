@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    private let externalAuthURL =
        "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
        "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
        "&cid=paykit.test&cpk=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"

    @MainActor
    func testPrivateLinkCallsAdvanceOnceAndAllowPendingHandshakesToResume() async throws {
        try await withCachedSessionKey { service, sdk, _ in
            let pending = try await service.ensureLinkWithPeer("peer")
            XCTAssertEqual(pending.state, .linking)
            sdk.handshakeState = .linked
            let linked = try await service.ensureLinkWithPeer("peer")
            XCTAssertEqual(linked.state, .linked)

            let preparations: [() async throws -> PreparedPrivateContactPayment] = [
                { try await service.prepareAndResolvePrivateContactPayment(counterparty: "peer", afterPrivatePaymentListVersion: nil) },
                {
                    try await service.prepareAndResolvePrivatePaymentRequest(
                        counterparty: "peer", paymentRequestId: "request", afterPrivatePaymentListVersion: nil
                    )
                },
            ]
            for prepare in preparations {
                do {
                    _ = try await prepare()
                    XCTFail("Pending preparation must remain retryable")
                } catch PaykitError.RecoveryRequired {}
            }
            XCTAssertEqual(sdk.handshakeAdvanceSteps, [1, 1, 1, 1])
        }
    }

    func testRegisteredIdentityCannotActivateAfterWalletWipe() async throws {
        let keys: [KeychainEntryType] = [.paykitSession]
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

    @MainActor
    func testSessionKeyCacheRefreshesForIdentityGenerationAndRuntimeChanges() async throws {
        let secrets = [String(repeating: "21", count: 32), String(repeating: "22", count: 32)]
        let publicKeys = try secrets.map { try PubkyProfileManager.publicKeyFromSecretKey($0) }
        let keys: [KeychainEntryType] = [.pubkySecretKey] + publicKeys.map { .paykitKeyGeneration(publicKey: $0) }
        let saved = try keys.map { try Keychain.load(key: $0) }
        let savedReference = AdoptedPubkyReference.current
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, saved) {
                if let value {
                    try? Keychain.upsert(key: key, data: value)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        AdoptedPubkyReference.current = nil
        for key in keys {
            try Keychain.delete(key: key)
        }
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secrets[0].utf8))
        let sdk = CacheActivationSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk }) { _, _ in CacheActivationBootstrap(noPointer: .init()) }

        _ = try await service.contactRecords()
        _ = try await service.contactRecords()
        XCTAssertEqual(sdk.registryPublicKeys, [publicKeys[0]])

        sdk.registry = PaykitAppRegistry(keyGeneration: 2, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
        let authorizationKey = try await service.paykitKeyForAuthorization(secretKeyHex: secrets[0])
        XCTAssertEqual(authorizationKey.keyGeneration(), 2)
        _ = try await service.contactRecords()
        XCTAssertEqual(sdk.registryPublicKeys.count, 3)

        try Keychain.upsert(key: .pubkySecretKey, data: Data(secrets[1].utf8))
        _ = try await service.contactRecords()
        XCTAssertEqual(sdk.registryPublicKeys.last, publicKeys[1])
        XCTAssertEqual(sdk.registryPublicKeys.count, 4)

        await service.clearState()
        _ = try await service.contactRecords()
        XCTAssertEqual(sdk.registryPublicKeys.count, 5)

        sdk.registryError = PubkyServiceError.authFailed("Registry unavailable")
        do {
            try await service.initialize()
            XCTFail("Forced validation must report the registry failure")
        } catch {}
        do {
            _ = try await service.contactRecords()
            XCTFail("Failed forced validation must not reuse the previous key cache")
        } catch {}
        XCTAssertEqual(sdk.registryPublicKeys.count, 7)
    }

    @MainActor
    func testSessionKeyCacheRefreshesAfterRemoteGenerationFailureWithoutReplayingOperations() async throws {
        let operations: [(PaykitSdkService) async throws -> Void] = [
            { _ = try await $0.contactRecords() },
            { _ = try await $0.cancelPaymentRequest(counterparty: "peer", paymentRequestId: "request") },
        ]
        for operation in operations {
            try await withCachedSessionKey { service, sdk, generationKey in
                sdk.registry = PaykitAppRegistry(keyGeneration: 3, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
                sdk.operationError = PaykitError.Identity(
                    code: "identity_error",
                    context: "Paykit key generation 1 does not match shared-state generation 3"
                )
                do {
                    try await operation(service)
                    XCTFail("The failed operation must not be retried")
                } catch {
                    XCTAssertEqual(String(describing: error), String(describing: sdk.operationError!))
                }
                XCTAssertEqual(sdk.operationCalls, 2)
                XCTAssertEqual(sdk.registryPublicKeys.count, 1)
                XCTAssertEqual(try Keychain.load(key: generationKey), try JSONEncoder().encode(UInt64(1)))

                sdk.operationError = nil
                _ = try await service.contactRecords()
                XCTAssertEqual(sdk.registryPublicKeys.count, 2)
                XCTAssertEqual(try Keychain.load(key: generationKey), try JSONEncoder().encode(UInt64(3)))
                _ = try await service.contactRecords()
                XCTAssertEqual(sdk.registryPublicKeys.count, 2)
            }
        }
    }

    @MainActor
    func testRemoteGenerationRecoveryPreservesFloorWhenRegistryIsStaleMissingOrUnavailable() async throws {
        try await withCachedSessionKey { service, sdk, generationKey in
            for generation: UInt64 in [3, 2] {
                sdk.operationError = PaykitError.Identity(code: "identity_error", context: "Paykit key generation mismatch")
                do {
                    _ = try await service.contactRecords()
                    XCTFail("Expected an identity failure")
                } catch {}
                sdk.operationError = nil
                sdk.registry = PaykitAppRegistry(
                    keyGeneration: generation,
                    noisePublicKey: nil,
                    apps: [],
                    defaultAppId: nil,
                    defaultAppsByEndpoint: [:]
                )
                if generation == 3 {
                    _ = try await service.contactRecords()
                    continue
                }
                let previousCalls = sdk.operationCalls
                for attempt in 0 ..< 3 {
                    if attempt > 0 { sdk.registry = nil }
                    if attempt == 2 { sdk.registryError = PaykitError.Storage(code: "registry_unavailable", context: "unavailable") }
                    do {
                        _ = try await service.contactRecords()
                        XCTFail("An invalid registry must not reuse the cached key")
                    } catch let PaykitError.Identity(code, _) {
                        XCTAssertEqual(code, "stale_paykit_key_generation")
                    } catch let PaykitError.Storage(code, _) {
                        XCTAssertEqual(code, "registry_unavailable")
                    }
                    XCTAssertEqual(sdk.operationCalls, previousCalls)
                    XCTAssertEqual(try Keychain.load(key: generationKey), try JSONEncoder().encode(UInt64(3)))
                }
                XCTAssertEqual(sdk.registryPublicKeys.count, 5)
                sdk.registryError = nil
                sdk.registry = PaykitAppRegistry(keyGeneration: 4, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
                _ = try await service.contactRecords()
                XCTAssertEqual(try Keychain.load(key: generationKey), try JSONEncoder().encode(UInt64(4)))
            }
        }
    }

    @MainActor
    func testUnrelatedSdkFailuresKeepSessionKeyCache() async throws {
        try await withCachedSessionKey { service, sdk, _ in
            for failure in [PaykitError.Storage(code: "unavailable", context: "offline"), CancellationError()] as [Error] {
                sdk.operationError = failure
                do {
                    _ = try await service.contactRecords()
                    XCTFail("Expected the operation failure")
                } catch {
                    XCTAssertEqual(String(describing: error), String(describing: failure))
                }
                sdk.operationError = nil
                _ = try await service.contactRecords()
                XCTAssertEqual(sdk.registryPublicKeys.count, 1)
            }
        }
    }

    @MainActor
    func testBestEffortSdkIdentityFailuresInvalidateSessionKeyCache() async throws {
        for publicationFails in [true, false] {
            try await withCachedSessionKey { service, sdk, generationKey in
                let failure = PaykitError.Identity(code: "identity_error", context: "Paykit key generation mismatch")
                sdk.capability = .privateLinkCapable
                if publicationFails {
                    sdk.publicationError = failure
                    try await service.initialize()
                } else {
                    sdk.backupError = failure
                    try await service.syncPaykitApp(privatePaymentsEnabled: true)
                }
                XCTAssertEqual(sdk.publicationCalls, 1)
                let previousReads = sdk.registryPublicKeys.count
                sdk.registry = PaykitAppRegistry(keyGeneration: 2, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
                sdk.publicationError = nil
                sdk.backupError = nil
                _ = try await service.contactRecords()
                XCTAssertEqual(sdk.registryPublicKeys.count, previousReads + 1)
                XCTAssertEqual(try Keychain.load(key: generationKey), try JSONEncoder().encode(UInt64(2)))
            }
        }
    }

    @MainActor
    private func withCachedSessionKey(
        _ operation: (PaykitSdkService, CacheActivationSdk, KeychainEntryType) async throws -> Void
    ) async throws {
        let secret = String(repeating: "23", count: 32)
        let publicKey = try PubkyProfileManager.publicKeyFromSecretKey(secret)
        let generationKey = KeychainEntryType.paykitKeyGeneration(publicKey: publicKey)
        let keys: [KeychainEntryType] = [.pubkySecretKey, generationKey]
        let saved = try keys.map { try Keychain.load(key: $0) }
        let savedReference = AdoptedPubkyReference.current
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, saved) {
                if let value {
                    try? Keychain.upsert(key: key, data: value)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }
        AdoptedPubkyReference.current = nil
        try Keychain.delete(key: generationKey)
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secret.utf8))
        let sdk = CacheActivationSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk }) { _, _ in CacheActivationBootstrap(noPointer: .init()) }
        _ = try await service.contactRecords()
        try await operation(service, sdk, generationKey)
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
    func testIdentityActivationSeparatesCacheAndPreservesSameOwner() async throws {
        let defaults = UserDefaults.standard
        let metadataKeys = ["pubky_profile_name", "pubky_profile_image_uri", "pubky_profile_identity"]
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
            defaults.removeObject(forKey: metadataKeys[2])
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
            XCTAssertEqual(sdk.activationEvents, ["registry", "initialize", "authorize"])
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

        defaults.set(differentKey, forKey: metadataKeys[2])
        defaults.set("Other identity", forKey: metadataKeys[0])
        ContactsManager.restoreContactProfileOverrides(overrides)
        PubkyProfileManager.activateCachedIdentity(publicKey: publicKey, previousPublicKey: nil)
        XCTAssertNil(defaults.string(forKey: metadataKeys[0]))
        XCTAssertNil(ContactsManager.backupContactProfileOverrides())
        XCTAssertEqual(defaults.string(forKey: metadataKeys[2]), publicKey)
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
            for failingStep in ["registry", "initialize", "authorize"] {
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
                sdk.authorizationError = failingStep == "authorize" ? failure : nil
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
                let expectedEvents = ["registry", "initialize", "authorize"].prefix(while: { event in
                    event != failingStep
                }) + [failingStep]
                XCTAssertEqual(sdk.activationEvents, Array(expectedEvents))
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
        XCTAssertEqual(sdk.initializationCalls, 1)
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
    var handshakeState: LinkedPeerState = .linking
    var handshakeAdvanceSteps: [UInt32] = []
    var previousKey: String?
    var capability: PubkyIdentityCapability = .signedOut
    var registry: PaykitAppRegistry?
    var registryPublicKeys: [String] = []
    var registryError: Error?
    var initializationError: Error?
    var activationEvents: [String] = []
    var operationError: Error?
    var operationCalls = 0
    var publicationError: Error?
    var publicationCalls = 0
    var authorizationError: Error?
    var backupError: Error?

    override func ensureLinkWithPeer(counterparty: String, maxAdvanceSteps: UInt32) async throws -> LinkedPeerHandshakeReport {
        handshakeAdvanceSteps.append(maxAdvanceSteps)
        return LinkedPeerHandshakeReport(counterparty: counterparty, state: handshakeState, generation: 1, handshakeRole: nil)
    }

    override func prepareAndResolvePrivateContactPayment(
        counterparty _: String, amount _: PaymentAmountContext?, afterPrivatePaymentListVersion _: UInt64?, maxAdvanceSteps: UInt32
    ) async throws -> PreparedPrivateContactPayment {
        handshakeAdvanceSteps.append(maxAdvanceSteps)
        throw PaykitError.RecoveryRequired(code: "recovery_required", context: "Handshake pending")
    }

    override func prepareAndResolvePrivatePaymentRequest(
        counterparty _: String, paymentRequestId _: String, afterPrivatePaymentListVersion _: UInt64?, maxAdvanceSteps: UInt32
    ) async throws -> PreparedPrivateContactPayment {
        handshakeAdvanceSteps.append(maxAdvanceSteps)
        throw PaykitError.RecoveryRequired(code: "recovery_required", context: "Handshake pending")
    }

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: previousKey, capability: capability)
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
        return IdentityStatus(publicKey: previousKey, capability: capability)
    }

    override func contactRecords() async throws -> [ContactRecord] {
        operationCalls += 1
        if let operationError { throw operationError }
        return []
    }

    override func cancelPaymentRequest(counterparty _: String, paymentRequestId _: String, reason _: String?) async throws -> PaymentRequestRecord {
        operationCalls += 1
        throw operationError ?? PubkyServiceError.sessionNotActive
    }

    override func publishPaykitApp(displayName _: String, capabilities _: PaykitAppCapabilities) async throws -> PaykitAppRegistry {
        publicationCalls += 1
        if let publicationError { throw publicationError }
        return registry ?? PaykitAppRegistry(keyGeneration: 1, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
    }

    override func publishPaykitNoiseKeyAuthorization() async throws -> PaykitNoiseKeyAuthorization {
        activationEvents.append("authorize")
        if let authorizationError { throw authorizationError }
        return PaykitNoiseKeyAuthorization(owner: "identity", noisePublicKey: "noise", noiseStaticPublicKey: "static", keyGeneration: 1)
    }

    override func backupStateRevision() async throws -> String {
        if let backupError { throw backupError }
        return "unchanged"
    }

    override func stateRevision() throws -> String? {
        "state"
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
    var initializationCalls = 0

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: nil, capability: .signedOut)
    }

    override func paykitAppRegistry(publicKey _: String) async throws -> PaykitAppRegistry? {
        nil
    }

    override func initialize() async throws -> IdentityStatus {
        initializationCalls += 1
        return IdentityStatus(publicKey: nil, capability: .signedOut)
    }

    override func publishPaykitNoiseKeyAuthorization() async throws -> PaykitNoiseKeyAuthorization {
        PaykitNoiseKeyAuthorization(owner: "identity", noisePublicKey: "noise", noiseStaticPublicKey: "static", keyGeneration: 1)
    }

    override func backupStateRevision() async throws -> String {
        "unchanged"
    }

    override func stateRevision() throws -> String? {
        nil
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
