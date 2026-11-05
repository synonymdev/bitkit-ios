@testable import Bitkit
import BreezSdkSpark
import XCTest

final class SparkConfigTests: XCTestCase {
    func testConnectsWithoutBreezDataSyncOrLightningAddressServer() {
        for network in [BreezSdkSpark.Network.mainnet, .regtest] {
            let config = SparkManager.sdkConfig(network: network, apiKey: "test-key", isExiting: false)

            XCTAssertNil(config.realTimeSyncServerUrl, "\(network)")
            XCTAssertNil(config.lnurlDomain, "\(network)")
            XCTAssertEqual(config.apiKey, "test-key")
            XCTAssertTrue(config.leafOptimizationConfig.autoEnabled)
        }
        XCTAssertFalse(SparkManager.sdkConfig(network: .regtest, apiKey: nil, isExiting: true).leafOptimizationConfig.autoEnabled)
    }
}
