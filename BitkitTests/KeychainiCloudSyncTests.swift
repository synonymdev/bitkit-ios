@testable import Bitkit
import XCTest

/// Tests to verify keychain items are NOT synced to iCloud
final class KeychainiCloudSyncTests: XCTestCase {
    override func setUpWithError() throws {
        try Keychain.wipeEntireKeychain()
        try? KeychainCrypto.deleteKey()
    }

    override func tearDownWithError() throws {
        try? KeychainCrypto.deleteKey()
    }

    func testKeychainItemsDoNotSyncToiCloud() throws {
        // Given: A test mnemonic
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        // When: Saving to keychain
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)

        // Then: Verify the keychain item was created with correct attributes
        // Query the keychain to check if kSecAttrSynchronizable is set to false
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bip39_mnemonic_0",
            kSecAttrAccessGroup as String: Env.keychainGroup,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess, "Should find the keychain item")

        guard let attributes = result as? [String: Any] else {
            XCTFail("Failed to get keychain item attributes")
            return
        }

        // Check if synchronizable attribute is set
        // If kSecAttrSynchronizable is not present or is false, item won't sync to iCloud
        if let synchronizable = attributes[kSecAttrSynchronizable as String] as? Bool {
            XCTAssertFalse(synchronizable, "Keychain items MUST NOT sync to iCloud for security")
        } else {
            // If the attribute is not set, check the accessibility attribute
            // kSecAttrAccessibleAfterFirstUnlock allows iCloud sync by default
            // We should be using kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly instead
            if let accessibility = attributes[kSecAttrAccessible as String] as? String {
                let thisDeviceOnlyAttributes = [
                    kSecAttrAccessibleWhenUnlocked as String,
                    kSecAttrAccessibleAfterFirstUnlock as String,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                ]

                // Items with "ThisDeviceOnly" suffix do NOT sync to iCloud
                let isThisDeviceOnly = accessibility.contains("ThisDeviceOnly")
                    || accessibility == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                    || accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

                XCTAssertTrue(
                    isThisDeviceOnly,
                    """
                    Keychain items should use 'ThisDeviceOnly' accessibility to prevent iCloud sync.
                    Current: \(accessibility)
                    Expected: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    """
                )
            }
        }
    }

    func testAllKeychainItemTypesDoNotSyncToiCloud() throws {
        // Test all keychain item types
        let testItems: [(KeychainEntryType, String)] = [
            (.bip39Mnemonic(index: 0), "test mnemonic"),
            (.bip39Passphrase(index: 0), "test passphrase"),
            (.securityPin, "123456"),
            (.pushNotificationPrivateKey, "test_key"),
        ]

        for (keyType, value) in testItems {
            // Save item
            try Keychain.saveString(key: keyType, str: value)

            // Query attributes
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: keyType.storageKey,
                kSecAttrAccessGroup as String: Env.keychainGroup,
                kSecReturnAttributes as String: true,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            XCTAssertEqual(status, errSecSuccess, "Should find \(keyType.storageKey)")

            if let attributes = result as? [String: Any],
               let accessibility = attributes[kSecAttrAccessible as String] as? String
            {
                let isThisDeviceOnly = accessibility.contains("ThisDeviceOnly")
                    || accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

                XCTAssertTrue(
                    isThisDeviceOnly,
                    "\(keyType.storageKey) should NOT sync to iCloud. Current: \(accessibility)"
                )
            }

            // Clean up
            try Keychain.delete(key: keyType)
        }
    }
}
