import CryptoKit
import Foundation

class KeychainCrypto {
    private static var cachedKey: SymmetricKey?
    private static let keyFileName = ".keychain_encryption_key"

    // Network-specific key path (matches existing patterns)
    private static var keyFilePath: URL {
        let networkName = switch Env.network {
        case .bitcoin:
            "bitcoin"
        case .testnet:
            "testnet"
        case .signet:
            "signet"
        case .regtest:
            "regtest"
        }

        return Env.appStorageUrl
            .appendingPathComponent(networkName)
            .appendingPathComponent(keyFileName)
    }

    // Get or create encryption key
    static func getOrCreateKey() throws -> SymmetricKey {
        // Return cached key if available
        if let cached = cachedKey {
            return cached
        }

        // Try to load existing key
        if FileManager.default.fileExists(atPath: keyFilePath.path) {
            let keyData = try Data(contentsOf: keyFilePath)
            let key = SymmetricKey(data: keyData)
            cachedKey = key
            Logger.debug("Loaded encryption key from storage", context: "KeychainCrypto")
            return key
        }

        // Create new key
        let newKey = SymmetricKey(size: .bits256)
        try saveKey(newKey)
        cachedKey = newKey
        Logger.info("Created new encryption key", context: "KeychainCrypto")
        return newKey
    }

    private static func saveKey(_ key: SymmetricKey) throws {
        // Ensure directory exists
        let directory = keyFilePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Save key data with file protection
        let keyData = key.withUnsafeBytes { Data($0) }
        try keyData.write(to: keyFilePath, options: .completeFileProtection)

        Logger.debug("Saved encryption key to \(keyFilePath.path)", context: "KeychainCrypto")
    }

    // Check if key exists
    static func keyExists() -> Bool {
        return FileManager.default.fileExists(atPath: keyFilePath.path)
    }

    // Delete key (used during wipe)
    static func deleteKey() throws {
        if FileManager.default.fileExists(atPath: keyFilePath.path) {
            try FileManager.default.removeItem(at: keyFilePath)
            cachedKey = nil
            Logger.info("Deleted encryption key", context: "KeychainCrypto")
        }
    }

    // Encrypt data before keychain storage
    static func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealedBox = try AES.GCM.seal(data, using: key)

        // Combine nonce + ciphertext + tag into single Data blob
        var combined = Data()
        combined.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        combined.append(sealedBox.ciphertext)
        combined.append(sealedBox.tag)

        Logger.debug("Encrypted data (\(data.count) bytes → \(combined.count) bytes)", context: "KeychainCrypto")
        return combined
    }

    // Decrypt data after keychain retrieval
    static func decrypt(_ encryptedData: Data) throws -> Data {
        let key = try getOrCreateKey()

        // Extract components (nonce=12 bytes, tag=16 bytes, rest=ciphertext)
        guard encryptedData.count >= 28 else { // 12 + 16 minimum
            Logger.error("Invalid encrypted data: too short (\(encryptedData.count) bytes)", context: "KeychainCrypto")
            throw KeychainCryptoError.invalidEncryptedData
        }

        let nonceData = encryptedData.prefix(12)
        let tagData = encryptedData.suffix(16)
        let ciphertextData = encryptedData.dropFirst(12).dropLast(16)

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)

            Logger.debug("Decrypted data (\(encryptedData.count) bytes → \(decryptedData.count) bytes)", context: "KeychainCrypto")
            return decryptedData
        } catch {
            Logger.error("Decryption failed: \(error.localizedDescription)", context: "KeychainCrypto")
            throw KeychainCryptoError.decryptionFailed
        }
    }

    enum KeychainCryptoError: Error {
        case invalidEncryptedData
        case keyNotFound
        case decryptionFailed
    }
}
