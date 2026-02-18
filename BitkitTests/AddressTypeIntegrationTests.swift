import BitkitCore
import LDKNode
import XCTest

@testable import Bitkit

final class AddressTypeIntegrationTests: XCTestCase {
    let walletIndex = 0
    let lightning = LightningService.shared
    let settings = SettingsViewModel.shared

    override func setUp() async throws {
        try await super.setUp()
        Logger.test("Starting address type integration test setup", context: "AddressTypeIntegrationTests")
        try Keychain.wipeEntireKeychain()
    }

    override func tearDown() async throws {
        lightning.dumpLdkLogs()
        try Keychain.wipeEntireKeychain()
        let isRunning = await MainActor.run { lightning.status?.isRunning == true }
        if isRunning {
            try? await lightning.stop()
        }
        try? await lightning.wipeStorage(walletIndex: walletIndex)
        await MainActor.run { settings.resetToDefaults() }
        try await super.tearDown()
    }

    /// Skip if not regtest - integration tests require regtest
    private func skipIfNotRegtest() throws {
        guard Env.network == .regtest else {
            throw XCTSkip("Address type integration tests require regtest")
        }
    }

    /// Shared setup: create wallet, start lightning node, sync
    private func setupWalletAndNode() async throws {
        try skipIfNotRegtest()
        let mnemonic = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        XCTAssertFalse(mnemonic.isEmpty)
        try await lightning.setup(walletIndex: walletIndex)
        try await lightning.start()
        try await lightning.sync()
    }

    @MainActor
    func testGetBalanceForAddressType() async throws {
        try await setupWalletAndNode()

        Logger.test("Getting balance for nativeSegwit", context: "AddressTypeIntegrationTests")
        let balance = try await lightning.getBalanceForAddressType(.nativeSegwit)
        XCTAssertGreaterThanOrEqual(balance.totalSats, 0)
        Logger.test("Balance: \(balance.totalSats) sats", context: "AddressTypeIntegrationTests")
    }

    func testGetChannelFundableBalance() async throws {
        try await setupWalletAndNode()

        Logger.test("Getting channel fundable balance", context: "AddressTypeIntegrationTests")
        let (selectedType, monitoredTypes) = LightningService.addressTypeStateFromUserDefaults()
        let fundable = try await lightning.getChannelFundableBalance(selectedType: selectedType, monitoredTypes: monitoredTypes)
        XCTAssertGreaterThanOrEqual(fundable, 0)
        Logger.test("Channel fundable: \(fundable) sats", context: "AddressTypeIntegrationTests")
    }

    @MainActor
    func testUpdateAddressType() async throws {
        try await setupWalletAndNode()

        Logger.test("Updating address type to taproot", context: "AddressTypeIntegrationTests")
        let success = await settings.updateAddressType(.taproot, wallet: nil)
        XCTAssertTrue(success, "updateAddressType should succeed")

        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedAddressType"), "taproot")
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot))
        Logger.test("Address type updated successfully", context: "AddressTypeIntegrationTests")
    }

    @MainActor
    func testUpdateAddressTypeToLegacy() async throws {
        try await setupWalletAndNode()

        Logger.test("Updating address type to legacy", context: "AddressTypeIntegrationTests")
        let success = await settings.updateAddressType(.legacy, wallet: nil)
        XCTAssertTrue(success, "updateAddressType to legacy should succeed")

        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedAddressType"), "legacy")
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.legacy))
        Logger.test("Address type updated to legacy successfully", context: "AddressTypeIntegrationTests")
    }

    @MainActor
    func testSetMonitoringEnable() async throws {
        try await setupWalletAndNode()

        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()

        Logger.test("Enabling monitoring for taproot", context: "AddressTypeIntegrationTests")
        let success = await settings.setMonitoring(.taproot, enabled: true, wallet: nil)
        XCTAssertTrue(success)
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot))
    }

    @MainActor
    func testSetMonitoringDisableForEmptyTypeSucceeds() async throws {
        try await setupWalletAndNode()

        // Add taproot via setMonitoring (uses addAddressTypeToMonitor runtime API)
        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()
        let addSuccess = await settings.setMonitoring(.taproot, enabled: true, wallet: nil)
        XCTAssertTrue(addSuccess, "Adding taproot to monitoring should succeed")

        Logger.test("Disabling monitoring for empty taproot type", context: "AddressTypeIntegrationTests")
        let success = await settings.setMonitoring(.taproot, enabled: false, wallet: nil)
        XCTAssertTrue(success, "Disabling empty type should succeed when nativeSegwit remains")
        XCTAssertFalse(settings.addressTypesToMonitor.contains(.taproot))
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nativeSegwit))
    }

    @MainActor
    func testSetMonitoringDisableLastNativeWitnessFails() async throws {
        try await setupWalletAndNode()

        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()

        Logger.test("Attempting to disable last native witness type", context: "AddressTypeIntegrationTests")
        let success = await settings.setMonitoring(.nativeSegwit, enabled: false, wallet: nil)
        XCTAssertFalse(success, "Disabling last native witness type should fail")
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nativeSegwit))
    }

    @MainActor
    func testSetMonitoringDisableSelectedTypeFails() async throws {
        try await setupWalletAndNode()

        // Add taproot, then set taproot as selected; cannot disable selected type
        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()
        let addSuccess = await settings.setMonitoring(.taproot, enabled: true, wallet: nil)
        XCTAssertTrue(addSuccess)
        let updateSuccess = await settings.updateAddressType(.taproot, wallet: nil)
        XCTAssertTrue(updateSuccess, "Taproot should be selected")

        Logger.test("Attempting to disable selected type (taproot)", context: "AddressTypeIntegrationTests")
        let success = await settings.setMonitoring(.taproot, enabled: false, wallet: nil)
        XCTAssertFalse(success, "Disabling selected address type should fail")
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot))
    }

    @MainActor
    func testPruneEmptyAddressTypesAfterRestore() async throws {
        try await setupWalletAndNode()

        settings.addressTypesToMonitor = [.nativeSegwit, .taproot]
        UserDefaults.standard.synchronize()
        try await lightning.addAddressTypeToMonitor(.taproot)
        try await lightning.sync()

        Logger.test("Pruning empty address types after restore", context: "AddressTypeIntegrationTests")
        await settings.pruneEmptyAddressTypesAfterRestore()

        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nativeSegwit))
        let monitored = settings.addressTypesToMonitor
        XCTAssertLessThanOrEqual(monitored.count, 4)
        Logger.test(
            "Pruned monitored types: \(monitored.map(\.stringValue).joined(separator: ","))",
            context: "AddressTypeIntegrationTests"
        )
    }
}
