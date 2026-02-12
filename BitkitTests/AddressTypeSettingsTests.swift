import LDKNode
import XCTest

@testable import Bitkit

/// Tests for the multi-address-type feature in SettingsViewModel.
/// Covers address type conversion, monitoring, native witness rules, and backup/restore.
@MainActor
final class AddressTypeSettingsTests: XCTestCase {
    private let settings = SettingsViewModel.shared

    override func setUp() {
        super.setUp()
        settings.resetToDefaults()
    }

    override func tearDown() {
        settings.resetToDefaults()
        super.tearDown()
    }

    // MARK: - SettingsBackupConfig (address type keys)

    func testSettingsBackupConfigContainsAddressTypeKeys() {
        XCTAssertTrue(SettingsBackupConfig.settingsKeyTypes.keys.contains("selectedAddressType"))
        XCTAssertTrue(SettingsBackupConfig.settingsKeyTypes.keys.contains("addressTypesToMonitor"))
        XCTAssertTrue(SettingsBackupConfig.settingsKeys.contains("selectedAddressType"))
        XCTAssertTrue(SettingsBackupConfig.settingsKeys.contains("addressTypesToMonitor"))
    }

    // MARK: - addressTypeToString

    func testAddressTypeToString() {
        XCTAssertEqual(SettingsViewModel.addressTypeToString(.legacy), "legacy")
        XCTAssertEqual(SettingsViewModel.addressTypeToString(.nestedSegwit), "nestedSegwit")
        XCTAssertEqual(SettingsViewModel.addressTypeToString(.nativeSegwit), "nativeSegwit")
        XCTAssertEqual(SettingsViewModel.addressTypeToString(.taproot), "taproot")
    }

    // MARK: - stringToAddressType

    func testStringToAddressType() {
        XCTAssertEqual(SettingsViewModel.stringToAddressType("legacy"), .legacy)
        XCTAssertEqual(SettingsViewModel.stringToAddressType("nestedSegwit"), .nestedSegwit)
        XCTAssertEqual(SettingsViewModel.stringToAddressType("nativeSegwit"), .nativeSegwit)
        XCTAssertEqual(SettingsViewModel.stringToAddressType("taproot"), .taproot)
    }

    func testStringToAddressTypeInvalidReturnsNil() {
        XCTAssertNil(SettingsViewModel.stringToAddressType("invalid"))
        XCTAssertNil(SettingsViewModel.stringToAddressType(""))
        XCTAssertNil(SettingsViewModel.stringToAddressType("p2wpkh"))
    }

    // MARK: - addressTypesToMonitor round-trip

    func testAddressTypesToMonitorHandlesWhitespace() {
        settings.addressTypesToMonitor = [.nativeSegwit, .taproot]
        // Simulate comma-separated string with spaces (as could come from restore/migration)
        UserDefaults.standard.set("nativeSegwit , taproot", forKey: "addressTypesToMonitor")
        UserDefaults.standard.synchronize()
        let monitored = settings.addressTypesToMonitor
        XCTAssertTrue(monitored.contains(.nativeSegwit))
        XCTAssertTrue(monitored.contains(.taproot))
    }

    func testSelectedAddressTypeReturnsDefaultForInvalidStoredValue() {
        UserDefaults.standard.set("invalidType", forKey: "selectedAddressType")
        UserDefaults.standard.synchronize()
        XCTAssertEqual(settings.selectedAddressType, .nativeSegwit)
    }

    func testAddressTypesToMonitorRoundTrip() {
        let types: [LDKNode.AddressType] = [.nativeSegwit, .taproot]
        settings.addressTypesToMonitor = types
        XCTAssertEqual(settings.addressTypesToMonitor, types)

        let allTypes: [LDKNode.AddressType] = [.legacy, .nestedSegwit, .nativeSegwit, .taproot]
        settings.addressTypesToMonitor = allTypes
        XCTAssertEqual(settings.addressTypesToMonitor, allTypes)
    }

    // MARK: - isMonitoring

    func testIsMonitoring() {
        settings.addressTypesToMonitor = [.nativeSegwit]
        XCTAssertTrue(settings.isMonitoring(.nativeSegwit))
        XCTAssertFalse(settings.isMonitoring(.taproot))
        XCTAssertFalse(settings.isMonitoring(.legacy))

        settings.addressTypesToMonitor = [.nativeSegwit, .taproot]
        XCTAssertTrue(settings.isMonitoring(.nativeSegwit))
        XCTAssertTrue(settings.isMonitoring(.taproot))
        XCTAssertFalse(settings.isMonitoring(.legacy))
    }

