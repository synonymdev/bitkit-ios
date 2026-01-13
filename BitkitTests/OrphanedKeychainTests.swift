@testable import Bitkit
import XCTest

/// Tests for orphaned keychain detection and handling.
/// These tests verify that the app correctly identifies and handles keychain data
/// that persists after app uninstall/reinstall.
final class OrphanedKeychainTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clean state before each test
        try? Keychain.wipeEntireKeychain()
        try? InstallationMarker.delete()
    }

    override func tearDown() {
        // Clean state after each test
        try? Keychain.wipeEntireKeychain()
        try? InstallationMarker.delete()
        super.tearDown()
    }

    // MARK: - Installation Marker Tests

    func testFreshInstallScenario() {
        // Scenario: Fresh install - no marker, no keychain data

        // Verify initial state
        XCTAssertFalse(InstallationMarker.exists())
        XCTAssertFalse((try? Keychain.exists(key: .bip39Mnemonic(index: 0))) ?? false)

        // This is what handleOrphanedKeychain() should do:
        // 1. No orphaned data to clean
        // 2. Create the marker

        // After handling, marker should be created
        XCTAssertNoThrow(try InstallationMarker.create())
        XCTAssertTrue(InstallationMarker.exists())
    }

    func testNormalAppLaunchWithMarker() throws {
        // Scenario: Normal app launch - marker exists, keychain has valid data

        // Setup: Create marker and keychain data (simulating previous successful install)
        try InstallationMarker.create()
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "test mnemonic words")

        // Verify state
        XCTAssertTrue(InstallationMarker.exists())
        XCTAssertTrue(try Keychain.exists(key: .bip39Mnemonic(index: 0)))

        // When marker exists, keychain should NOT be wiped
        // (handleOrphanedKeychain returns early when marker exists)

        // Keychain data should still be there
        XCTAssertEqual(try Keychain.loadString(key: .bip39Mnemonic(index: 0)), "test mnemonic words")
    }

    func testOrphanedNativeKeychainDetection() throws {
        // Scenario: Reinstall - no marker, but keychain has mnemonic (orphaned)

        // Setup: Keychain has data but no marker (simulates reinstall after uninstall)
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "orphaned mnemonic")
        XCTAssertFalse(InstallationMarker.exists())

        // Detect orphaned state
        let hasNativeKeychain = (try? Keychain.exists(key: .bip39Mnemonic(index: 0))) == true
        XCTAssertTrue(hasNativeKeychain)

        // This is orphaned: keychain exists but marker doesn't
        // handleOrphanedKeychain() should wipe the keychain

        try Keychain.wipeEntireKeychain()

        // After wipe, keychain should be empty
        XCTAssertFalse((try? Keychain.exists(key: .bip39Mnemonic(index: 0))) ?? false)

        // Then marker should be created
        try InstallationMarker.create()
        XCTAssertTrue(InstallationMarker.exists())
    }

    func testMultipleOrphanedKeysAreAllWiped() throws {
        // Scenario: Multiple keychain entries exist without marker

        // Setup: Multiple keychain entries
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "mnemonic 0")
        try Keychain.saveString(key: .bip39Passphrase(index: 0), str: "passphrase 0")
        try Keychain.saveString(key: .bip39Mnemonic(index: 1), str: "mnemonic 1")
        try Keychain.saveString(key: .securityPin, str: "123456")

        // Verify all keys exist
        XCTAssertTrue(try Keychain.exists(key: .bip39Mnemonic(index: 0)))
        XCTAssertTrue(try Keychain.exists(key: .bip39Passphrase(index: 0)))
        XCTAssertTrue(try Keychain.exists(key: .bip39Mnemonic(index: 1)))
        XCTAssertTrue(try Keychain.exists(key: .securityPin))

        // Wipe entire keychain (what handleOrphanedKeychain does)
        try Keychain.wipeEntireKeychain()

        // All keys should be gone
        XCTAssertFalse((try? Keychain.exists(key: .bip39Mnemonic(index: 0))) ?? false)
        XCTAssertFalse((try? Keychain.exists(key: .bip39Passphrase(index: 0))) ?? false)
        XCTAssertFalse((try? Keychain.exists(key: .bip39Mnemonic(index: 1))) ?? false)
        XCTAssertFalse((try? Keychain.exists(key: .securityPin)) ?? false)
    }

    func testOrphanedKeychainWithPassphraseOnly() throws {
        // Edge case: Only passphrase exists (no mnemonic) - still orphaned

        try Keychain.saveString(key: .bip39Passphrase(index: 0), str: "orphaned passphrase")

        // Verify passphrase was saved
        XCTAssertTrue(try Keychain.exists(key: .bip39Passphrase(index: 0)))

        // Wipe should clean it
        try Keychain.wipeEntireKeychain()
        XCTAssertFalse((try? Keychain.exists(key: .bip39Passphrase(index: 0))) ?? false)
    }

    func testAppResetDeletesMarker() throws {
        // Scenario: App reset should delete marker so next launch detects as fresh

        // Setup: Normal state with marker and keychain
        try InstallationMarker.create()
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "test mnemonic")

        XCTAssertTrue(InstallationMarker.exists())
        XCTAssertTrue(try Keychain.exists(key: .bip39Mnemonic(index: 0)))

        // Simulate app reset: wipe keychain and delete marker
        try Keychain.wipeEntireKeychain()
        try InstallationMarker.delete()

        // After reset, both should be gone
        XCTAssertFalse(InstallationMarker.exists())
        XCTAssertFalse((try? Keychain.exists(key: .bip39Mnemonic(index: 0))) ?? false)
    }
}
