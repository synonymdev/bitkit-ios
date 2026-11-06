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

        let sharedSecret2 = try Crypto.generateSharedSecret(
            privateKey: keyPair3.privateKey, nodePubkey: Data(keyPair4.publicKey).hex, derivationName: derivationName
        )
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
        let aliceSharedSecret = try Crypto.generateSharedSecret(
            privateKey: aliceKeyPair.privateKey, nodePubkey: Data(bobKeyPair.publicKey).hex, derivationName: "random123"
        )
        let bobSharedSecret = try Crypto.generateSharedSecret(
            privateKey: bobKeyPair.privateKey, nodePubkey: Data(aliceKeyPair.publicKey).hex, derivationName: "random123"
        )

        // Ensure shared secrets are the same
        XCTAssertEqual(aliceSharedSecret, bobSharedSecret)

        // Message to encrypt
        let originalMessage = "Hello, secure world!"
        let messageData = try XCTUnwrap(originalMessage.data(using: .utf8))

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
        let cipher =
            "l2fInfyw64gO12odo8iipISloQJ45Rc4WjFmpe95brdaAMDq+T/L9ZChcmMCXnR0J6BXd8sSIJe/0bmby8uSZZJuVCzwF76XHfY5oq0Y1/hKzyZTn8nG3dqfiLHnAPy1tZFQfm5ALgjwWnViYJLXoGFpXs7kLMA="
        let iv = "2b8ed77fd2198e3ed88cfaa794a246e8"
        let serverPublicKey = "031e9923e689a181a803486b7d8c0d4a5aad360edb70c8bb413a98458d91652213"
        let tag = "caddd13746d6a6aed16176734964d3a3"
        let derivationName = "bitkit-notifications"
        let decryptedPayload =
            "{\"source\":\"blocktank\",\"type\":\"incomingHtlc\",\"payload\":{\"secretMessage\":\"hello\"},\"createdAt\":\"2024-09-18T13:33:52.555Z\"}"

        let clientPrivateKey = "cc74b1a4fdcd35916c766d3318c5a93b7e33a36ebeff0463128bf284975c2680"

        guard let ciphertext = Data(base64Encoded: cipher) else {
            XCTFail("Failed to decode cipher")
            return
        }

        // Without derivationName
        let sharedSecret = try Crypto.generateSharedSecret(privateKey: clientPrivateKey.hexaData, nodePubkey: serverPublicKey)
        XCTAssertEqual("028ce542975d6d7b2307c92e527d507b03ffb3d897eb2e0830d29f40d5efd80ee3", sharedSecret.hex)

        let sharedSecret2 = try Crypto.generateSharedSecret(
            privateKey: clientPrivateKey.hexaData, nodePubkey: serverPublicKey, derivationName: derivationName
        )
        XCTAssertEqual("3a9d552cb16dfae40feae644254c4ca46cab82e570de5662aacc4018e33b609b", sharedSecret2.hex)

        let encryptedPayload = Crypto.EncryptedPayload(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData)

        let value = try Crypto.decrypt(encryptedPayload, secretKey: sharedSecret2)

        XCTAssertEqual(String(data: value, encoding: .utf8), decryptedPayload)
    }

    /// Expected values computed with an independent secp256k1 implementation (RFC 6979 nonces, low-S).
    func testGetPublicKeyMatchesReferenceVector() throws {
        let privateKey = "cc74b1a4fdcd35916c766d3318c5a93b7e33a36ebeff0463128bf284975c2680".hexaData
        let publicKey = try Crypto.getPublicKey(privateKey: privateKey)
        XCTAssertEqual(publicKey.hex, "02f7c231fe139475b8193194b42043ae546768167e5cf836f5a4063f5d448a127f")
    }

    func testSignMatchesReferenceVector() throws {
        let privateKey = "cc74b1a4fdcd35916c766d3318c5a93b7e33a36ebeff0463128bf284975c2680".hexaData
        let signature = try Crypto.sign(message: "hello bitkit", privateKey: privateKey)
        XCTAssertEqual(
            signature,
            "204b84a4bfc77965c2ea561930829fca5a05610027d3591268e13f4e0cbb65aea2176f20bd78ca453a23214323ac1a6df88045f71b40f2e9dadab360743606a655"
        )
    }

    func testGenerateKeyPairPublicKeyMatchesPrivateKey() throws {
        let keyPair = try Crypto.generateKeyPair()
        XCTAssertEqual(keyPair.privateKey.count, 32)
        XCTAssertEqual(keyPair.publicKey.count, 33)
        XCTAssertEqual(try Crypto.getPublicKey(privateKey: keyPair.privateKey), keyPair.publicKey)
    }

    // MARK: - Input validation (regression: sign/getPublicKey read past the end of short keys)

    private static let validPrivateKey = "cc74b1a4fdcd35916c766d3318c5a93b7e33a36ebeff0463128bf284975c2680".hexaData
    private static let validPublicKey = "031e9923e689a181a803486b7d8c0d4a5aad360edb70c8bb413a98458d91652213"
    private static let curveOrder = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141".hexaData

    private func assertThrows(
        _ expected: Crypto.CryptoError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> some Any
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let error = error as? Crypto.CryptoError, error == expected else {
                return XCTFail("Expected \(expected), got \(error)", file: file, line: line)
            }
        }
    }

    func testSignRejectsPrivateKeyOfWrongLength() {
        for length in [0, 1, 31, 33, 64] {
            assertThrows(.invalidPrivateKey) { try Crypto.sign(message: "hello", privateKey: Data(repeating: 1, count: length)) }
        }
    }

    func testSignRejectsOutOfRangePrivateKey() {
        assertThrows(.signingFailed) { try Crypto.sign(message: "hello", privateKey: Data(repeating: 0, count: 32)) }
        assertThrows(.signingFailed) { try Crypto.sign(message: "hello", privateKey: Self.curveOrder) }
    }

    func testGetPublicKeyRejectsPrivateKeyOfWrongLength() {
        for length in [0, 1, 31, 33, 64] {
            assertThrows(.invalidPrivateKey) { try Crypto.getPublicKey(privateKey: Data(repeating: 1, count: length)) }
        }
    }

    func testGetPublicKeyRejectsOutOfRangePrivateKey() {
        assertThrows(.publicKeyCreationFailed) { try Crypto.getPublicKey(privateKey: Data(repeating: 0, count: 32)) }
        assertThrows(.publicKeyCreationFailed) { try Crypto.getPublicKey(privateKey: Self.curveOrder) }
    }

    func testGenerateSharedSecretRejectsPrivateKeyOfWrongLength() {
        for length in [0, 1, 31, 33, 64] {
            assertThrows(.invalidPrivateKey) {
                try Crypto.generateSharedSecret(privateKey: Data(repeating: 1, count: length), nodePubkey: Self.validPublicKey)
            }
        }
    }

    func testGenerateSharedSecretRejectsOutOfRangePrivateKey() {
        assertThrows(.sharedSecretGenerationFailed) {
            try Crypto.generateSharedSecret(privateKey: Data(repeating: 0, count: 32), nodePubkey: Self.validPublicKey)
        }
        assertThrows(.sharedSecretGenerationFailed) {
            try Crypto.generateSharedSecret(privateKey: Self.curveOrder, nodePubkey: Self.validPublicKey)
        }
    }

    func testGenerateSharedSecretRejectsInvalidPublicKeys() throws {
        let compressedHex = try Crypto.getPublicKey(privateKey: Self.validPrivateKey).hex
        let xCoordinate = String(compressedHex.dropFirst(2))
        let offCurveX = String(repeating: "0", count: 63) + "5" // x = 5 has no y on secp256k1

        let invalid = [
            "",
            String(Self.validPublicKey.dropLast(2)), // 32 bytes
            Self.validPublicKey + "00", // 34 bytes
            "04" + xCoordinate + xCoordinate, // 65 bytes: only compressed keys are accepted
            "04" + xCoordinate, // uncompressed prefix on 33 bytes
            "05" + xCoordinate, // unknown prefix
            "02" + offCurveX,
            "02" + String(repeating: "f", count: 64), // x >= field prime
        ]
        for pubkey in invalid {
            assertThrows(.invalidPublicKey) { try Crypto.generateSharedSecret(privateKey: Self.validPrivateKey, nodePubkey: pubkey) }
        }
    }
}
