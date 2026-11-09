import CryptoKit
import Foundation
import libsecp256k1

/// ECDH output: the shared point serialized as a 33-byte compressed key (no hashing).
private let compressedPointHash: secp256k1_ecdh_hash_function = { output, x32, y32, _ in
    guard let output, let x32, let y32 else { return 0 }
    output[0] = 0x02 | (y32[31] & 1)
    (output + 1).update(from: x32, count: 32)
    return 1
}

class Crypto {
    private static let privateKeyLength = 32
    private static let compressedPublicKeyLength = 33

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
        guard privateKey.count == privateKeyLength else {
            throw CryptoError.invalidPrivateKey
        }

        let publicKeyBytes = nodePubkey.hexaBytes
        guard publicKeyBytes.count == compressedPublicKeyLength else {
            throw CryptoError.invalidPublicKey
        }

        let context = try SharedContext.shared.get()

        var publicKey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_parse(context, &publicKey, publicKeyBytes, publicKeyBytes.count) == 1 else {
            throw CryptoError.invalidPublicKey
        }

        var baseSecret = [UInt8](repeating: 0, count: compressedPublicKeyLength)
        defer { zeroize(&baseSecret) }
        let result = privateKey.withUnsafeBytes { keyPtr in
            secp256k1_ecdh(
                context,
                &baseSecret,
                &publicKey,
                keyPtr.bindMemory(to: UInt8.self).baseAddress!,
                compressedPointHash,
                nil
            )
        }

        // 0 means the private key is zero or not below the curve order.
        guard result == 1 else {
            throw CryptoError.sharedSecretGenerationFailed
        }

        if let derivationName {
            let bytes = stringToBytes(derivationName)
            var merged = baseSecret + bytes
            defer { zeroize(&merged) }

            return try Data(dsha256(merged))
        }

        return Data(baseSecret)
    }

    /// One libsecp256k1 context for the process, randomized once at creation to blind secret-key
    /// operations (signing, public key creation) against side-channel leakage. Upstream allows
    /// concurrent use without locking as long as the context is never randomized again or destroyed.
    private final class SharedContext: @unchecked Sendable {
        static let shared = SharedContext()

        private let lock = NSLock()
        private var context: OpaquePointer?

        func get() throws -> OpaquePointer {
            lock.lock()
            defer { lock.unlock() }

            if let context {
                return context
            }

            guard let created = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
                throw CryptoError.contextCreationFailed
            }

            var seed = [UInt8](repeating: 0, count: 32)
            defer { Crypto.zeroize(&seed) }

            guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess else {
                secp256k1_context_destroy(created)
                throw CryptoError.randomGenerationFailed
            }

            guard secp256k1_context_randomize(created, seed) == 1 else {
                secp256k1_context_destroy(created)
                throw CryptoError.contextRandomizationFailed
            }

            context = created
            return created
        }
    }

    private static func zeroize(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }

    static func generateKeyPair() throws -> KeyPair {
        let context = try SharedContext.shared.get()

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
            return try AES.GCM.open(sealedBox, using: key)
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
        guard privateKey.count == privateKeyLength else {
            throw CryptoError.invalidPrivateKey
        }

        let context = try SharedContext.shared.get()

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
        guard privateKey.count == privateKeyLength else {
            throw CryptoError.invalidPrivateKey
        }

        let context = try SharedContext.shared.get()

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
        case contextRandomizationFailed
        case invalidPublicKey
        case invalidPrivateKey
        case publicKeyCreationFailed
        case randomGenerationFailed
        case publicKeySerializationFailed
        case decryptionFailed
        case invalidInputData
        case signingFailed
    }
}
