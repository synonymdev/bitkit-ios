@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class JadeDeviceIdentityTests: XCTestCase {
    // MARK: - Device id and model

    func testTheDeviceIdCarriesTheEfuseMacInTheJadeNamespace() {
        XCTAssertEqual(JadeDeviceIdentity.deviceId(efuseMac: "246F288F6B64"), "jade:bluetooth:246F288F6B64")
    }

    func testThereIsNoDeviceIdWithoutAnEfuseMac() {
        XCTAssertNil(JadeDeviceIdentity.deviceId(efuseMac: nil))
        XCTAssertNil(JadeDeviceIdentity.deviceId(efuseMac: ""))
        XCTAssertNil(JadeDeviceIdentity.deviceId(efuseMac: "  "))
    }

    func testAV2BoardIsAJadePlus() {
        XCTAssertEqual(JadeDeviceIdentity.model(boardType: "JADE_V2"), "Jade Plus")
        XCTAssertEqual(JadeDeviceIdentity.model(boardType: "jade_v2"), "Jade Plus")
    }

    func testEveryOtherBoardIsTheOriginalJade() {
        XCTAssertEqual(JadeDeviceIdentity.model(boardType: "JADE_V1_1"), "Jade")
        XCTAssertEqual(JadeDeviceIdentity.model(boardType: nil), "Jade")
    }

    // MARK: - Advertised name

    func testAJadeIsRecognisedByTheSuffixOfItsAdvertisedName() {
        XCTAssertTrue(JadeDeviceIdentity.advertises("Jade 8F6B64", jadeDeviceId: "246F288F6B64"))
        XCTAssertTrue(JadeDeviceIdentity.advertises("jade 8f6b64", jadeDeviceId: "246F288F6B64"))
    }

    func testAnotherNameOrNoNameIsNotTheJade() {
        XCTAssertFalse(JadeDeviceIdentity.advertises("Jade AAAAAA", jadeDeviceId: "246F288F6B64"))
        XCTAssertFalse(JadeDeviceIdentity.advertises(nil, jadeDeviceId: "246F288F6B64"))
    }

    func testAnIdTooShortOrBlankNeverMatches() {
        XCTAssertFalse(JadeDeviceIdentity.advertises("Jade 8F6B", jadeDeviceId: "8F6B"))
        XCTAssertFalse(JadeDeviceIdentity.advertises("Jade", jadeDeviceId: nil))
        XCTAssertFalse(JadeDeviceIdentity.advertises("Jade       ", jadeDeviceId: "      "))
    }

    func testAPairedEntryIsTheSameJadeUnderItsPathOrItsName() {
        let entry = HwKnownDevice(
            id: "jade:bluetooth:246F288F6B64",
            name: "Jade 8F6B64",
            path: "ble:old",
            transportType: "bluetooth",
            lastConnectedAt: Date(),
            vendor: .blockstream,
            jadeDeviceId: "246F288F6B64"
        )

        XCTAssertTrue(entry.isSameJade(as: JadeDeviceInfo(path: "ble:old", transport: .bluetooth, name: nil, serialNumber: nil)))
        XCTAssertTrue(entry.isSameJade(as: JadeDeviceInfo(path: "ble:new", transport: .bluetooth, name: "Jade 8F6B64", serialNumber: nil)))
        XCTAssertFalse(entry.isSameJade(as: JadeDeviceInfo(path: "ble:new", transport: .bluetooth, name: "Jade AAAAAA", serialNumber: nil)))
        XCTAssertTrue(entry.matches(deviceId: "ble:old"))
        XCTAssertTrue(entry.matches(deviceId: "jade:bluetooth:246F288F6B64"))
        XCTAssertFalse(entry.matches(deviceId: "ble:new"))
    }

    // MARK: - Session state

    func testOnlyAReadyOrTemporaryJadeIsUnlocked() {
        XCTAssertTrue(JadeState.ready.isUnlocked)
        XCTAssertTrue(JadeState.temp.isUnlocked)
        for state in [JadeState.locked, .uninit, .unsaved, .unknown] {
            XCTAssertFalse(state.isUnlocked, "\(state)")
        }
    }

    func testAConnectedJadeReportsItsLockAndModel() {
        let session = ConnectedJadeDevice(
            id: "jade:bluetooth:246F288F6B64",
            path: "ble:path",
            versionInfo: JadeFixtures.version(.locked),
            walletId: nil
        )

        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.model, "Jade")
        XCTAssertTrue(session.matches("ble:path"))
        XCTAssertTrue(session.matches("jade:bluetooth:246F288F6B64"))
        XCTAssertFalse(session.matches("ble:other"))
    }

    // MARK: - Network and address variants

    func testNetworksMapToTheirJadeNetwork() throws {
        XCTAssertEqual(try LDKNode.Network.bitcoin.toJadeNetwork(), .mainnet)
        XCTAssertEqual(try LDKNode.Network.testnet.toJadeNetwork(), .testnet)
        XCTAssertEqual(try LDKNode.Network.regtest.toJadeNetwork(), .regtest)
    }

    func testSignetIsNotSupportedByJade() {
        XCTAssertThrowsError(try LDKNode.Network.signet.toJadeNetwork()) { error in
            XCTAssertEqual((error as? Bitkit.AppError)?.message, "Signet is not supported by Jade")
        }
    }

    func testEveryAddressTypeRoundTripsThroughItsJadeVariant() {
        for addressType in AddressScriptType.allAddressTypes {
            XCTAssertEqual(AddressScriptType(jadeVariant: addressType.jadeVariant), addressType, "\(addressType)")
        }
    }

    func testAddressVariantsMatchCore() {
        XCTAssertEqual(AddressScriptType.nativeSegwit.jadeVariant, .wpkh)
        for addressType in AddressScriptType.allAddressTypes {
            XCTAssertEqual(addressType.jadeVariant, jadeAccountTypeToVariant(accountType: addressType.accountType), "\(addressType)")
        }
    }
}
