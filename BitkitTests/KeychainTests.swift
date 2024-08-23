//
//  Keychain.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/07/29.
//

import XCTest

final class KeychainTests: XCTestCase {
    override func setUpWithError() throws {
        try Keychain.wipeEntireKeychain()
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testKeychain() throws {
        let testMnemonic = "test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999)) test\(Int.random(in: 0...99999))"
        let testPassphrase = "testpasshrase\(Int.random(in: 0...99999))"
        
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
        for i in 0...5 {
            try Keychain.saveString(key: .bip39Mnemonic(index: i), str: "\(testMnemonic) index\(i)")
            try Keychain.saveString(key: .bip39Passphrase(index: i), str: "\(testPassphrase) index\(i)")
        }
        
        // Check all keys are saved correctly
        let listedKeys = Keychain.getAllKeyChainStorageKeys()
        XCTAssertEqual(listedKeys.count, 12)
        for i in 0...5 {
            XCTAssertTrue(listedKeys.contains("bip39_mnemonic_\(i)"))
            XCTAssertTrue(listedKeys.contains("bip39_passphrase_\(i)"))
        }
        
        // Check each value
        for i in 0...5 {
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
