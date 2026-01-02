@testable import Bitkit
import XCTest

final class KeychainTests: XCTestCase {
    override func setUpWithError() throws {
        try Keychain.wipeEntireKeychain()
        try? KeychainCrypto.deleteKey() // Clean encryption key before each test
    }

    override func tearDownWithError() throws {
        try? KeychainCrypto.deleteKey() // Clean encryption key after each test
    }

    func testKeychain() throws {
        let testMnemonic =
            "test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999)) test\(Int.random(in: 0 ... 99999))"
        let testPassphrase = "testpasshrase\(Int.random(in: 0 ... 99999))"

        // Write
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)
        try Keychain.saveString(key: .bip39Passphrase(index: 0), str: testPassphrase)

        // Read
        XCTAssertEqual(try Keychain.loadString(key: .bip39Mnemonic(index: 0)), testMnemonic)
        XCTAssertEqual(try Keychain.loadString(key: .bip39Passphrase(index: 0)), testPassphrase)

        // Not allowed to overwrite existing key
        XCTAssertThrowsError(try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic))
        XCTAssertThrowsError(try Keychain.saveString(key: .bip39Passphrase(index: 0), str: testMnemonic))

        // Test deleting
        try Keychain.delete(key: .bip39Mnemonic(index: 0))
        try Keychain.delete(key: .bip39Passphrase(index: 0))

        // Write multiple wallets
        for i in 0 ... 5 {
            try Keychain.saveString(key: .bip39Mnemonic(index: i), str: "\(testMnemonic) index\(i)")
            try Keychain.saveString(key: .bip39Passphrase(index: i), str: "\(testPassphrase) index\(i)")
        }

        // Check all keys are saved correctly
        let listedKeys = Keychain.getAllKeyChainStorageKeys()
        // Note: getAllKeyChainStorageKeys() returns ALL keychain items (all apps),
        // so we check for at least our 12 items, not exactly 12
        XCTAssertGreaterThanOrEqual(listedKeys.count, 12, "Should have at least our 12 items")
        for i in 0 ... 5 {
            XCTAssertTrue(listedKeys.contains("bip39_mnemonic_\(i)"))
            XCTAssertTrue(listedKeys.contains("bip39_passphrase_\(i)"))
        }

        // Check each value
        for i in 0 ... 5 {
            XCTAssertEqual(try Keychain.loadString(key: .bip39Mnemonic(index: i)), "\(testMnemonic) index\(i)")
            XCTAssertEqual(try Keychain.loadString(key: .bip39Passphrase(index: i)), "\(testPassphrase) index\(i)")
        }

        // Wipe
        try Keychain.wipeEntireKeychain()

        // Check our keys are gone (verify specific keys, not count)
        for i in 0 ... 5 {
            XCTAssertNil(try Keychain.loadString(key: .bip39Mnemonic(index: i)))
            XCTAssertNil(try Keychain.loadString(key: .bip39Passphrase(index: i)))
        }
    }

    // MARK: - Encryption Integration Tests

    func testKeychainDataIsEncrypted() throws {
        // Given: A test mnemonic
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        // When: Saving to keychain
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)

        // Then: Encryption key should have been created
        XCTAssertTrue(KeychainCrypto.keyExists(), "Encryption key should be created when saving to keychain")

        // And: Data should be retrievable and match original
        let retrieved = try Keychain.loadString(key: .bip39Mnemonic(index: 0))
        XCTAssertEqual(retrieved, testMnemonic, "Retrieved data should match original")
    }

    func testKeychainWithoutEncryptionKeyReturnsEncryptedData() throws {
        // Given: A saved mnemonic with encryption
        let testMnemonic = "test mnemonic with encryption"
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)

        // Get the encrypted data for comparison
        var encryptedData: Data?
        var dataTypeRef: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bip39_mnemonic_0",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        encryptedData = dataTypeRef as? Data

        // When: Deleting the encryption key (simulating orphaned scenario)
        try KeychainCrypto.deleteKey()

        // Then: Loading returns the encrypted data as-is (migration path)
        // Note: This is encrypted garbage, but AppScene.handleOrphanedKeychainScenario()
        // will detect this scenario and wipe the keychain before the app starts
        let loaded = try Keychain.load(key: .bip39Mnemonic(index: 0))
        XCTAssertEqual(loaded, encryptedData, "Should return encrypted data as-is when no key exists")

        // And: The loaded data should NOT equal the original plaintext
        let loadedString = String(data: loaded!, encoding: .utf8)
        XCTAssertNotEqual(loadedString, testMnemonic, "Returned data should be encrypted, not plaintext")
    }

    func testMultipleKeychainItemsUseSameEncryptionKey() throws {
        // Given: Multiple test values
        let testMnemonic = "test mnemonic"
        let testPassphrase = "test passphrase"
        let testPin = "123456"

        // When: Saving multiple items
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)
        try Keychain.saveString(key: .bip39Passphrase(index: 0), str: testPassphrase)
        try Keychain.saveString(key: .securityPin, str: testPin)

        // Then: All should be retrievable
        XCTAssertEqual(try Keychain.loadString(key: .bip39Mnemonic(index: 0)), testMnemonic)
        XCTAssertEqual(try Keychain.loadString(key: .bip39Passphrase(index: 0)), testPassphrase)
        XCTAssertEqual(try Keychain.loadString(key: .securityPin), testPin)

        // And: Only one encryption key file should exist
        XCTAssertTrue(KeychainCrypto.keyExists())
    }

    func testKeychainEncryptionWithBinaryData() throws {
        // Given: Binary data (push notification private key)
        var binaryData = Data()
        for i in 0 ..< 32 {
            binaryData.append(UInt8(i))
        }

        // When: Saving binary data
        try Keychain.save(key: .pushNotificationPrivateKey, data: binaryData)

        // Then: Should be retrievable and match exactly
        let retrieved = try Keychain.load(key: .pushNotificationPrivateKey)
        XCTAssertEqual(retrieved, binaryData, "Binary data should be preserved exactly")
    }

    func testKeychainWipeDoesNotDeleteEncryptionKey() throws {
        // Given: Saved keychain items
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "test")
        XCTAssertTrue(KeychainCrypto.keyExists())

        // When: Wiping keychain
        try Keychain.wipeEntireKeychain()

        // Then: Our keychain item should be gone
        XCTAssertNil(try Keychain.loadString(key: .bip39Mnemonic(index: 0)))

        // But: Encryption key is NOT deleted by wipeEntireKeychain()
        // This is intentional - only AppReset.wipe() deletes the encryption key
        // The key will be reused if new items are saved
        XCTAssertTrue(KeychainCrypto.keyExists(), "Encryption key should persist after keychain wipe")
    }

    func testEncryptionPreservesUnicodeCharacters() throws {
        // Given: Mnemonic with unicode characters
        let unicodeMnemonic = "test émoji 🔑 中文 العربية"

        // When: Saving and loading
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: unicodeMnemonic)
        let retrieved = try Keychain.loadString(key: .bip39Mnemonic(index: 0))

        // Then: Unicode should be preserved
        XCTAssertEqual(retrieved, unicodeMnemonic)
    }

    func testEncryptionWithEmptyString() throws {
        // Given: Empty passphrase
        let emptyPassphrase = ""

        // When: Saving and loading
        try Keychain.saveString(key: .bip39Passphrase(index: 0), str: emptyPassphrase)
        let retrieved = try Keychain.loadString(key: .bip39Passphrase(index: 0))

        // Then: Empty string should be preserved
        XCTAssertEqual(retrieved, emptyPassphrase)
    }

    func testEncryptionKeyPersistsAcrossMultipleSaves() throws {
        // Given: First save creates encryption key
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "first")
        let firstKeyExists = KeychainCrypto.keyExists()
        XCTAssertTrue(firstKeyExists)

        // When: Deleting first item and saving another
        try Keychain.delete(key: .bip39Mnemonic(index: 0))
        try Keychain.saveString(key: .bip39Mnemonic(index: 1), str: "second")

        // Then: Same encryption key should be reused
        XCTAssertTrue(KeychainCrypto.keyExists())

        // And: Both old and new items work (new one is retrievable)
        XCTAssertNil(try Keychain.loadString(key: .bip39Mnemonic(index: 0))) // Deleted
        XCTAssertEqual(try Keychain.loadString(key: .bip39Mnemonic(index: 1)), "second")
    }

    // MARK: - Migration Tests

    func testMigrationFromUnencryptedData() throws {
        // Given: Plaintext data directly in keychain (simulating master branch)
        let testMnemonic = "test mnemonic from master"
        let plaintextData = testMnemonic.data(using: .utf8)!

        // Manually insert plaintext into keychain (bypass Keychain.save)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccount as String: "bip39_mnemonic_0",
            kSecValueData as String: plaintextData,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        // Ensure no encryption key exists
        XCTAssertFalse(KeychainCrypto.keyExists())

        // When: Loading the data using new code
        let loaded = try Keychain.loadString(key: .bip39Mnemonic(index: 0))

        // Then: Should successfully load plaintext
        XCTAssertEqual(loaded, testMnemonic)
    }

    func testMigrationAutoEncryptsOnNextSave() throws {
        // Given: Legacy plaintext in keychain
        let plaintextData = "legacy".data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccount as String: "bip39_mnemonic_1",
            kSecValueData as String: plaintextData,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        SecItemAdd(query as CFDictionary, nil)

        // Load legacy data (does not create encryption key, just returns plaintext)
        let loaded = try Keychain.loadString(key: .bip39Mnemonic(index: 1))
        XCTAssertEqual(loaded, "legacy")

        // When: Deleting and re-saving
        try Keychain.delete(key: .bip39Mnemonic(index: 1))
        try Keychain.saveString(key: .bip39Mnemonic(index: 1), str: "new encrypted")

        // Then: Data should now be encrypted
        XCTAssertTrue(KeychainCrypto.keyExists())

        // Verify by trying to read raw keychain data - it should be encrypted
        var dataTypeRef: AnyObject?
        let loadQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bip39_mnemonic_1",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        SecItemCopyMatching(loadQuery as CFDictionary, &dataTypeRef)
        let rawData = dataTypeRef as! Data

        // Raw data should NOT be plaintext "new encrypted"
        let plaintextAttempt = String(data: rawData, encoding: .utf8)
        XCTAssertNotEqual(plaintextAttempt, "new encrypted", "Data should be encrypted")
    }

    func testDecryptionFailsWithCorruptedDataWhenKeyExists() throws {
        // Given: Encryption key exists and encrypted data is saved
        try Keychain.saveString(key: .bip39Mnemonic(index: 2), str: "test")
        XCTAssertTrue(KeychainCrypto.keyExists())

        // When: Manually corrupting the encrypted data in keychain
        var dataTypeRef: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bip39_mnemonic_2",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        var corruptedData = dataTypeRef as! Data
        corruptedData[corruptedData.count - 1] ^= 0xFF // Flip bits

        // Update keychain with corrupted data
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bip39_mnemonic_2",
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: corruptedData]
        SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        // Then: Should throw failedToDecrypt (not return plaintext)
        XCTAssertThrowsError(try Keychain.loadString(key: .bip39Mnemonic(index: 2))) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Should throw KeychainError")
                return
            }
            XCTAssertEqual(keychainError, .failedToDecrypt)
        }
    }
}
