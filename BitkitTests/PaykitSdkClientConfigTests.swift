@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    func testProductionUsesDefaultPubkyClient() {
        let config = PaykitSdkService.pubkyClientConfig(isLocalE2EBackend: false)

        XCTAssertEqual(config.environment, .production)
        XCTAssertNil(config.testnetHost)
    }

    func testLocalE2EUsesLocalPubkyTestnet() {
        let config = PaykitSdkService.pubkyClientConfig(isLocalE2EBackend: true)

        XCTAssertEqual(config.environment, .localTestnet)
        XCTAssertNil(config.testnetHost)
    }
}
