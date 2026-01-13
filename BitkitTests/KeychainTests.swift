import Security
import XCTest

final class KeychainTests: XCTestCase {
    override func setUpWithError() throws {
        try Keychain.wipeEntireKeychain()
    }

    override func tearDownWithError() throws {
        try Keychain.wipeEntireKeychain()
    }

    // MARK: - Security Attribute Tests

    func testKeychainSecurityAttributes() throws {
        // Save a test item
        let testValue = "test_mnemonic_for_security_check"
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testValue)

        // Query the item with attributes returned
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainEntryType.bip39Mnemonic(index: 0).storageKey,
            kSecAttrAccessGroup as String: Env.keychainGroup,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess, "Failed to query keychain item")

        guard let attributes = result as? [String: Any] else {
            XCTFail("Failed to get keychain attributes")
            return
        }

        // Verify accessibility is set to WhenUnlockedThisDeviceOnly
        if let accessible = attributes[kSecAttrAccessible as String] as? String {
            XCTAssertEqual(
                accessible,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                "Keychain item should use kSecAttrAccessibleWhenUnlockedThisDeviceOnly"
            )
        } else {
            XCTFail("Could not read kSecAttrAccessible attribute")
        }

        // Verify synchronizable is false (item should not sync to iCloud)
        if let synchronizable = attributes[kSecAttrSynchronizable as String] as? Bool {
            XCTAssertFalse(
                synchronizable,
                "Keychain item should not be synchronizable (kSecAttrSynchronizable should be false)"
            )
        }
        // Note: If synchronizable is nil/missing, that's also acceptable as the default is false
    }

    func testKeychainItemsAreDeviceOnly() throws {
        // This test verifies that keychain items cannot sync to other devices
        // by checking the accessibility attribute

        try Keychain.saveString(key: .securityPin, str: "123456")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainEntryType.securityPin.storageKey,
            kSecAttrAccessGroup as String: Env.keychainGroup,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess)

        guard let attributes = result as? [String: Any] else {
            XCTFail("Failed to get keychain attributes")
            return
        }

        // The "ThisDeviceOnly" suffix means the item won't migrate to a new device
        if let accessible = attributes[kSecAttrAccessible as String] as? String {
            XCTAssertTrue(
                accessible.contains("ThisDeviceOnly") ||
                    accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
                "Keychain items should be device-only (not transferable to other devices)"
            )
        }
    }

    // MARK: - Basic Keychain Tests

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
        XCTAssertEqual(listedKeys.count, 12)
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

        // Check all keys are gone
        let listedKeysAfterWipe = Keychain.getAllKeyChainStorageKeys()
        XCTAssertEqual(listedKeysAfterWipe.count, 0)
    }
}
