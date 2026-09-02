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
        let error = PaykitError.Identity(code: "identity_error", context: "restore Pubky grant session from platform provider")

        XCTAssertTrue(PaykitSdkService.shouldDeferStaleSession(error: error, hasStoredSession: true))
    }

    func testMissingSessionOrUnrelatedIdentityFailureIsNotDeferred() {
        let staleSession = PaykitError.Identity(code: "identity_error", context: "restore Pubky grant session from platform provider")
        let unrelatedError = PaykitError.Identity(code: "identity_error", context: "local Pubky secret key does not match session public key")

        XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: staleSession, hasStoredSession: false))
        XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: unrelatedError, hasStoredSession: true))
    }
}
