@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    private let externalAuthURL =
        "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
        "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
        "&cid=paykit.test&cpk=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"

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
        for context in [
            "restore Pubky grant session from platform provider",
            "Pubky session must be grant-backed",
            "Pubky grant client ID `old.bitkit.to` did not match `staging.bitkit.to`",
        ] {
            let error = PaykitError.Identity(code: "identity_error", context: context)
            XCTAssertTrue(PaykitSdkService.shouldDeferStaleSession(error: error, hasStoredSession: true))
            XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: error, hasStoredSession: false))
        }
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
