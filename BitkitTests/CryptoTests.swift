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
        XCTAssertEqual(sharedSecret1.count, 33)

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
        let aliceSharedSecret = try Crypto.generateSharedSecret(privateKey: aliceKeyPair.privateKey, nodePubkey: Data(bobKeyPair.publicKey).hex, derivationName: "random123")
        let bobSharedSecret = try Crypto.generateSharedSecret(privateKey: bobKeyPair.privateKey, nodePubkey: Data(aliceKeyPair.publicKey).hex, derivationName: "random123")

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

    func testBlocktankEncryptedPayload() throws {
        let cipher = "1kGoUrkQN8yymc8JWMBsn0g3oS4DJtY4cUESuRi6HOMohJEjT7and62SWPKoINI0p+gIc8LbHAVz8vQdNiS7cNhUXfaWDB+ytVMmMVnlo8ky9vk90pUt/V7ToDBEf5MjFop3DQsPUQsh2LL/zNaJjpEb12v6aKg="
        let iv = "4f44c8f4d22f69c3d64b4c33e29a16e4"
        let publicKey = "0234957d95b9716774faed99ad84bc6994abe5b29b259bfb4015abc013d28c1a1d"
        let tag = "68696bbf002589ea833dd151f128cb6b"
        let derivationName = "bitkit-notifications"

        let clientPublicKey = "0395504daf41d6aa6e0b13a30f52793201bb3e132cbefb232022267f549b0219d4"
        let clientPrivateKey = "5cbf2390a02a21df211d0a6480e187e60b8b089f1a7648abf6b312cc48480401"

        guard let ciphertext = Data(base64Encoded: cipher) else {
            XCTFail("Failed to decode cipher")
            return
        }

        // Without derivationName
        let sharedSecret = try Crypto.generateSharedSecret(privateKey: clientPrivateKey.hexaData, nodePubkey: publicKey)
        XCTAssertEqual("03c027f7d82611ab64bc4f3e9be4137fec80fc506aefe7ec63327b99e6b56d62a0", sharedSecret.hex)

        let sharedSecret2 = try Crypto.generateSharedSecret(privateKey: clientPrivateKey.hexaData, nodePubkey: publicKey, derivationName: derivationName)
        XCTAssertEqual("12fc8324f541348ffb033884a88838e102c6d14018f55e0682e6be1180befdd6", sharedSecret2.hex)

        let encryptedPayload = Crypto.EncryptedPayload(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData)

        let value = try Crypto.decrypt(encryptedPayload, secretKey: sharedSecret2)

        XCTAssertEqual(String(data: value, encoding: .utf8), "{\"source\":\"blocktank\",\"type\":\"incomingHtlc\",\"payload\":{\"secretMessage\":\"hello\"},\"createdAt\":\"2024-09-13T14:20:09.429Z\"}")
    }
}
