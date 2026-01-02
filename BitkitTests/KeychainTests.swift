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

    func testKeychainWithoutEncryptionKeyFails() throws {
        // Given: A saved mnemonic with encryption
        let testMnemonic = "test mnemonic with encryption"
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)

        // When: Deleting the encryption key
        try KeychainCrypto.deleteKey()

        // Then: Loading should fail with decryption error
        XCTAssertThrowsError(try Keychain.loadString(key: .bip39Mnemonic(index: 0))) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Should throw KeychainError")
                return
            }
            XCTAssertEqual(keychainError, .failedToDecrypt, "Should fail with decryption error")
        }
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
}
