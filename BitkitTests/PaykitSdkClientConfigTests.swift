@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkClientConfigTests: XCTestCase {
    func testProductionUsesDefaultPubkyClient() {
        let config = PaykitSdkService.pubkyClientConfig(isLocalE2EBackend: false)

        XCTAssertNil(config.localTestnetHost)
    }

    func testLocalE2EUsesLocalPubkyTestnet() {
        let config = PaykitSdkService.pubkyClientConfig(isLocalE2EBackend: true)

        XCTAssertEqual(config.localTestnetHost, "localhost")
    }
}
