@testable import Bitkit
import BreezSdkSpark
import XCTest

final class SparkConfigTests: XCTestCase {
    func testConnectsWithoutBreezDataSyncOrLightningAddressServer() {
        for network in [BreezSdkSpark.Network.mainnet, .regtest] {
            let config = SparkManager.sdkConfig(network: network, apiKey: "test-key")

            XCTAssertNil(config.realTimeSyncServerUrl, "\(network)")
            XCTAssertNil(config.lnurlDomain, "\(network)")
            XCTAssertEqual(config.apiKey, "test-key")
        }
    }

    func testChainServiceIsBitkitElectrsOnMainnetOnly() {
        XCTAssertEqual(Env.sparkChainServiceUrl(for: .bitcoin), "https://bitkit.to/electrs")
        XCTAssertNil(Env.sparkChainServiceUrl(for: .regtest))
    }
}
