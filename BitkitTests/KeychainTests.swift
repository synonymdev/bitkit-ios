@testable import Bitkit
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
            kSecAttrAccount as String: Keychain.account(for: .bip39Mnemonic(index: 0)),
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

        // Verify accessibility is set to AfterFirstUnlockThisDeviceOnly
        // This allows notification extension access while still being device-only (no iCloud sync)
        if let accessible = attributes[kSecAttrAccessible as String] as? String {
            XCTAssertEqual(
                accessible,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                "Keychain items should use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
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
            kSecAttrAccount as String: Keychain.account(for: .securityPin),
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
            XCTAssertEqual(
                accessible,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
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

        // Check all keys are saved correctly by verifying their values
        for i in 0 ... 5 {
            XCTAssertEqual(try Keychain.loadString(key: .bip39Mnemonic(index: i)), "\(testMnemonic) index\(i)")
            XCTAssertEqual(try Keychain.loadString(key: .bip39Passphrase(index: i)), "\(testPassphrase) index\(i)")
        }

        // Wipe
        try Keychain.wipeEntireKeychain()

        // Check all our keys are gone (using exists() which respects access group)
        for i in 0 ... 5 {
            XCTAssertFalse((try? Keychain.exists(key: .bip39Mnemonic(index: i))) ?? false)
            XCTAssertFalse((try? Keychain.exists(key: .bip39Passphrase(index: i))) ?? false)
        }
    }

    func testWipeRetainingKeepsListedEntriesAndRemovesOthers() throws {
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: "test mnemonic")
        try Keychain.saveString(key: .securityPin, str: "1234")
        try Keychain.saveString(key: .pinFailedAttempts, str: "1")

        try Keychain.wipeEntireKeychain(retaining: [.securityPin, .pinFailedAttempts])

        XCTAssertFalse(try Keychain.exists(key: .bip39Mnemonic(index: 0)))
        XCTAssertEqual(try Keychain.loadString(key: .securityPin), "1234")
        XCTAssertEqual(try Keychain.loadString(key: .pinFailedAttempts), "1")
    }

    /// The wipe must leave accounts outside the unit-test namespace alone, or running this suite deletes
    /// the wallet on the simulator it runs against. The probe uses a unique account name rather than a
    /// real key like `bip39_mnemonic_0`: on a simulator with a wallet that name is already taken, and
    /// cleaning it up would delete the real seed.
    func testWipeLeavesAccountsOutsideTheTestNamespace() throws {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "wipe-guard-probe-\(UUID().uuidString)",
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        var item = probe
        item[kSecValueData as String] = Data("probe".utf8)
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess, "Failed to plant the probe account")
        addTeardownBlock { SecItemDelete(probe as CFDictionary) }

        try Keychain.wipeEntireKeychain()

        XCTAssertEqual(
            SecItemCopyMatching(probe as CFDictionary, nil),
            errSecSuccess,
            "wipeEntireKeychain deleted an account outside the unit-test namespace"
        )
    }

    // Regression: a wipe deleted in listing order and never checked the seed was gone, so a failed delete could leave the seed
    // on the device with its PIN already removed
    func testAWipeStopsBeforeThePinWhileASeedRemains() {
        let pin = Keychain.account(for: .securityPin)
        let mnemonic = Keychain.account(for: .bip39Mnemonic(index: 0))
        let passphrase = Keychain.account(for: .bip39Passphrase(index: 0))
        let pushKey = Keychain.account(for: .pushNotificationPrivateKey)

        var deleted: [String] = []
        XCTAssertThrowsError(try Keychain.wipe(
            accounts: [pin, mnemonic, pushKey, passphrase],
            retaining: [],
            delete: { account in
                deleted.append(account)
                return account == mnemonic ? errSecInteractionNotAllowed : errSecSuccess
            },
            remainingAccounts: { [pin, mnemonic, pushKey] }
        ))
        XCTAssertEqual(Set(deleted), [mnemonic, passphrase], "nothing else is deleted while a seed delete failed")

        deleted = []
        XCTAssertThrowsError(try Keychain.wipe(
            accounts: [pin, mnemonic, pushKey],
            retaining: [],
            delete: { deleted.append($0); return errSecSuccess },
            remainingAccounts: { [pin, mnemonic, pushKey] }
        ))
        XCTAssertEqual(deleted, [mnemonic], "a seed the keychain still lists is not taken as gone")

        deleted = []
        struct ListingFailure: Error {}
        XCTAssertThrowsError(try Keychain.wipe(
            accounts: [pin, mnemonic],
            retaining: [],
            delete: { deleted.append($0); return errSecSuccess },
            remainingAccounts: { throw ListingFailure() }
        ))
        XCTAssertEqual(deleted, [mnemonic], "an unreadable keychain is not proof the seed is gone")
    }

    func testAWipeDeletesTheSeedsFirstThenTheRestButNotTheRetained() throws {
        let pin = Keychain.account(for: .securityPin)
        let mnemonic = Keychain.account(for: .bip39Mnemonic(index: 0))
        let pushKey = Keychain.account(for: .pushNotificationPrivateKey)
        var stored: Set = [pin, mnemonic, pushKey]
        var deleted: [String] = []

        try Keychain.wipe(
            accounts: [pushKey, pin, mnemonic],
            retaining: [pin],
            delete: { account in
                deleted.append(account)
                stored.remove(account)
                return errSecSuccess
            },
            remainingAccounts: { Array(stored) }
        )

        XCTAssertEqual(deleted, [mnemonic, pushKey])
        XCTAssertEqual(stored, [pin])
    }

    func testUpsertInsertsThenReplacesTheValue() throws {
        try Keychain.upsert(key: .pushNotificationPrivateKey, data: Data("first".utf8))
        XCTAssertEqual(try Keychain.loadString(key: .pushNotificationPrivateKey), "first")

        try Keychain.upsert(key: .pushNotificationPrivateKey, data: Data("second".utf8))
        XCTAssertEqual(try Keychain.loadString(key: .pushNotificationPrivateKey), "second")
        XCTAssertThrowsError(try Keychain.saveString(key: .pushNotificationPrivateKey, str: "third")) { error in
            XCTAssertEqual(error as? KeychainError, .failedToSaveAlreadyExists)
        }
    }
}