    // MARK: - ensureMonitoring

    func testEnsureMonitoringAddsType() {
        settings.addressTypesToMonitor = [.nativeSegwit]
        settings.ensureMonitoring(.taproot)
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot))
        XCTAssertEqual(settings.addressTypesToMonitor.count, 2)
    }

    func testEnsureMonitoringNoOpWhenAlreadyPresent() {
        settings.addressTypesToMonitor = [.nativeSegwit, .taproot]
        settings.ensureMonitoring(.taproot)
        XCTAssertEqual(settings.addressTypesToMonitor.count, 2)
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot))
    }

    // MARK: - monitorAllAddressTypes

    func testMonitorAllAddressTypes() {
        settings.addressTypesToMonitor = [.nativeSegwit]
        settings.monitorAllAddressTypes()
        XCTAssertEqual(settings.addressTypesToMonitor.count, 4)
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.legacy))
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nestedSegwit))
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nativeSegwit))
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot))
    }

    // MARK: - isLastRequiredNativeWitnessWallet

    func testIsLastRequiredNativeWitnessWalletWhenOnlyNativeSegwit() {
        settings.addressTypesToMonitor = [.nativeSegwit]
        XCTAssertTrue(settings.isLastRequiredNativeWitnessWallet(.nativeSegwit))
    }

    func testIsLastRequiredNativeWitnessWalletWhenOnlyTaproot() {
        settings.addressTypesToMonitor = [.taproot]
        XCTAssertTrue(settings.isLastRequiredNativeWitnessWallet(.taproot))
    }

    func testIsLastRequiredNativeWitnessWalletFalseForLegacy() {
        settings.addressTypesToMonitor = [.legacy]
        XCTAssertFalse(settings.isLastRequiredNativeWitnessWallet(.legacy))
    }

    func testIsLastRequiredNativeWitnessWalletFalseForNestedSegwit() {
        settings.addressTypesToMonitor = [.nestedSegwit]
        XCTAssertFalse(settings.isLastRequiredNativeWitnessWallet(.nestedSegwit))
    }

    func testIsLastRequiredNativeWitnessWalletFalseWhenOtherNativeWitnessExists() {
        settings.addressTypesToMonitor = [.nativeSegwit, .taproot]
        XCTAssertFalse(settings.isLastRequiredNativeWitnessWallet(.nativeSegwit))
        XCTAssertFalse(settings.isLastRequiredNativeWitnessWallet(.taproot))
    }

    // MARK: - resetToDefaults

    func testResetToDefaultsSetsAddressTypes() {
        settings.addressTypesToMonitor = [.legacy, .taproot]
        settings.selectedAddressType = .taproot

        settings.resetToDefaults()

        XCTAssertEqual(settings.selectedAddressType, .nativeSegwit)
        XCTAssertEqual(settings.addressTypesToMonitor, [.nativeSegwit])
    }

    // MARK: - Backup/Restore

    func testGetSettingsDictionaryIncludesAddressTypes() {
        settings.selectedAddressType = .taproot
        settings.addressTypesToMonitor = [.nativeSegwit, .taproot]
        UserDefaults.standard.synchronize()

        let dict = settings.getSettingsDictionary()

        XCTAssertEqual(dict["selectedAddressType"] as? String, "taproot")
        XCTAssertEqual(dict["addressTypesToMonitor"] as? String, "nativeSegwit,taproot")
    }

    func testRestoreSettingsDictionaryAddressTypes() {
        let dict: [String: Any] = [
            "selectedAddressType": "taproot",
            "addressTypesToMonitor": "nativeSegwit,taproot",
        ]

        settings.restoreSettingsDictionary(dict)

        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedAddressType"), "taproot")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "addressTypesToMonitor"), "nativeSegwit,taproot")
    }

    func testRestoreSettingsDictionaryFiltersInvalidAddressTypes() {
        // Restore writes raw string; parseAddressTypesString filters invalid when reading
        let dict: [String: Any] = [
            "addressTypesToMonitor": "nativeSegwit,invalid,taproot",
        ]
        settings.restoreSettingsDictionary(dict)

        let raw = UserDefaults.standard.string(forKey: "addressTypesToMonitor")
        XCTAssertEqual(raw, "nativeSegwit,invalid,taproot", "Restore should write raw string")
        let monitored = SettingsViewModel.parseAddressTypesString(raw ?? "")
        XCTAssertEqual(monitored, [.nativeSegwit, .taproot], "Invalid types should be filtered when parsing")
    }
}
