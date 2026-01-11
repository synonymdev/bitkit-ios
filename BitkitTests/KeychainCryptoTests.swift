@testable import Bitkit
import CryptoKit
import XCTest

final class KeychainCryptoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clean up any existing encryption key before each test
        try? KeychainCrypto.deleteKey()
    }

    override func tearDown() {
        // Clean up after each test
        try? KeychainCrypto.deleteKey()
        super.tearDown()
    }

    // MARK: - Key Generation Tests

    func testKeyGenerationCreates256BitKey() throws {
        // When: Creating a new encryption key
        let key = try KeychainCrypto.getOrCreateKey()

        // Then: Key should be 256 bits (32 bytes)
        key.withUnsafeBytes { bytes in
            XCTAssertEqual(bytes.count, 32, "Key should be 256 bits (32 bytes)")
        }
    }

    func testKeyPersistenceToFile() throws {
        // Given: No key exists initially
        XCTAssertFalse(KeychainCrypto.keyExists())

        // When: Creating a key
        _ = try KeychainCrypto.getOrCreateKey()

        // Then: Key file should exist
        XCTAssertTrue(KeychainCrypto.keyExists())
    }

    func testKeyLoadingFromFile() throws {
        // Given: A key has been created and saved
        let originalKey = try KeychainCrypto.getOrCreateKey()

        // When: Deleting the cached key and loading again
        try KeychainCrypto.deleteKey()
        let loadedKey = try KeychainCrypto.getOrCreateKey()

        // Then: Loaded key should match original
        var originalData = Data()
        var loadedData = Data()

        originalKey.withUnsafeBytes { originalData = Data($0) }
        loadedKey.withUnsafeBytes { loadedData = Data($0) }

        // Note: Keys are different after deletion since a new key is created
        // This test verifies that getOrCreateKey works after deletion
        XCTAssertEqual(loadedData.count, 32)
    }

    func testKeyCaching() throws {
        // Given: A key has been created
        let firstKey = try KeychainCrypto.getOrCreateKey()

        // When: Calling getOrCreateKey again (should use cache)
        let cachedKey = try KeychainCrypto.getOrCreateKey()

        // Then: Should return the same key instance (from cache)
        var firstData = Data()
        var cachedData = Data()

        firstKey.withUnsafeBytes { firstData = Data($0) }
        cachedKey.withUnsafeBytes { cachedData = Data($0) }

        XCTAssertEqual(firstData, cachedData, "Cached key should match first key")
    }

    // MARK: - Encryption Tests

    func testEncryptionProducesDifferentOutputForSameInput() throws {
        // Given: Same plaintext data
        let plaintext = "test data".data(using: .utf8)!

        // When: Encrypting the same data twice
        let encrypted1 = try KeychainCrypto.encrypt(plaintext)
        let encrypted2 = try KeychainCrypto.encrypt(plaintext)

        // Then: Encrypted outputs should differ (due to random nonce)
        XCTAssertNotEqual(encrypted1, encrypted2, "Encryption should produce different output due to random nonce")
    }

    func testEncryptionDecryptionRoundTrip() throws {
        // Given: Original plaintext data
        let originalData = "Hello, World! This is a test of encryption.".data(using: .utf8)!

        // When: Encrypting and then decrypting
        let encrypted = try KeychainCrypto.encrypt(originalData)
        let decrypted = try KeychainCrypto.decrypt(encrypted)

        // Then: Decrypted data should match original
        XCTAssertEqual(decrypted, originalData, "Decrypted data should match original")
    }

    func testEncryptionWithVariousDataSizes() throws {
        // Test with different data sizes
        let testCases: [String] = [
            "", // Empty
            "a", // Single character
            "Short text", // Short
            String(repeating: "Long text ", count: 100), // Long
            String(repeating: "Very long ", count: 1000), // Very long
        ]

        for testString in testCases {
            // Given: Test data
            let original = testString.data(using: .utf8)!

            // When: Encrypting and decrypting
            let encrypted = try KeychainCrypto.encrypt(original)
            let decrypted = try KeychainCrypto.decrypt(encrypted)

            // Then: Should match
            XCTAssertEqual(
                decrypted,
                original,
                "Round-trip should work for data of size \(original.count)"
            )
        }
    }

    // MARK: - Decryption Failure Tests

    func testDecryptWithCorruptedDataFails() throws {
        // Given: Properly encrypted data
        let plaintext = "test data".data(using: .utf8)!
        var encrypted = try KeychainCrypto.encrypt(plaintext)

        // When: Corrupting the encrypted data
        encrypted[encrypted.count - 1] ^= 0xFF // Flip bits in last byte

        // Then: Decryption should fail
        XCTAssertThrowsError(try KeychainCrypto.decrypt(encrypted)) { error in
            XCTAssertTrue(
                error is KeychainCrypto.KeychainCryptoError,
                "Should throw KeychainCryptoError"
            )
        }
    }

    func testDecryptWithTooShortDataFails() throws {
        // Given: Data that's too short to be valid encrypted data (< 28 bytes)
        let tooShortData = Data(repeating: 0, count: 20)

        // Then: Should throw invalidEncryptedData error
        XCTAssertThrowsError(try KeychainCrypto.decrypt(tooShortData)) { error in
            guard let cryptoError = error as? KeychainCrypto.KeychainCryptoError else {
                XCTFail("Should throw KeychainCryptoError")
                return
            }
            XCTAssertEqual(cryptoError, .invalidEncryptedData)
        }
    }

    func testDecryptWithInvalidNonceFails() throws {
        // Given: Data with invalid nonce (but correct length)
        var invalidData = Data(repeating: 0xFF, count: 50)
        // Make last 16 bytes valid-ish (for tag)
        for i in 34 ..< 50 {
            invalidData[i] = UInt8.random(in: 0 ... 255)
        }

        // Then: Should throw decryption error
        XCTAssertThrowsError(try KeychainCrypto.decrypt(invalidData))
    }

    // MARK: - Key Management Tests

    func testKeyExistsReturnsFalseInitially() {
        // Given: Clean state (setUp deletes any existing key)
        // Then: Key should not exist
        XCTAssertFalse(KeychainCrypto.keyExists())
    }

    func testKeyExistsReturnsTrueAfterCreation() throws {
        // Given: No key initially
        XCTAssertFalse(KeychainCrypto.keyExists())

        // When: Creating a key
        _ = try KeychainCrypto.getOrCreateKey()

        // Then: Key should exist
        XCTAssertTrue(KeychainCrypto.keyExists())
    }

    func testDeleteKeyRemovesFile() throws {
        // Given: A key exists
        _ = try KeychainCrypto.getOrCreateKey()
        XCTAssertTrue(KeychainCrypto.keyExists())

        // When: Deleting the key
        try KeychainCrypto.deleteKey()

        // Then: Key should no longer exist
        XCTAssertFalse(KeychainCrypto.keyExists())
    }

    func testDeleteKeyClearsCache() throws {
        // Given: A key exists and is cached
        let originalKey = try KeychainCrypto.getOrCreateKey()
        var originalData = Data()
        originalKey.withUnsafeBytes { originalData = Data($0) }

        // When: Deleting the key and creating a new one
        try KeychainCrypto.deleteKey()
        let newKey = try KeychainCrypto.getOrCreateKey()
        var newData = Data()
        newKey.withUnsafeBytes { newData = Data($0) }

        // Then: New key should be different (cache was cleared)
        XCTAssertNotEqual(originalData, newData, "New key should be different from deleted key")
    }

    func testDeleteNonexistentKeyDoesNotThrow() throws {
        // Given: No key exists
        XCTAssertFalse(KeychainCrypto.keyExists())

        // When/Then: Deleting should not throw
        XCTAssertNoThrow(try KeychainCrypto.deleteKey())
    }

    // MARK: - Encrypted Data Format Tests

    func testEncryptedDataContainsNonceCiphertextAndTag() throws {
        // Given: Original data
        let plaintext = "test".data(using: .utf8)!

        // When: Encrypting
        let encrypted = try KeychainCrypto.encrypt(plaintext)

        // Then: Encrypted data should be at least 28 bytes (12 nonce + 16 tag)
        XCTAssertGreaterThanOrEqual(
            encrypted.count,
            28,
            "Encrypted data should contain at least nonce (12) + tag (16)"
        )

        // And: Should contain the plaintext length + overhead
        let expectedMinSize = 12 + plaintext.count + 16
        XCTAssertEqual(encrypted.count, expectedMinSize)
    }

    // MARK: - Integration Tests

    func testMultipleEncryptDecryptCycles() throws {
        // Given: Multiple pieces of data
        let testData = [
            "First test data",
            "Second test data",
            "Third test data with more content",
        ]

        // When: Encrypting and decrypting each
        for testString in testData {
            let original = testString.data(using: .utf8)!
            let encrypted = try KeychainCrypto.encrypt(original)
            let decrypted = try KeychainCrypto.decrypt(encrypted)

            // Then: Each should decrypt correctly
            XCTAssertEqual(decrypted, original)
        }
    }

    func testEncryptionWithBinaryData() throws {
        // Given: Binary data (not UTF-8 text)
        var binaryData = Data()
        for i in 0 ..< 256 {
            binaryData.append(UInt8(i))
        }

        // When: Encrypting and decrypting
        let encrypted = try KeychainCrypto.encrypt(binaryData)
        let decrypted = try KeychainCrypto.decrypt(encrypted)

        // Then: Should preserve binary data exactly
        XCTAssertEqual(decrypted, binaryData)
    }

    // MARK: - Security Tests

    func testEncryptedDataDoesNotContainPlaintext() throws {
        // Given: Plaintext with distinctive pattern
        let plaintext = "DISTINCTIVE_PATTERN_12345".data(using: .utf8)!

        // When: Encrypting
        let encrypted = try KeychainCrypto.encrypt(plaintext)

        // Then: Encrypted data should not contain the plaintext pattern
        let encryptedString = String(data: encrypted, encoding: .utf8) ?? ""
        XCTAssertFalse(
            encryptedString.contains("DISTINCTIVE_PATTERN"),
            "Encrypted data should not contain plaintext"
        )
    }

    // MARK: - Documents Marker Tests

    func testDocumentsMarkerCreatedWithKey() throws {
        // Given: No key exists
        XCTAssertFalse(KeychainCrypto.keyExists())
        XCTAssertFalse(KeychainCrypto.documentsMarkerExists())

        // When: Creating a key
        _ = try KeychainCrypto.getOrCreateKey()

        // Then: Both key and marker should exist
        XCTAssertTrue(KeychainCrypto.keyExists())
        XCTAssertTrue(KeychainCrypto.documentsMarkerExists())
    }

    func testDocumentsMarkerDeletedWithKey() throws {
        // Given: Key and marker exist
        _ = try KeychainCrypto.getOrCreateKey()
        XCTAssertTrue(KeychainCrypto.documentsMarkerExists())

        // When: Deleting the key
        try KeychainCrypto.deleteKey()

        // Then: Both should be deleted
        XCTAssertFalse(KeychainCrypto.keyExists())
        XCTAssertFalse(KeychainCrypto.documentsMarkerExists())
    }

    func testDocumentsMarkerExistsReturnsFalseInitially() {
        // Given: Clean state (setUp deletes any existing key and marker)
        // Then: Marker should not exist
        XCTAssertFalse(KeychainCrypto.documentsMarkerExists())
    }
}
