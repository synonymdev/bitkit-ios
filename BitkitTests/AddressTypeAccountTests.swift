@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

/// Covers the hardware-wallet additions to `LDKNode.AddressType` (`AddressScriptType`):
/// the bitkit-core `accountType` mapping and the account-level derivation path.
final class AddressTypeAccountTests: XCTestCase {
    func testAccountTypeMapping() {
        XCTAssertEqual(AddressScriptType.legacy.accountType, .legacy)
        XCTAssertEqual(AddressScriptType.nestedSegwit.accountType, .wrappedSegwit)
        XCTAssertEqual(AddressScriptType.nativeSegwit.accountType, .nativeSegwit)
        XCTAssertEqual(AddressScriptType.taproot.accountType, .taproot)
    }

    func testAccountDerivationPathMainnet() {
        XCTAssertEqual(AddressScriptType.legacy.accountDerivationPath(coinType: "0"), "m/44'/0'/0'")
        XCTAssertEqual(AddressScriptType.nestedSegwit.accountDerivationPath(coinType: "0"), "m/49'/0'/0'")
        XCTAssertEqual(AddressScriptType.nativeSegwit.accountDerivationPath(coinType: "0"), "m/84'/0'/0'")
        XCTAssertEqual(AddressScriptType.taproot.accountDerivationPath(coinType: "0"), "m/86'/0'/0'")
    }

    func testAccountDerivationPathTestNetworks() {
        XCTAssertEqual(AddressScriptType.nativeSegwit.accountDerivationPath(coinType: "1"), "m/84'/1'/0'")
        XCTAssertEqual(AddressScriptType.taproot.accountDerivationPath(coinType: "1"), "m/86'/1'/0'")
    }

    /// The account path is the chain-level `derivationPath` without the trailing chain/index.
    func testAccountPathIsChainPathWithoutSuffix() {
        for type in AddressScriptType.allAddressTypes {
            XCTAssertEqual(type.derivationPath(coinType: "0"), type.accountDerivationPath(coinType: "0") + "/0")
        }
    }
}
