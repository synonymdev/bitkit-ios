@testable import Bitkit
import class Paykit.PubkySessionAccess
import struct Paykit.PubkySessionBootstrapResult
import XCTest

final class PubkyProfileManagerTests: XCTestCase {
    @MainActor
    func testForegroundMaintenanceWaitsForSharedIdentityValidation() async {
        let validationStarted = expectation(description: "Shared identity validation started")
        let validation = AsyncStream<Bool>.makeStream()
        var walletPaykitPermission: Bool?
        var didRunPaykitMaintenance = false

        let task = Task { @MainActor in
            await AppScene.performForegroundMaintenance(
                waitForSharedIdentityValidation: {
                    validationStarted.fulfill()
                    for await result in validation.stream {
                        return result
                    }
                    return false
                },
                walletMaintenance: { walletPaykitPermission = $0 },
                paykitMaintenance: { didRunPaykitMaintenance = true }
            )
        }

        await fulfillment(of: [validationStarted], timeout: 1)
        await Task.yield()
        XCTAssertNil(walletPaykitPermission)
        XCTAssertFalse(didRunPaykitMaintenance)

        validation.continuation.yield(true)
        validation.continuation.finish()
        await task.value
        XCTAssertEqual(walletPaykitPermission, true)
        XCTAssertTrue(didRunPaykitMaintenance)
    }

    @MainActor
    func testForegroundMaintenancePreservesWalletSyncButStopsPaykitAfterFailedValidation() async {
        var walletPaykitPermission: Bool?
        var didRunPaykitMaintenance = false

        await AppScene.performForegroundMaintenance(
            waitForSharedIdentityValidation: { false },
            walletMaintenance: { walletPaykitPermission = $0 },
            paykitMaintenance: { didRunPaykitMaintenance = true }
        )

        XCTAssertEqual(walletPaykitPermission, false)
        XCTAssertFalse(didRunPaykitMaintenance)
    }

    @MainActor
    func testFailedSharedSessionRestorationDoesNotAuthorizePaykitMaintenance() {
        XCTAssertTrue(PubkyProfileManager.canPerformPaykitMaintenance(afterSharedSessionRestoration: nil))
        XCTAssertTrue(PubkyProfileManager.canPerformPaykitMaintenance(afterSharedSessionRestoration: .restored(publicKey: "pubky")))
        XCTAssertFalse(PubkyProfileManager.canPerformPaykitMaintenance(afterSharedSessionRestoration: .noSession))
        XCTAssertFalse(PubkyProfileManager.canPerformPaykitMaintenance(afterSharedSessionRestoration: .restorationFailed))
    }

    func testPaykitMaintenancePermissionChangesOnlyForRealAuthenticationTransitions() {
        XCTAssertNil(AppScene.paykitMaintenancePermission(
            previousAuthState: .authenticated,
            authState: .authenticated
        ))
        XCTAssertEqual(AppScene.paykitMaintenancePermission(
            previousAuthState: .idle,
            authState: .authenticated
        ), true)
        XCTAssertEqual(AppScene.paykitMaintenancePermission(
            previousAuthState: .authenticated,
            authState: .idle
        ), false)
    }

