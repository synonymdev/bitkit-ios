@testable import Bitkit
import BitkitCore
import XCTest

final class HwAddressTypeTests: XCTestCase {
    func testAllCasesOrderMatchesAndroid() {
        XCTAssertEqual(HwAddressType.allCases, [.legacy, .nestedSegwit, .nativeSegwit, .taproot])
    }

    func testSettingsStrings() {
        XCTAssertEqual(HwAddressType.legacy.settingsString, "legacy")
        XCTAssertEqual(HwAddressType.nestedSegwit.settingsString, "nestedSegwit")
        XCTAssertEqual(HwAddressType.nativeSegwit.settingsString, "nativeSegwit")
        XCTAssertEqual(HwAddressType.taproot.settingsString, "taproot")
    }

    func testAccountTypeMapping() {
        XCTAssertEqual(HwAddressType.legacy.accountType, .legacy)
        XCTAssertEqual(HwAddressType.nestedSegwit.accountType, .wrappedSegwit)
        XCTAssertEqual(HwAddressType.nativeSegwit.accountType, .nativeSegwit)
        XCTAssertEqual(HwAddressType.taproot.accountType, .taproot)
    }

    func testAccountDerivationPathMainnet() {
        XCTAssertEqual(HwAddressType.legacy.accountDerivationPath(network: .bitcoin), "m/44'/0'/0'")
        XCTAssertEqual(HwAddressType.nestedSegwit.accountDerivationPath(network: .bitcoin), "m/49'/0'/0'")
        XCTAssertEqual(HwAddressType.nativeSegwit.accountDerivationPath(network: .bitcoin), "m/84'/0'/0'")
        XCTAssertEqual(HwAddressType.taproot.accountDerivationPath(network: .bitcoin), "m/86'/0'/0'")
    }

    func testAccountDerivationPathUsesCoinType1ForTestNetworks() {
        XCTAssertEqual(HwAddressType.nativeSegwit.accountDerivationPath(network: .regtest), "m/84'/1'/0'")
        XCTAssertEqual(HwAddressType.taproot.accountDerivationPath(network: .testnet), "m/86'/1'/0'")
    }

    func testInitFromSettingsStringRoundTrips() {
        for type in HwAddressType.allCases {
            XCTAssertEqual(HwAddressType(settingsString: type.settingsString), type)
        }
        XCTAssertNil(HwAddressType(settingsString: "p2wpkh"))
        XCTAssertNil(HwAddressType(settingsString: ""))
    }
}
