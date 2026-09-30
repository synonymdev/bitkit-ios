@testable import Bitkit
import class Paykit.PubkySessionAccess
import struct Paykit.PubkySessionBootstrapResult
import XCTest

final class PubkyProfileManagerTests: XCTestCase {
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
    func testLoadProfileDropsAResultThatPredatesAProfileWrite() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(holdsRequests: true)
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

            let adoption = Task { await manager.completeRingAdoptionForTesting(publicKey: ringKeyA) }
            await stub.waitForRequests(1)
            let load = Task { await manager.loadProfile() }
            await stub.waitForRequests(2)

            await stub.setProfile(makeProfile(publicKey: ringKeyA, name: "Written"), for: ringKeyA)
            await stub.release(request: 0)
            _ = await adoption.value
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
    func testClearingAuthenticatedStateDropsRingIdentityProfilesAndLookups() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
            await stub.setHoldsRequests(true)
            let inFlight = Task { await manager.loadRingIdentityProfiles([bareRingKeyC]) }
            await stub.waitForRequests(3)

            manager.clearAuthenticatedStateForTesting()
            await stub.setProfile(makeProfile(publicKey: ringKeyC, name: "Carol"), for: ringKeyC)
            await stub.release(request: 2)
            await inFlight.value
            XCTAssertTrue(manager.ringIdentityProfiles.isEmpty)

            await stub.setHoldsRequests(false)
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 5, "The miss is forgotten along with the found profile")
        }
    }

    @MainActor
    func testRingAdoptionReusesTheFoundRowProfileAndClearsTheRows() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyA: makeProfile(publicKey: ringKeyA, name: "Alice")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyA, bareRingKeyB])

            let adopted = await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)

            let requests = await stub.requests
            XCTAssertEqual(requests.count, 2, "Adoption reuses the row's profile instead of fetching it again")
            XCTAssertEqual(adopted?.name, "Alice")
            XCTAssertEqual(manager.profile?.name, "Alice")
            XCTAssertEqual(manager.cachedName, "Alice")
            XCTAssertEqual(manager.publicKey, ringKeyA)
            XCTAssertEqual(manager.authState, .authenticated)
            XCTAssertFalse(manager.isProfileSetupPending)
            XCTAssertTrue(manager.ringIdentityProfiles.isEmpty)
        }
    }

    @MainActor
    func testRingAdoptionAfterARowMissStillFetchesTheProfile() async {
        await withRestoredProfileDefaults {
            // A row miss can mean offline, so it never stands in for the fetch that decides profile setup.
            let stub = RemoteProfileStub()
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyB])
            await stub.setProfile(makeProfile(publicKey: ringKeyB, name: "Bob"), for: ringKeyB)

            let adopted = await manager.completeRingAdoptionForTesting(publicKey: ringKeyB)

            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyB, ringKeyB])
            XCTAssertEqual(adopted?.name, "Bob")
            XCTAssertEqual(manager.profile?.name, "Bob")
            XCTAssertFalse(manager.isProfileSetupPending)
        }
    }

    @MainActor
    func testRingAdoptionFetchesWhenTheRowProfileIsForAnotherKey() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub(profiles: [ringKeyC: makeProfile(publicKey: ringKeyB, name: "Other")])
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })
            await manager.loadRingIdentityProfiles([bareRingKeyC])

            _ = await manager.completeRingAdoptionForTesting(publicKey: ringKeyC)

            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyC, ringKeyC])
        }
    }

    @MainActor
    func testRingAdoptionWithoutARowProfileKeepsFetchAndSetupLogic() async {
        await withRestoredProfileDefaults {
            let stub = RemoteProfileStub()
            let manager = PubkyProfileManager(remoteProfileResolver: { try await stub.resolve($0) })

            let adopted = await manager.completeRingAdoptionForTesting(publicKey: ringKeyA)

            let requests = await stub.requests
            XCTAssertEqual(requests, [ringKeyA])
            XCTAssertNil(adopted)
            XCTAssertNil(manager.profile)
            XCTAssertEqual(manager.publicKey, ringKeyA)
            XCTAssertTrue(manager.isProfileSetupPending)
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
    private func withRestoredProfileDefaults(_ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let keys = ["pubky_profile_name", "pubky_profile_image_uri", "pubky_profile_owner", "pubky_profile_setup_pending"]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previousValues) {
                defaults.set(value, forKey: key)
            }
        }

        await body()
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
/// answers from the profiles set at that moment; a key with no profile fails as not found.
private actor RemoteProfileStub {
    private(set) var requests: [String] = []
    private var profiles: [String: PubkyProfile]
    private var isHolding: Bool
    private var heldRequests: [Int: CheckedContinuation<Void, Never>] = [:]
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(profiles: [String: PubkyProfile] = [:], holdsRequests: Bool = false) {
        self.profiles = profiles
        isHolding = holdsRequests
    }

    func resolve(_ key: String) async throws -> PubkyProfile {
        let index = requests.count
        requests.append(key)
        let satisfiedWaiters = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        satisfiedWaiters.forEach { $0.continuation.resume() }

        if isHolding {
            await withCheckedContinuation { heldRequests[index] = $0 }
        }
        guard let profile = profiles[key] else { throw PubkyServiceError.profileNotFound }
        return profile
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func setProfile(_ profile: PubkyProfile, for key: String) {
        profiles[key] = profile
    }

    func setHoldsRequests(_ holds: Bool) {
        isHolding = holds
    }

    func release(request index: Int) {
        heldRequests.removeValue(forKey: index)?.resume()
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
