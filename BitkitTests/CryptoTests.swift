//
//  CryptoTests.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/09/13.
//

import XCTest

final class CryptoTests: XCTestCase {
    func testGenerateSharedSecret() throws {
        // Test case 1: Basic shared secret generation
        let keyPair1 = try Crypto.generateKeyPair()
        let keyPair2 = try Crypto.generateKeyPair()

        let sharedSecret1 = try Crypto.generateSharedSecret(privateKey: keyPair1.privateKey, nodePubkey: Data(keyPair2.publicKey).hex)
        XCTAssertEqual(sharedSecret1.count, 32)

        // Test case 2: With derivation name
        let keyPair3 = try Crypto.generateKeyPair()
        let keyPair4 = try Crypto.generateKeyPair()
        let derivationName = "encryption"

        let sharedSecret2 = try Crypto.generateSharedSecret(privateKey: keyPair3.privateKey, nodePubkey: Data(keyPair4.publicKey).hex, derivationName: derivationName)
        XCTAssertEqual(sharedSecret2.count, 32)
        XCTAssertNotEqual(sharedSecret1, sharedSecret2)

        // Test case 3: Invalid public key
        let invalidPubkey = "invalid_pubkey"
        XCTAssertThrowsError(try Crypto.generateSharedSecret(privateKey: keyPair1.privateKey, nodePubkey: invalidPubkey))
    }

    func testEncryptDecryptWithSharedSecret() throws {
        // Generate key pairs
        let aliceKeyPair = try Crypto.generateKeyPair()
        let bobKeyPair = try Crypto.generateKeyPair()

        // Generate shared secrets
        let aliceSharedSecret = try Crypto.generateSharedSecret(privateKey: aliceKeyPair.privateKey, nodePubkey: Data(bobKeyPair.publicKey).hex)
        let bobSharedSecret = try Crypto.generateSharedSecret(privateKey: bobKeyPair.privateKey, nodePubkey: Data(aliceKeyPair.publicKey).hex)

        // Ensure shared secrets are the same
        XCTAssertEqual(aliceSharedSecret, bobSharedSecret)

        // Message to encrypt
        let originalMessage = "Hello, secure world!"
        let messageData = originalMessage.data(using: .utf8)!

        // Encrypt the message using Alice's shared secret
        let encryptedData = try Crypto.encrypt(messageData, secretKey: aliceSharedSecret)

        // Decrypt the message using Bob's shared secret
        let decryptedData = try Crypto.decrypt(encryptedData, secretKey: bobSharedSecret)

        // Convert decrypted data back to string
        let decryptedMessage = String(data: decryptedData, encoding: .utf8)

        // Assert that the decrypted message matches the original
        XCTAssertEqual(decryptedMessage, originalMessage)
    }
}
