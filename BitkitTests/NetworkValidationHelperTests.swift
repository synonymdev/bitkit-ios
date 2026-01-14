@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class NetworkValidationHelperTests: XCTestCase {
    // MARK: - getAddressNetwork Tests

    // Mainnet addresses
    func testGetAddressNetwork_MainnetBech32() {
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .bitcoin)
    }

    func testGetAddressNetwork_MainnetBech32Uppercase() {
        let address = "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .bitcoin)
    }

    func testGetAddressNetwork_MainnetP2PKH() {
        let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .bitcoin)
    }

    func testGetAddressNetwork_MainnetP2SH() {
        let address = "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .bitcoin)
    }

    // Testnet addresses
    func testGetAddressNetwork_TestnetBech32() {
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .testnet)
    }

    func testGetAddressNetwork_TestnetP2PKH_m() {
        let address = "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .testnet)
    }

    func testGetAddressNetwork_TestnetP2PKH_n() {
        let address = "n3ZddxzLvAY9o7184TB4c6FJasAybsw4HZ"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .testnet)
    }

    func testGetAddressNetwork_TestnetP2SH() {
        let address = "2MzQwSSnBHWHqSAqtTVQ6v47XtaisrJa1Vc"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .testnet)
    }

    // Regtest addresses
    func testGetAddressNetwork_RegtestBech32() {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        XCTAssertEqual(NetworkValidationHelper.getAddressNetwork(address), .regtest)
    }

    // Edge cases
    func testGetAddressNetwork_EmptyString() {
        XCTAssertNil(NetworkValidationHelper.getAddressNetwork(""))
    }

    func testGetAddressNetwork_InvalidAddress() {
        XCTAssertNil(NetworkValidationHelper.getAddressNetwork("invalid"))
    }

    func testGetAddressNetwork_RandomText() {
        XCTAssertNil(NetworkValidationHelper.getAddressNetwork("test123"))
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

    // MARK: - Integration Tests (combining methods)

    func testMainnetAddressOnRegtest_ShouldMismatch() {
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let addressNetwork = NetworkValidationHelper.getAddressNetwork(address)
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .regtest))
    }

    func testTestnetAddressOnRegtest_ShouldNotMismatch() {
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let addressNetwork = NetworkValidationHelper.getAddressNetwork(address)
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .regtest))
    }

    func testRegtestAddressOnMainnet_ShouldMismatch() {
        let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"
        let addressNetwork = NetworkValidationHelper.getAddressNetwork(address)
        XCTAssertTrue(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .bitcoin))
    }

    func testLegacyTestnetAddressOnRegtest_ShouldNotMismatch() {
        let address = "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn" // m-prefix testnet
        let addressNetwork = NetworkValidationHelper.getAddressNetwork(address)
        XCTAssertFalse(NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: .regtest))
    }
}
