@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    func testProductionUsesDefaultPubkyClient() {
        let config = PaykitSdkService.makePubkyClientConfig(localTestnetHost: nil)

        XCTAssertNil(config.localTestnetHost)
    }

    func testLocalE2EUsesLocalPubkyTestnet() {
        let config = PaykitSdkService.makePubkyClientConfig(localTestnetHost: "192.0.2.1")

        XCTAssertEqual(config.localTestnetHost, "192.0.2.1")
    }

    func testStoredSessionCanBeDeferredDuringSdkInitialization() {
        let error = PaykitError.Identity(code: "identity_error", context: "import Pubky session from platform provider")

        XCTAssertTrue(PaykitSdkService.shouldDeferStaleSession(error: error, hasStoredSession: true))
    }

    func testMissingSessionOrUnrelatedIdentityFailureIsNotDeferred() {
        let staleSession = PaykitError.Identity(code: "identity_error", context: "import Pubky session from platform provider")
        let unrelatedError = PaykitError.Identity(code: "identity_error", context: "local Pubky secret key does not match session public key")

        XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: staleSession, hasStoredSession: false))
        XCTAssertFalse(PaykitSdkService.shouldDeferStaleSession(error: unrelatedError, hasStoredSession: true))
    }
}
