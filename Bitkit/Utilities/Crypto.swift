//
//  Crypto.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/13.
//

import CryptoKit
import Foundation
import secp256k1

class Crypto {
    static func generateSharedSecret(privateKey: Data, nodePubkey: String, derivationName: String? = nil) throws -> Data {
        let publicKey = nodePubkey.hexaBytes
        
        // Create a secp256k1 context
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)) else {
            throw CryptoError.contextCreationFailed
        }
        defer { secp256k1_context_destroy(context) }
        
        // Parse the public key
        var pubKey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_parse(context, &pubKey, publicKey, publicKey.count) == 1 else {
            throw CryptoError.invalidPublicKey
        }
        
        // Perform the ECDH operation
        var output = [UInt8](repeating: 0, count: 32)
        guard secp256k1_ecdh(context, &output, &pubKey, privateKey.bytes, { output, x, _, _ -> Int32 in
            memcpy(output, x, 32)
            return 1
        }, nil) == 1 else {
            throw CryptoError.sharedSecretGenerationFailed
        }
        
        if derivationName == nil {
            return Data(output)
        }
        
        guard let derivationBytes = derivationName?.data(using: .utf8)?.bytes else {
            throw CryptoError.invalidDerivationName
        }
        
        let mergedArray = output + derivationBytes
        return try Data(dsha256(mergedArray))
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
        
        var serializedPubKey = [UInt8](repeating: 0, count: 33)  // Change to 33 bytes
        var outputLen = 33  // Change to 33
        guard secp256k1_ec_pubkey_serialize(context, &serializedPubKey, &outputLen, &publicKey, UInt32(SECP256K1_EC_COMPRESSED)) == 1 else {
            throw CryptoError.publicKeySerializationFailed
        }
        
        return KeyPair(privateKey: Data(privateKey), publicKey: Data(serializedPubKey))
    }
    
    struct KeyPair {
        let privateKey: Data
        let publicKey: Data
    }

    static func encrypt(_ blob: Data, secretKey: Data) throws -> Data {
        let key = SymmetricKey(data: secretKey)

        let sealedBox = try AES.GCM.seal(blob, using: key)
            
        return sealedBox.combined!
    }
        
    static func decrypt(_ blob: Data, secretKey: Data) throws -> Data {
        let key = SymmetricKey(data: secretKey)
            
        // Remove appended 12 bytes nonce and 16 byte trailing tag
        let encryptedData: Data = {
            var bytes = blob.subdata(in: 12 ..< blob.count)
            let removalRange = bytes.count - 16 ..< bytes.count
            bytes.removeSubrange(removalRange)
            return bytes
        }()
        let nonce = blob.prefix(12)
        let tag = blob.suffix(16)
            
        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: encryptedData, tag: tag)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
                
            return decryptedData
        } catch {
            if let ce = error as? CryptoKit.CryptoKitError {
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
    
    enum CryptoError: Error {
        case sharedSecretGenerationFailed
        case invalidDerivationName
        case contextCreationFailed
        case invalidPublicKey
        case publicKeyCreationFailed
        case randomGenerationFailed
        case publicKeySerializationFailed
        case decryptionFailed
    }
}
