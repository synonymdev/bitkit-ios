@testable import Bitkit
import LDKNode
import XCTest

/// Unit tests for LDKNode.AddressType derivation path and storage mapping (LDKNode+AddressType extension).
final class AddressTypeDerivationTests: XCTestCase {
    // MARK: - fromStorage

    func testFromStorage_ValidStrings_ReturnsCorrectType() {
        XCTAssertEqual(LDKNode.AddressType.fromStorage("legacy"), .legacy)
        XCTAssertEqual(LDKNode.AddressType.fromStorage("nestedSegwit"), .nestedSegwit)
        XCTAssertEqual(LDKNode.AddressType.fromStorage("nativeSegwit"), .nativeSegwit)
        XCTAssertEqual(LDKNode.AddressType.fromStorage("taproot"), .taproot)
    }

    func testFromStorage_NilOrInvalid_ReturnsNativeSegwit() {
        XCTAssertEqual(LDKNode.AddressType.fromStorage(nil), .nativeSegwit)
        XCTAssertEqual(LDKNode.AddressType.fromStorage(""), .nativeSegwit)
        XCTAssertEqual(LDKNode.AddressType.fromStorage("invalid"), .nativeSegwit)
        XCTAssertEqual(LDKNode.AddressType.fromStorage("p2wpkh"), .nativeSegwit)
    }

    // MARK: - derivationPath(coinType:)

    func testDerivationPath_Mainnet_ReturnsBIPPaths() {
        XCTAssertEqual(LDKNode.AddressType.legacy.derivationPath(coinType: "0"), "m/44'/0'/0'/0")
        XCTAssertEqual(LDKNode.AddressType.nestedSegwit.derivationPath(coinType: "0"), "m/49'/0'/0'/0")
        XCTAssertEqual(LDKNode.AddressType.nativeSegwit.derivationPath(coinType: "0"), "m/84'/0'/0'/0")
        XCTAssertEqual(LDKNode.AddressType.taproot.derivationPath(coinType: "0"), "m/86'/0'/0'/0")
    }

    func testDerivationPath_Testnet_ReturnsBIPPathsWithCoinType1() {
        XCTAssertEqual(LDKNode.AddressType.legacy.derivationPath(coinType: "1"), "m/44'/1'/0'/0")
        XCTAssertEqual(LDKNode.AddressType.nestedSegwit.derivationPath(coinType: "1"), "m/49'/1'/0'/0")
        XCTAssertEqual(LDKNode.AddressType.nativeSegwit.derivationPath(coinType: "1"), "m/84'/1'/0'/0")
        XCTAssertEqual(LDKNode.AddressType.taproot.derivationPath(coinType: "1"), "m/86'/1'/0'/0")
    }

    func testDerivationPath_StringValueRoundTrip() {
        for type in LDKNode.AddressType.allAddressTypes {
            let parsed = LDKNode.AddressType.fromStorage(type.stringValue)
            XCTAssertEqual(parsed, type, "fromStorage(\(type.stringValue)) should round-trip")
        }
    }

    // MARK: - parseCommaSeparated(_:)

    func testParseCommaSeparated_ValidTypes() {
        let result = LDKNode.AddressType.parseCommaSeparated("nativeSegwit,taproot")
        XCTAssertEqual(result, [.nativeSegwit, .taproot])
    }

    func testParseCommaSeparated_HandlesWhitespace() {
        let result = LDKNode.AddressType.parseCommaSeparated("nativeSegwit , taproot ")
        XCTAssertEqual(result, [.nativeSegwit, .taproot])
    }

    func testParseCommaSeparated_FiltersInvalid() {
        let result = LDKNode.AddressType.parseCommaSeparated("nativeSegwit,invalid,taproot")
        XCTAssertEqual(result, [.nativeSegwit, .taproot])
    }

    // MARK: - matchesAddressFormat(_:network:)

    func testMatchesAddressFormat_Mainnet_AcceptsCorrectPrefixes() {
        let network: LDKNode.Network = .bitcoin
        XCTAssertTrue(LDKNode.AddressType.legacy.matchesAddressFormat("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", network: network))
        XCTAssertTrue(LDKNode.AddressType.nestedSegwit.matchesAddressFormat("3J98t1WpEZ73CNmYviecrnyiWrnqRhWNLy", network: network))
        XCTAssertTrue(LDKNode.AddressType.nativeSegwit.matchesAddressFormat("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", network: network))
        XCTAssertTrue(LDKNode.AddressType.taproot.matchesAddressFormat(
            "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr",
            network: network
        ))
    }

    func testMatchesAddressFormat_NonMainnet_AcceptsTestnetRegtestPrefixes() {
        let network: LDKNode.Network = .regtest
        XCTAssertTrue(LDKNode.AddressType.legacy.matchesAddressFormat("n1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", network: network))
        XCTAssertTrue(LDKNode.AddressType.legacy.matchesAddressFormat("mipcBbFg9gMi2EuSb4p2xS1jG7xJsK9Np2", network: network))
        XCTAssertTrue(LDKNode.AddressType.nestedSegwit.matchesAddressFormat("2N1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", network: network))
        XCTAssertTrue(LDKNode.AddressType.nativeSegwit.matchesAddressFormat("bcrt1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", network: network))
        XCTAssertTrue(LDKNode.AddressType.taproot.matchesAddressFormat(
            "bcrt1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqejdw4v",
            network: network
        ))
    }

    func testMatchesAddressFormat_RejectsWrongType() {
        let network: LDKNode.Network = .bitcoin
        XCTAssertFalse(LDKNode.AddressType.legacy.matchesAddressFormat("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", network: network))
        XCTAssertFalse(LDKNode.AddressType.nativeSegwit.matchesAddressFormat("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", network: network))
        XCTAssertFalse(LDKNode.AddressType.taproot.matchesAddressFormat("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", network: network))
    }

    func testMatchesAddressFormat_RejectsEmpty() {
        XCTAssertFalse(LDKNode.AddressType.nativeSegwit.matchesAddressFormat("", network: .bitcoin))
        XCTAssertFalse(LDKNode.AddressType.legacy.matchesAddressFormat("  ", network: .regtest))
    }
}