    @MainActor
    func testSharedIdentityDiscoveryTransitionsHideCreationUntilSuccessfulEmptyLoad() async {
        let manager = PubkyProfileManager()
        let (stream, continuation) = AsyncStream<[SharedPubkyIdentityRefV1]>.makeStream()

        await manager.refreshSharedRingIdentities(
            isRingAvailable: false,
            loadReferences: {
                XCTFail("Ring absence should complete without reading shared storage")
                return []
            }
        )
        XCTAssertEqual(manager.sharedRingIdentityDiscoveryState, .loaded)

        let loadingStarted = expectation(description: "Shared identity discovery started")
        let refresh = Task { @MainActor in
            await manager.refreshSharedRingIdentities(
                isRingAvailable: true,
                loadReferences: {
                    loadingStarted.fulfill()
                    for await references in stream {
                        return references
                    }
                    return []
                }
            )
        }
        await fulfillment(of: [loadingStarted], timeout: 1)
        XCTAssertEqual(manager.sharedRingIdentityDiscoveryState, .loading)

        continuation.yield([])
        continuation.finish()
        await refresh.value
        XCTAssertEqual(manager.sharedRingIdentityDiscoveryState, .loaded)

        await manager.refreshSharedRingIdentities(
            isRingAvailable: true,
            loadReferences: { throw SharedPubkyIdentityError.temporarilyUnavailable }
        )
        XCTAssertEqual(manager.sharedRingIdentityDiscoveryState, .unavailable)
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
                            if shouldFail, failedStep == "load" { throw failure }
                            return storedKey
                        },
                        signIn: {
                            XCTAssertEqual($0, "existing-key")
                            if shouldFail, failedStep == "signIn" { throw failure }
                            return "pubky_existing"
                        },
                        signUp: {
                            XCTFail("An existing identity must not be registered on another homeserver")
                            return "pubky_new"
                        },
                        createProfile: {
                            if shouldFail, failedStep == "profile" { throw failure }
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
                            if failsToSaveProfile { throw PubkyServiceError.authFailed("profile") }
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
    func testCreateIdentityRefusesToSignUpOverAnUnrecoverableSession() async throws {
        let defaults = UserDefaults.standard
        let previousPending = defaults.object(forKey: "pubky_profile_setup_pending")
        let previousSession = try? Keychain.loadString(key: .paykitSession)
        let previousSecretKey = try? Keychain.loadString(key: .pubkySecretKey)
        addTeardownBlock {
            try? Keychain.delete(key: .paykitSession)
            try? Keychain.delete(key: .pubkySecretKey)
            if let previousSession {
                try? Keychain.saveString(key: .paykitSession, str: previousSession)
            }
            if let previousSecretKey {
                try? Keychain.saveString(key: .pubkySecretKey, str: previousSecretKey)
            }
            defaults.set(previousPending, forKey: "pubky_profile_setup_pending")
        }

        // An external or borrowed session with no local secret to re-sign-in with.
        try Keychain.delete(key: .pubkySecretKey)
        try Keychain.delete(key: .paykitSession)
        try Keychain.saveString(key: .paykitSession, str: "external-session-secret")
        defaults.set(false, forKey: "pubky_profile_setup_pending")
        let manager = KeyDerivationProbeProfileManager()

        do {
            try await manager.createIdentity(name: "Test", bio: "", links: [], loadStoredSecretKey: { nil })
            XCTFail("Expected an unrecoverable session to block identity creation")
        } catch {
            XCTAssertFalse(manager.didDeriveKeys, "A new identity must not be derived over an existing session")
        }

        XCTAssertEqual(try Keychain.loadString(key: .paykitSession), "external-session-secret")
        XCTAssertNil(try Keychain.loadString(key: .pubkySecretKey))
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
                if step == failingStep { throw PubkyServiceError.authFailed(step) }
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

    // MARK: - Ring callbacks

    func testPubkyRingAuthCallbackParsesSuccessCancelAndError() throws {
        XCTAssertEqual(
            try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/success"))),
            .success(nonce: nil)
        )
        XCTAssertEqual(
            try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/cancel"))),
            .cancel(nonce: nil)
        )
        XCTAssertEqual(
            try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/error?errorMessage=Denied"))),
            .error(message: "Denied", nonce: nil)
        )
    }

    func testPubkyRingAuthCallbackParsesNonce() throws {
        XCTAssertEqual(
            try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/error?nonce=abc&errorMessage=Denied"))),
            .error(message: "Denied", nonce: "abc")
        )
    }

    func testPubkyRingAuthCallbackTreatsBareNonceAsMissing() throws {
        XCTAssertEqual(
            try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/cancel?nonce"))),
            .cancel(nonce: nil)
        )
    }

    func testPubkyRingAuthCallbackRejectsOtherDeeplinks() throws {
        XCTAssertNil(try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://wallet/success"))))
        XCTAssertNil(try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "https://pubky-auth/success"))))
        XCTAssertNil(try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/setup"))))
        XCTAssertNil(try PubkyRingAuthCallback.parse(url: XCTUnwrap(URL(string: "bitkit://pubky-auth/unknown"))))
    }

    @MainActor
    func testLegacyRingCallbacksPreserveCurrentIdentityAndAuthenticationState() {
        let callbacks: [PubkyRingAuthCallback] = [
            .success(nonce: nil),
            .success(nonce: UUID().uuidString),
            .cancel(nonce: nil),
            .cancel(nonce: UUID().uuidString),
            .error(message: "Denied", nonce: nil),
            .error(message: "Untrusted callback message", nonce: UUID().uuidString),
        ]
        let states: [PubkyAuthState] = [
            .idle, .authenticating, .completingAuthentication, .authenticated, .error("Existing error"),
        ]
        let publicKeys: [String?] = [nil, "pubky_test"]

        for publicKey in publicKeys {
            for state in states {
                let manager = PubkyProfileManager()
                manager.publicKey = publicKey
                manager.authState = state
                manager.profile = publicKey.map { PubkyProfile.placeholder(publicKey: $0) }

                for callback in callbacks {
                    manager.handleAuthCallback(callback)

                    XCTAssertEqual(manager.publicKey, publicKey)
                    XCTAssertEqual(manager.profile?.publicKey, publicKey)
                    XCTAssertEqual(manager.authState, state)
                }
            }
        }
    }

    @MainActor
    func testIsAuthenticatedUsesRestoredPublicKeyDuringTransientAuthError() {
        let manager = PubkyProfileManager()

        manager.publicKey = "pubky_test"
        manager.authState = .error("Gateway timeout")

        XCTAssertTrue(manager.isAuthenticated)
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

        XCTAssertEqual(snapshot, PubkySessionBackupV1(kind: .localSeed, sessionSecret: nil))
    }

    func testSnapshotSessionBackupStateUsesExternalSessionWhenNoLocalSeed() throws {
        let store = makeKeychainStore(paykitSession: "external-session")

        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { key in
            return store[key.storageKey]
        }

        XCTAssertEqual(snapshot, PubkySessionBackupV1(kind: .externalSession, sessionSecret: "external-session"))
    }

    func testSnapshotSessionBackupStateReturnsNilWhenNoPubkyCredentialsExist() throws {
        let snapshot = try PubkyProfileManager.snapshotSessionBackupState { _ in nil }

        XCTAssertNil(snapshot)
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
            },
            deleteSessionSecret: {
                XCTFail("Session should not be deleted after successful import")
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
            },
            deleteSessionSecret: {
                XCTFail("Session should not be deleted after successful re-sign-in")
            }
        )

