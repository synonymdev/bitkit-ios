@testable import Bitkit
import Security
import XCTest

/// Tests for RN (React Native) migration cleanup functionality.
/// These tests verify the detection of orphaned RN keychain data and proper cleanup
/// of RN data after migration.
final class RNMigrationCleanupTests: XCTestCase {
    private let migrations = MigrationsService.shared
    private let fileManager = FileManager.default

    // RN wallet name used by the migration service
    private let rnWalletName = "wallet0"

    // Sandbox Documents directory (where RN stored its data)
    private var sandboxDocuments: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var rnMmkvPath: URL {
        sandboxDocuments.appendingPathComponent("mmkv")
    }

    private var rnLdkPath: URL {
        sandboxDocuments.appendingPathComponent("ldk")
    }

    override func setUp() {
        super.setUp()
        // Clean up any existing test data
        cleanupRNTestData()
        try? Keychain.wipeEntireKeychain()
    }

    override func tearDown() {
        // Clean up after tests
        cleanupRNTestData()
        try? Keychain.wipeEntireKeychain()
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func cleanupRNTestData() {
        // Clean up RN keychain entries
        migrations.cleanupRNKeychain()

        // Clean up RN files
        try? fileManager.removeItem(at: rnMmkvPath)
        try? fileManager.removeItem(at: rnLdkPath)
    }

    private func createRNKeychainEntry(walletName: String, mnemonic: String) {
        // Simulate RN keychain storage format
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: walletName,
            kSecAttrAccount as String: walletName,
            kSecValueData as String: mnemonic.data(using: .utf8)!,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func createRNMmkvDirectory() throws {
        // Create MMKV directory structure as RN would
        let mmkvDefaultPath = rnMmkvPath.appendingPathComponent("mmkv.default")
        try fileManager.createDirectory(at: rnMmkvPath, withIntermediateDirectories: true)
        // Create a dummy mmkv.default file
        try "dummy_mmkv_data".data(using: .utf8)!.write(to: mmkvDefaultPath)
    }

    private func createRNLdkDirectory() throws {
        // Create LDK directory structure as RN would
        let accountPath = rnLdkPath.appendingPathComponent("\(rnWalletName)bitcoinRegtestldkaccountv3")
        try fileManager.createDirectory(at: accountPath, withIntermediateDirectories: true)
        // Create a dummy channel_manager.bin file
        let channelManagerPath = accountPath.appendingPathComponent("channel_manager.bin")
        try "dummy_channel_manager".data(using: .utf8)!.write(to: channelManagerPath)
    }

    // MARK: - Orphaned RN Keychain Detection Tests

    func testHasOrphanedRNKeychainReturnsFalseWhenNoData() {
        // No RN keychain data, no RN files
        XCTAssertFalse(migrations.hasOrphanedRNKeychain())
    }

    func testHasOrphanedRNKeychainReturnsTrueWhenOnlyKeychain() {
        // Setup: RN keychain exists but no MMKV or LDK files
        createRNKeychainEntry(walletName: rnWalletName, mnemonic: "test mnemonic words here")

        // Should detect as orphaned (keychain without files)
        XCTAssertTrue(migrations.hasOrphanedRNKeychain())
    }

    func testHasOrphanedRNKeychainReturnsFalseWhenMmkvExists() throws {
        // Setup: RN keychain AND MMKV files exist (valid RN data)
        createRNKeychainEntry(walletName: rnWalletName, mnemonic: "test mnemonic words here")
        try createRNMmkvDirectory()

        // Should NOT be orphaned (has corresponding files)
        XCTAssertFalse(migrations.hasOrphanedRNKeychain())
    }

    func testHasOrphanedRNKeychainReturnsFalseWhenLdkExists() throws {
        // Setup: RN keychain AND LDK files exist (valid RN data)
        createRNKeychainEntry(walletName: rnWalletName, mnemonic: "test mnemonic words here")
        try createRNLdkDirectory()

        // Should NOT be orphaned (has corresponding files)
        XCTAssertFalse(migrations.hasOrphanedRNKeychain())
    }

    func testHasOrphanedRNKeychainReturnsFalseWhenBothFilesExist() throws {
        // Setup: RN keychain AND both MMKV and LDK files exist
        createRNKeychainEntry(walletName: rnWalletName, mnemonic: "test mnemonic words here")
        try createRNMmkvDirectory()
        try createRNLdkDirectory()

        // Should NOT be orphaned (has corresponding files)
        XCTAssertFalse(migrations.hasOrphanedRNKeychain())
    }

    // MARK: - RN Keychain Cleanup Tests

    func testCleanupRNKeychainDeletesEntries() {
        // Setup: Create RN keychain entries
        createRNKeychainEntry(walletName: rnWalletName, mnemonic: "test mnemonic")

        // Also create passphrase entry
        let passphraseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(rnWalletName)passphrase",
            kSecAttrAccount as String: "\(rnWalletName)passphrase",
            kSecValueData as String: "test passphrase".data(using: .utf8)!,
        ]
        SecItemAdd(passphraseQuery as CFDictionary, nil)

        // Verify entries exist
        XCTAssertTrue(migrations.hasRNWalletData())

        // Clean up
        migrations.cleanupRNKeychain()

        // Verify entries are deleted
        XCTAssertFalse(migrations.hasRNWalletData())
    }

    func testCleanupRNKeychainHandlesMissingEntries() {
        // No RN keychain entries exist
        XCTAssertFalse(migrations.hasRNWalletData())

        // Cleanup should not throw even with no entries
        migrations.cleanupRNKeychain()

        // Still no data (no crash)
        XCTAssertFalse(migrations.hasRNWalletData())
    }

    // MARK: - RN Files Cleanup Tests

    func testCleanupRNFilesDeletesMmkvDirectory() throws {
        // Setup: Create MMKV directory
        try createRNMmkvDirectory()
        XCTAssertTrue(fileManager.fileExists(atPath: rnMmkvPath.path))

        // Clean up
        migrations.cleanupRNFiles()

        // MMKV directory should be deleted
        XCTAssertFalse(fileManager.fileExists(atPath: rnMmkvPath.path))
    }

    func testCleanupRNFilesDeletesLdkDirectory() throws {
        // Setup: Create LDK directory
        try createRNLdkDirectory()
        XCTAssertTrue(fileManager.fileExists(atPath: rnLdkPath.path))

        // Clean up
        migrations.cleanupRNFiles()

        // LDK directory should be deleted
        XCTAssertFalse(fileManager.fileExists(atPath: rnLdkPath.path))
    }

    func testCleanupRNFilesDeletesBothDirectories() throws {
        // Setup: Create both directories
        try createRNMmkvDirectory()
        try createRNLdkDirectory()
        XCTAssertTrue(fileManager.fileExists(atPath: rnMmkvPath.path))
        XCTAssertTrue(fileManager.fileExists(atPath: rnLdkPath.path))

        // Clean up
        migrations.cleanupRNFiles()

        // Both directories should be deleted
        XCTAssertFalse(fileManager.fileExists(atPath: rnMmkvPath.path))
        XCTAssertFalse(fileManager.fileExists(atPath: rnLdkPath.path))
    }

    func testCleanupRNFilesHandlesMissingDirectories() {
        // No directories exist
        XCTAssertFalse(fileManager.fileExists(atPath: rnMmkvPath.path))
        XCTAssertFalse(fileManager.fileExists(atPath: rnLdkPath.path))

        // Cleanup should not throw
        migrations.cleanupRNFiles()

        // Still no directories (no crash)
        XCTAssertFalse(fileManager.fileExists(atPath: rnMmkvPath.path))
        XCTAssertFalse(fileManager.fileExists(atPath: rnLdkPath.path))
    }

    // MARK: - Full Cleanup Tests

    func testCleanupAfterMigrationDeletesEverything() throws {
        // Setup: Create all RN data
        createRNKeychainEntry(walletName: rnWalletName, mnemonic: "test mnemonic")
        try createRNMmkvDirectory()
        try createRNLdkDirectory()

        // Verify data exists
        XCTAssertTrue(migrations.hasRNWalletData())
        XCTAssertTrue(fileManager.fileExists(atPath: rnMmkvPath.path))
        XCTAssertTrue(fileManager.fileExists(atPath: rnLdkPath.path))

        // Full cleanup
        migrations.cleanupAfterMigration()

        // Everything should be deleted
        XCTAssertFalse(migrations.hasRNWalletData())
        XCTAssertFalse(fileManager.fileExists(atPath: rnMmkvPath.path))
        XCTAssertFalse(fileManager.fileExists(atPath: rnLdkPath.path))
    }
}
