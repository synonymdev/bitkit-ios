@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class NetworkValidationHelperTests: XCTestCase {
    // MARK: - convertNetwork Tests

    func testConvertNetwork_Bitcoin() {
        XCTAssertEqual(NetworkValidationHelper.convertNetwork(.bitcoin), .bitcoin)
    }

    func testConvertNetwork_Testnet() {
        XCTAssertEqual(NetworkValidationHelper.convertNetwork(.testnet), .testnet)
    }

    func testConvertNetwork_Signet() {
        XCTAssertEqual(NetworkValidationHelper.convertNetwork(.signet), .signet)
    }

    func testConvertNetwork_Regtest() {
        XCTAssertEqual(NetworkValidationHelper.convertNetwork(.regtest), .regtest)
    }

    // MARK: - convertNetworkType Tests

    func testConvertNetworkType_Bitcoin() {
        XCTAssertEqual(NetworkValidationHelper.convertNetworkType(.bitcoin), .bitcoin)
    }

    func testConvertNetworkType_Testnet() {
        XCTAssertEqual(NetworkValidationHelper.convertNetworkType(.testnet), .testnet)
    }

    func testConvertNetworkType_Signet() {
        XCTAssertEqual(NetworkValidationHelper.convertNetworkType(.signet), .signet)
    }

    func testConvertNetworkType_Regtest() {
        XCTAssertEqual(NetworkValidationHelper.convertNetworkType(.regtest), .regtest)
    }

    // MARK: - isNetworkMismatch Tests

    func testIsNetworkMismatch_SameNetwork() {
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .bitcoin, currentNetwork: .bitcoin))
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .testnet, currentNetwork: .testnet))
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .regtest, currentNetwork: .regtest))
    }

    func testIsNetworkMismatch_DifferentNetwork() {
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .bitcoin, currentNetwork: .testnet))
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .bitcoin, currentNetwork: .regtest))
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .testnet, currentNetwork: .bitcoin))
    }

    func testIsNetworkMismatch_RegtestAcceptsTestnetPrefixes() {
        // Regtest should accept testnet prefixes (m, n, 2, tb1)
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .testnet, currentNetwork: .regtest))
    }

    func testIsNetworkMismatch_TestnetRejectsRegtestAddresses() {
        // Testnet should NOT accept regtest-specific addresses (bcrt1)
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: .regtest, currentNetwork: .testnet))
    }

    func testIsNetworkMismatch_NilAddressNetwork() {
        // When address network is nil (unrecognized format), no mismatch
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: nil, currentNetwork: .bitcoin))
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: nil, currentNetwork: .regtest))
    }

    // MARK: - Integration Tests (combining validateBitcoinAddress with isNetworkMismatch)

    func testMainnetAddressOnRegtest_ShouldMismatch() {
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let addressNetwork = (try? validateBitcoinAddress(address)).map { NetworkValidationHelper.convertNetwork($0.network) }
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .regtest))
    }

    func testTestnetAddressOnRegtest_ShouldNotMismatch() {
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let addressNetwork = (try? validateBitcoinAddress(address)).map { NetworkValidationHelper.convertNetwork($0.network) }
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .regtest))
    }

    func testRegtestAddressOnMainnet_ShouldMismatch() {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let addressNetwork = (try? validateBitcoinAddress(address)).map { NetworkValidationHelper.convertNetwork($0.network) }
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .bitcoin))
    }

    func testLegacyTestnetAddressOnRegtest_ShouldNotMismatch() {
        let address = "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn" // m-prefix testnet
        let addressNetwork = (try? validateBitcoinAddress(address)).map { NetworkValidationHelper.convertNetwork($0.network) }
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .regtest))
    }
}
