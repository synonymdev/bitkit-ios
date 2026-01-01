import CryptoKit
import Foundation
import secp256k1

class Crypto {
    struct KeyPair {
        let privateKey: Data
        let publicKey: Data
    }

    struct EncryptedPayload {
        let cipher: Data
        let iv: Data
        let tag: Data
    }

    private static func stringToBytes(_ val: String) -> [UInt8] {
        var result: [UInt8] = []
        for char in val.utf8 {
            result.append(char)
        }
        return result
    }

    static func generateSharedSecret(privateKey: Data, nodePubkey: String, derivationName: String? = nil) throws -> Data {
        let privateKey = try secp256k1.KeyAgreement.PrivateKey(dataRepresentation: privateKey.bytes)

        let publicKey = try secp256k1.KeyAgreement.PublicKey(dataRepresentation: nodePubkey.hexaBytes)

        let baseSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey, format: .compressed).bytes

        if let derivationName {
            let bytes = stringToBytes(derivationName)
            let merged = baseSecret + bytes

            return try Data(dsha256(merged))
        }

        return Data(baseSecret)
    }

    static func generateKeyPair() throws -> KeyPair {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else {
            throw CryptoError.contextCreationFailed
        }
        defer { secp256k1_context_destroy(context) }

        var privateKey = [UInt8](repeating: 0, count: 32)
        repeat {
            guard SecRandomCopyBytes(kSecRandomDefault, privateKey.count, &privateKey) == errSecSuccess else {
                throw CryptoError.randomGenerationFailed
            }
        } while secp256k1_ec_seckey_verify(context, privateKey) != 1

        var publicKey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(context, &publicKey, privateKey) == 1 else {
            throw CryptoError.publicKeyCreationFailed
        }

        var serializedPubKey = [UInt8](repeating: 0, count: 33)
        var outputLen = 33
        guard secp256k1_ec_pubkey_serialize(context, &serializedPubKey, &outputLen, &publicKey, UInt32(SECP256K1_EC_COMPRESSED)) == 1 else {
            throw CryptoError.publicKeySerializationFailed
        }

        return KeyPair(privateKey: Data(privateKey), publicKey: Data(serializedPubKey))
    }

    static func encrypt(_ blob: Data, secretKey: Data) throws -> EncryptedPayload {
        let key = SymmetricKey(data: secretKey)

        let sealedBox = try AES.GCM.seal(blob, using: key)

        return .init(
            cipher: sealedBox.ciphertext,
            iv: sealedBox.nonce.withUnsafeBytes { Data($0) },
            tag: sealedBox.tag
        )
    }

    static func decrypt(_ payload: EncryptedPayload, secretKey: Data) throws -> Data {
        let key = SymmetricKey(data: secretKey)

        do {
            let nonce = try AES.GCM.Nonce(data: payload.iv)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.cipher, tag: payload.tag)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)

            return decryptedData
        } catch {
            if let ce = error as? CryptoKit.CryptoKitError {
                Logger.warn(ce)
                throw CryptoError.decryptionFailed
            } else {
                throw error
            }
        }
    }

    static func dsha256(_ data: [UInt8]) throws -> [UInt8] {
        let sha256 = SHA256.hash(data: Data(data))
        return SHA256.hash(data: Data(sha256)).bytes
    }

    /// Sign using Lightning Network message signing format
    static func sign(message: String, privateKey: Data) throws -> String {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else {
            throw CryptoError.contextCreationFailed
        }
        defer { secp256k1_context_destroy(context) }

        let lightningPrefix = "Lightning Signed Message:"
        let prefixedMessage = lightningPrefix + message
        let hash1 = SHA256.hash(data: Data(prefixedMessage.utf8))
        let messageHash = SHA256.hash(data: Data(hash1))

        var signature = secp256k1_ecdsa_recoverable_signature()

        let result = messageHash.withUnsafeBytes { hashPtr in
            privateKey.withUnsafeBytes { keyPtr in
                secp256k1_ecdsa_sign_recoverable(
                    context,
                    &signature,
                    hashPtr.bindMemory(to: UInt8.self).baseAddress!,
                    keyPtr.bindMemory(to: UInt8.self).baseAddress!,
                    nil,
                    nil
                )
            }
        }

        guard result == 1 else {
            throw CryptoError.signingFailed
        }

        var output = [UInt8](repeating: 0, count: 64)
        var recId: Int32 = 0
        secp256k1_ecdsa_recoverable_signature_serialize_compact(context, &output, &recId, &signature)

        let recIdByte = UInt8(recId + 31)
        var fullSig = [recIdByte]
        fullSig.append(contentsOf: output)
        return Data(fullSig).hex
    }

    static func getPublicKey(privateKey: Data) throws -> Data {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else {
            throw CryptoError.contextCreationFailed
        }
        defer { secp256k1_context_destroy(context) }

        var publicKey = secp256k1_pubkey()
        let createResult = privateKey.withUnsafeBytes { keyPtr in
            secp256k1_ec_pubkey_create(
                context,
                &publicKey,
                keyPtr.bindMemory(to: UInt8.self).baseAddress!
            )
        }

        guard createResult == 1 else {
            throw CryptoError.publicKeyCreationFailed
        }

        var serializedPubKey = [UInt8](repeating: 0, count: 33)
        var outputLen = 33
        guard secp256k1_ec_pubkey_serialize(context, &serializedPubKey, &outputLen, &publicKey, UInt32(SECP256K1_EC_COMPRESSED)) == 1 else {
            throw CryptoError.publicKeySerializationFailed
        }

        return Data(serializedPubKey)
    }

    enum CryptoError: Error {
        case sharedSecretGenerationFailed
        case invalidDerivationName
        case contextCreationFailed
        case invalidPublicKey
        case publicKeyCreationFailed
        case randomGenerationFailed
        case publicKeySerializationFailed
        case decryptionFailed
        case invalidInputData
        case signingFailed
    }
}
