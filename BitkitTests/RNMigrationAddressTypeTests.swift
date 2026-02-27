@testable import Bitkit
import XCTest

/// Tests for RN (React Native) migration of address type settings from MMKV data.
/// Covers extractRNAddressTypeSettings and applyRNAddressTypeSettings in MigrationsService.
final class RNMigrationAddressTypeTests: XCTestCase {
    private let migrations = MigrationsService.shared

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedAddressType")
        UserDefaults.standard.removeObject(forKey: "addressTypesToMonitor")
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func makePersistRoot(
        addressTypePerNetwork: [String: String]? = nil,
        addressTypesToMonitor: [String]? = nil
    ) -> String {
        var walletDict: [String: Any] = [:]
        if let addressType = addressTypePerNetwork {
            walletDict["wallets"] = ["wallet0": ["addressType": addressType]]
        }
        if let monitored = addressTypesToMonitor {
            walletDict["addressTypesToMonitor"] = monitored
        }
        let walletData = try! JSONSerialization.data(withJSONObject: walletDict)
        let walletJson = String(data: walletData, encoding: .utf8)!
        let root: [String: Any] = ["wallet": walletJson]
        let rootData = try! JSONSerialization.data(withJSONObject: root)
        return String(data: rootData, encoding: .utf8)!
    }

    private func makeMmkvData(
        addressTypePerNetwork: [String: String]? = nil,
        addressTypesToMonitor: [String]? = nil
    ) -> [String: String] {
        ["persist:root": makePersistRoot(addressTypePerNetwork: addressTypePerNetwork, addressTypesToMonitor: addressTypesToMonitor)]
    }

    // MARK: - Extract Tests

    func testExtractRNAddressTypeSettingsFromMmkvData() {
        let networkKey = "bitcoinRegtest"
        let mmkvData = makeMmkvData(
            addressTypePerNetwork: [networkKey: "p2wpkh"],
            addressTypesToMonitor: ["p2pkh", "p2wpkh"]
        )
        let result = migrations.extractRNAddressTypeSettings(from: mmkvData)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.selectedAddressType, "nativeSegwit")
        XCTAssertEqual(result?.addressTypesToMonitor, ["legacy", "nativeSegwit"])
    }

    func testExtractRNAddressTypeSettingsMapping() {
        let networkKey = "bitcoinRegtest"
        let mappings: [(String, String)] = [
            ("p2pkh", "legacy"),
            ("p2sh", "nestedSegwit"),
            ("p2wpkh", "nativeSegwit"),
            ("p2tr", "taproot"),
        ]
        for (rnValue, iosValue) in mappings {
            let mmkvData = makeMmkvData(
                addressTypePerNetwork: [networkKey: rnValue],
                addressTypesToMonitor: [rnValue]
            )
            let result = migrations.extractRNAddressTypeSettings(from: mmkvData)
            XCTAssertNotNil(result, "Failed for RN value: \(rnValue)")
            XCTAssertEqual(result?.selectedAddressType, iosValue, "RN \(rnValue) should map to \(iosValue)")
            XCTAssertEqual(result?.addressTypesToMonitor, [iosValue])
        }
    }

    func testExtractRNAddressTypeSettingsReturnsNilWhenNoWalletData() {
        XCTAssertNil(migrations.extractRNAddressTypeSettings(from: [:]))
        XCTAssertNil(migrations.extractRNAddressTypeSettings(from: ["otherKey": "value"]))
        XCTAssertNil(migrations.extractRNAddressTypeSettings(from: makeMmkvData(addressTypePerNetwork: nil, addressTypesToMonitor: nil)))
    }

    func testExtractRNAddressTypeSettingsFiltersUnknownRNValues() {
        let networkKey = "bitcoinRegtest"
        let mmkvData = makeMmkvData(
            addressTypePerNetwork: [networkKey: "p2wpkh"],
            addressTypesToMonitor: ["p2wpkh", "unknown", "p2tr"]
        )
        let result = migrations.extractRNAddressTypeSettings(from: mmkvData)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.selectedAddressType, "nativeSegwit")
        // Unknown values filtered out; p2wpkh -> nativeSegwit, p2tr -> taproot
        XCTAssertEqual(Set(result?.addressTypesToMonitor ?? []), ["nativeSegwit", "taproot"])
    }

    // MARK: - Apply Tests

    func testApplyRNAddressTypeSettingsSelectedType() {
        migrations.applyRNAddressTypeSettings(selectedAddressType: "taproot", addressTypesToMonitor: nil)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedAddressType"), "taproot")
    }

    func testApplyRNAddressTypeSettingsMonitoredTypes() {
        migrations.applyRNAddressTypeSettings(selectedAddressType: nil, addressTypesToMonitor: ["nativeSegwit", "taproot"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "addressTypesToMonitor"), "nativeSegwit,taproot")
    }

    func testApplyRNAddressTypeSettingsNativeWitnessAdded() {
        migrations.applyRNAddressTypeSettings(selectedAddressType: nil, addressTypesToMonitor: ["legacy"])
        let monitored = UserDefaults.standard.string(forKey: "addressTypesToMonitor")
        XCTAssertNotNil(monitored)
        XCTAssertTrue(monitored!.contains("nativeSegwit"))
        XCTAssertTrue(monitored!.contains("legacy"))
    }

    func testApplyRNAddressTypeSettingsNestedSegwitOnlyAddsNativeSegwit() {
        migrations.applyRNAddressTypeSettings(selectedAddressType: nil, addressTypesToMonitor: ["nestedSegwit"])
        let monitored = UserDefaults.standard.string(forKey: "addressTypesToMonitor")
        XCTAssertNotNil(monitored)
        XCTAssertTrue(monitored!.contains("nativeSegwit"))
        XCTAssertTrue(monitored!.contains("nestedSegwit"))
    }

    func testApplyRNAddressTypeSettingsWithNativeWitnessDoesNotDuplicate() {
        migrations.applyRNAddressTypeSettings(selectedAddressType: nil, addressTypesToMonitor: ["nativeSegwit", "legacy"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "addressTypesToMonitor"), "nativeSegwit,legacy")
    }
}
