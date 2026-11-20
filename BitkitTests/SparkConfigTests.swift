@testable import Bitkit
import BreezSdkSpark
import XCTest

final class SparkConfigTests: XCTestCase {
    func testConnectsWithoutBreezDataSyncOrLightningAddressServer() {
        for network in [BreezSdkSpark.Network.mainnet, .regtest] {
            let config = SparkManager.sdkConfig(network: network, apiKey: "test-key", isExiting: false)

            XCTAssertNil(config.realTimeSyncServerUrl, "\(network)")
            XCTAssertNil(config.lnurlDomain, "\(network)")
            XCTAssertFalse(config.useDefaultExternalInputParsers, "Parsing input must not look it up with a third party")
            XCTAssertEqual(config.apiKey, "test-key")
            XCTAssertTrue(config.leafOptimizationConfig.autoEnabled)
        }
        XCTAssertFalse(SparkManager.sdkConfig(network: .regtest, apiKey: nil, isExiting: true).leafOptimizationConfig.autoEnabled)
    }

    func testInvoicesCarryNoSparkAddressOnAnyNetworkSoEveryPaymentIsALightningPaymentBitkitRecords() {
        for network in [BreezSdkSpark.Network.mainnet, .regtest] {
            XCTAssertFalse(SparkManager.sdkConfig(network: network, apiKey: nil, isExiting: false).preferSparkOverLightning, "\(network)")
        }
    }

    func testChainServiceIsBitkitElectrsOnMainnetOnly() {
        XCTAssertEqual(Env.sparkChainServiceUrl(for: .bitcoin), "https://bitkit.to/electrs")
        XCTAssertNil(Env.sparkChainServiceUrl(for: .regtest, localRegtestURL: nil, configuredURL: nil))
    }

    func testLocalChainServiceTakesPrecedenceOnlyOnRegtest() {
        let local = "http://127.0.0.1:23090/api"
        let configured = "https://example.com/electrs"
        XCTAssertEqual(Env.sparkChainServiceUrl(for: .regtest, localRegtestURL: local, configuredURL: configured), local)
        XCTAssertEqual(Env.sparkChainServiceUrl(for: .regtest, localRegtestURL: nil, configuredURL: configured), configured)
        XCTAssertEqual(Env.sparkChainServiceUrl(for: .bitcoin, localRegtestURL: local, configuredURL: configured), "https://bitkit.to/electrs")
        XCTAssertEqual(Env.sparkChainServiceUrl(for: .signet, localRegtestURL: local, configuredURL: configured), configured)
    }
}
