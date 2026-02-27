import BitkitCore
import LDKNode
import XCTest

@testable import Bitkit

final class AddressTypeIntegrationTests: XCTestCase {
    let walletIndex = 0
    let settings = SettingsViewModel.shared

    override func setUp() async throws {
        try await super.setUp()
        Logger.test("Starting address type integration test setup", context: "AddressTypeIntegrationTests")
        try Keychain.wipeEntireKeychain()
    }

    override func tearDown() async throws {
        let lightning = await MainActor.run { settings.lightningService }
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
        let lightning = await MainActor.run { settings.lightningService }
        try await lightning.setup(walletIndex: walletIndex)
        try await lightning.start()
        try await lightning.sync()
    }

    @MainActor
    func testGetBalanceForAddressType() async throws {
        try await setupWalletAndNode()

        Logger.test("Getting balance for nativeSegwit", context: "AddressTypeIntegrationTests")
        let balance = try await settings.lightningService.getBalanceForAddressType(.nativeSegwit)
        XCTAssertGreaterThanOrEqual(balance.totalSats, 0)
        Logger.test("Balance: \(balance.totalSats) sats", context: "AddressTypeIntegrationTests")
    }

    @MainActor
    func testGetChannelFundableBalance() async throws {
        try await setupWalletAndNode()

        Logger.test("Getting channel fundable balance", context: "AddressTypeIntegrationTests")
        let (selectedType, monitoredTypes) = Bitkit.LightningService.addressTypeStateFromUserDefaults()
        let fundable = try await settings.lightningService.getChannelFundableBalance(selectedType: selectedType, monitoredTypes: monitoredTypes)
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
        try await settings.lightningService.addAddressTypeToMonitor(.taproot)
        try await settings.lightningService.sync()

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

    // MARK: - Mutex / Concurrency

    @MainActor
    func testUpdateAddressTypeMutexReturnsImmediately() async throws {
        try await setupWalletAndNode()

        Logger.test("Testing updateAddressType mutex guard", context: "AddressTypeIntegrationTests")
        // First call should succeed
        let success = await settings.updateAddressType(.taproot, wallet: nil)
        XCTAssertTrue(success)

        // Same type returns true (guard: addressType == selectedAddressType)
        let sameTypeResult = await settings.updateAddressType(.taproot, wallet: nil)
        XCTAssertTrue(sameTypeResult, "Same type should return true immediately")
    }

    // MARK: - Channel Fundable Balance Excludes Legacy

    @MainActor
    func testGetChannelFundableBalanceExcludesLegacy() async throws {
        try await setupWalletAndNode()

        let blocktank = CoreService.shared.blocktank

        // Enable legacy monitoring and switch to legacy
        settings.addressTypesToMonitor = [.nativeSegwit, .legacy]
        UserDefaults.standard.synchronize()
        let updateSuccess = await settings.updateAddressType(.legacy, wallet: nil)
        XCTAssertTrue(updateSuccess)

        let legacyAddress = try await settings.lightningService.newAddressForType(.legacy)
        Logger.test("Funding legacy address: \(legacyAddress)", context: "AddressTypeIntegrationTests")
        let txId = try await blocktank.regtestDepositFunds(address: legacyAddress, amountSat: 50000)
        XCTAssertFalse(txId.isEmpty)

        try await blocktank.regtestMineBlocks(6)
        try await Task.sleep(nanoseconds: 15_000_000_000)
        try await settings.lightningService.sync()

        // Verify legacy has balance
        let legacyBalance = try await settings.lightningService.getBalanceForAddressType(.legacy)
        XCTAssertGreaterThan(legacyBalance.totalSats, 0, "Legacy should have balance")

        // Channel fundable should NOT include legacy
        let fundable = try await settings.lightningService.getChannelFundableBalance(
            selectedType: .legacy,
            monitoredTypes: [.nativeSegwit, .legacy]
        )
        XCTAssertEqual(fundable, 0, "Channel fundable should exclude legacy even when it has balance")
        Logger.test("Channel fundable correctly excludes legacy: \(fundable)", context: "AddressTypeIntegrationTests")
    }

    // MARK: - Disable Monitoring With Balance Fails

    @MainActor
    func testSetMonitoringDisableWithBalanceFails() async throws {
        try await setupWalletAndNode()

        let blocktank = CoreService.shared.blocktank

        // Enable taproot monitoring
        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()
        let addSuccess = await settings.setMonitoring(.taproot, enabled: true, wallet: nil)
        XCTAssertTrue(addSuccess, "Adding taproot should succeed")

        // Fund the taproot address
        let taprootAddress = try await settings.lightningService.newAddressForType(.taproot)
        Logger.test("Funding taproot address: \(taprootAddress)", context: "AddressTypeIntegrationTests")
        let txId = try await blocktank.regtestDepositFunds(address: taprootAddress, amountSat: 50000)
        XCTAssertFalse(txId.isEmpty)

        try await blocktank.regtestMineBlocks(6)
        try await Task.sleep(nanoseconds: 15_000_000_000)
        try await settings.lightningService.sync()

        // Verify taproot has balance
        let taprootBalance = try await settings.lightningService.getBalanceForAddressType(.taproot)
        XCTAssertGreaterThan(taprootBalance.totalSats, 0, "Taproot should have balance after funding")

        // Attempt to disable — should fail because of balance
        Logger.test("Attempting to disable taproot monitoring with balance", context: "AddressTypeIntegrationTests")
        let disableSuccess = await settings.setMonitoring(.taproot, enabled: false, wallet: nil)
        XCTAssertFalse(disableSuccess, "Disabling type with balance should fail")
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot), "Taproot should remain monitored")
    }

    // MARK: - Prune Preserves Types With Balance

    @MainActor
    func testPruneEmptyPreservesTypesWithBalance() async throws {
        try await setupWalletAndNode()

        let blocktank = CoreService.shared.blocktank

        // Enable taproot monitoring
        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()
        let addSuccess = await settings.setMonitoring(.taproot, enabled: true, wallet: nil)
        XCTAssertTrue(addSuccess)

        // Fund the taproot address
        let taprootAddress = try await settings.lightningService.newAddressForType(.taproot)
        Logger.test("Funding taproot for prune test: \(taprootAddress)", context: "AddressTypeIntegrationTests")
        let txId = try await blocktank.regtestDepositFunds(address: taprootAddress, amountSat: 50000)
        XCTAssertFalse(txId.isEmpty)

        try await blocktank.regtestMineBlocks(6)
        try await Task.sleep(nanoseconds: 15_000_000_000)
        try await settings.lightningService.sync()

        // Add legacy (will be empty)
        let addLegacy = await settings.setMonitoring(.legacy, enabled: true, wallet: nil)
        XCTAssertTrue(addLegacy)
        XCTAssertEqual(settings.addressTypesToMonitor.count, 3)

        Logger.test("Pruning — should remove empty legacy but keep funded taproot", context: "AddressTypeIntegrationTests")
        await settings.pruneEmptyAddressTypesAfterRestore()

        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nativeSegwit), "nativeSegwit should remain")
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.taproot), "Funded taproot should remain")
        XCTAssertFalse(settings.addressTypesToMonitor.contains(.legacy), "Empty legacy should be pruned")
    }

    // MARK: - Address Format Verification

    @MainActor
    func testNewAddressMatchesTypeFormat() async throws {
        try await setupWalletAndNode()

        // Enable all types so LDK creates wallets for each
        settings.addressTypesToMonitor = [.nativeSegwit]
        UserDefaults.standard.synchronize()
        for type in [LDKNode.AddressType.taproot, .nestedSegwit, .legacy] {
            let success = await settings.setMonitoring(type, enabled: true, wallet: nil)
            XCTAssertTrue(success, "Enabling \(type.stringValue) monitoring should succeed")
        }

        let expectations: [(LDKNode.AddressType, String, String)] = [
            (.legacy, "m", "Legacy address should start with m or n on regtest"),
            (.nestedSegwit, "2", "Nested SegWit address should start with 2 on regtest"),
            (.nativeSegwit, "bcrt1q", "Native SegWit address should start with bcrt1q on regtest"),
            (.taproot, "bcrt1p", "Taproot address should start with bcrt1p on regtest"),
        ]

        for (type, prefix, message) in expectations {
            let address = try await settings.lightningService.newAddressForType(type)
            Logger.test("\(type.stringValue) address: \(address)", context: "AddressTypeIntegrationTests")
            XCTAssertTrue(address.hasPrefix(prefix), "\(message), got: \(address)")
        }
    }
}