        XCTAssertEqual(result, .restored(publicKey: "pubky_test"))
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
            publicKeyFromSecretKey: { _ in
                XCTFail("No public key should be derived when re-sign-in fails")
                return "pubky_unused"
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
            publicKeyFromSecretKey: { _ in
                XCTFail("No public key should be derived without credentials")
                return "pubky_unused"
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
        var didClearSessionAccess = false

        try await PubkyProfileManager.restoreSessionBackupState(
            PubkySessionBackupV1(kind: .externalSession, sessionSecret: "external-session"),
            loadKeychainString: { key in
                return store[key.storageKey]
            },
            persistKeychainString: { key, value in
                store[key.storageKey] = value
            },
            deleteKeychainValue: { key in
                store.removeValue(forKey: key.storageKey)
            },
            deleteBitkitSharedIdentities: {},
            forgetSessionAccess: {
                didClearSessionAccess = true
            },
            signInWithSecretKey: { _ in
                XCTFail("External session restore should not sign in with a local secret")
                return "unused-session"
            },
            importExternalSession: { session in
                XCTAssertEqual(session, "external-session")
                store[KeychainEntryType.paykitSession.storageKey] = session
                store.removeValue(forKey: KeychainEntryType.pubkySecretKey.storageKey)
                return "pubky_external"
            }
        )

        XCTAssertTrue(didClearSessionAccess)
        XCTAssertEqual(store[KeychainEntryType.paykitSession.storageKey], "external-session")
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
    }

    func testRestoreSessionBackupStateClearsCredentialsWhenBackupHasNoPubkyState() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "local-secret"
        )
        var events: [String] = []

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
                if case .pubkySecretKey = key {
                    events.append("private")
                }
            },
            deleteBitkitSharedIdentities: {
                events.append("shared")
            },
            forgetSessionAccess: {
                events.append("session")
            },
            signInWithSecretKey: { _ in
                XCTFail("Missing pubky state should not sign in")
                return "unused-session"
            },
            importExternalSession: { _ in
                XCTFail("Missing pubky state should not import a session")
                return "pubky_unused"
            }
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
        XCTAssertEqual(events, ["shared", "session", "private"])
    }

    func testRestoreSessionBackupStateReplacesSessionWhenForgetFails() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "stale-local-secret"
        )

        try await PubkyProfileManager.restoreSessionBackupState(
            PubkySessionBackupV1(kind: .externalSession, sessionSecret: "backup-session"),
            loadKeychainString: { store[$0.storageKey] },
            persistKeychainString: { store[$0.storageKey] = $1 },
            deleteKeychainValue: { store.removeValue(forKey: $0.storageKey) },
            deleteBitkitSharedIdentities: {},
            forgetSessionAccess: { throw PubkyServiceError.authFailed("offline") },
            signInWithSecretKey: { _ in
                XCTFail("External session restore should not sign in with a local secret")
                return "unused-session"
            },
            importExternalSession: { session in
                store[KeychainEntryType.paykitSession.storageKey] = session
                store.removeValue(forKey: KeychainEntryType.pubkySecretKey.storageKey)
                return "pubky_external"
            }
        )

        XCTAssertEqual(store[KeychainEntryType.paykitSession.storageKey], "backup-session")
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
    }

    func testRestoreSessionBackupStateClearsCredentialsWhenForgetFailsWithoutBackup() async throws {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "stale-local-secret"
        )

        try await PubkyProfileManager.restoreSessionBackupState(
            nil,
            loadKeychainString: { store[$0.storageKey] },
            persistKeychainString: { store[$0.storageKey] = $1 },
            deleteKeychainValue: { store.removeValue(forKey: $0.storageKey) },
            deleteBitkitSharedIdentities: {},
            forgetSessionAccess: { throw PubkyServiceError.authFailed("offline") },
            signInWithSecretKey: { _ in
                XCTFail("Missing pubky state should not sign in")
                return "unused-session"
            },
            importExternalSession: { _ in
                XCTFail("Missing pubky state should not import a session")
                return "pubky_unused"
            }
        )

        XCTAssertNil(store[KeychainEntryType.paykitSession.storageKey])
        XCTAssertNil(store[KeychainEntryType.pubkySecretKey.storageKey])
    }

    func testRestorePreservesPrivateIdentityWhenSharedMirrorDeletionFails() async {
        var store = makeKeychainStore(
            paykitSession: "stale-session",
            pubkySecretKey: "local-secret"
        )
        var didClearSessionAccess = false

        do {
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
                deleteBitkitSharedIdentities: {
                    throw SharedPubkyIdentityError.unavailable
                },
                forgetSessionAccess: {
                    didClearSessionAccess = true
                }
            )
            XCTFail("Expected shared mirror deletion failure")
        } catch {
            XCTAssertEqual(error as? SharedPubkyIdentityError, .unavailable)
        }

        XCTAssertFalse(didClearSessionAccess)
        XCTAssertEqual(store[KeychainEntryType.paykitSession.storageKey], "stale-session")
        XCTAssertEqual(store[KeychainEntryType.pubkySecretKey.storageKey], "local-secret")
    }

    func testRestoreSessionBackupStateForLocalSeedDerivesSecretAndClearsSession() async throws {
        var store = makeKeychainStore(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            paykitSession: "stale-session"
        )

        try await PubkyProfileManager.restoreSessionBackupState(
            PubkySessionBackupV1(kind: .localSeed, sessionSecret: nil),
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
                PubkySessionBackupV1(kind: .localSeed, sessionSecret: nil),
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
            pubkySession: PubkySessionBackupV1(kind: .externalSession, sessionSecret: "session-secret"),
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

@MainActor
private class KeyDerivationProbeProfileManager: PubkyProfileManager {
    var didDeriveKeys = false

    override func deriveKeys() async throws -> (String, String) {
        didDeriveKeys = true
        throw PubkyServiceError.authFailed("key derivation probe")
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
