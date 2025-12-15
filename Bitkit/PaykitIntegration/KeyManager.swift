//
//  KeyManager.swift
//  Bitkit
//
//  Manages Ed25519 identity keys and X25519 device keys for Paykit
//  Uses Bitkit's Keychain for secure storage
//

import Foundation
import PaykitMobile

/// Manages Ed25519 identity keys and X25519 device keys for Paykit
public final class PaykitKeyManager {
    
    public static let shared = PaykitKeyManager()
    
    private let keychain: PaykitKeychainStorage
    
    private enum Keys {
        static let secretKey = "paykit.identity.secret"
        static let publicKey = "paykit.identity.public"
        static let publicKeyZ32 = "paykit.identity.public.z32"
        static let deviceId = "paykit.device.id"
        static let epoch = "paykit.device.epoch"
    }
    
    private var deviceId: String {
        if let existing = keychain.retrieve(key: Keys.deviceId) {
            return String(data: existing, encoding: .utf8) ?? generateDeviceId()
        }
        let newId = generateDeviceId()
        try? keychain.store(key: Keys.deviceId, data: newId.data(using: .utf8)!)
        return newId
    }
    
    private var currentEpoch: UInt32 {
        if let epochData = keychain.retrieve(key: Keys.epoch),
           let epochStr = String(data: epochData, encoding: .utf8),
           let epoch = UInt32(epochStr) {
            return epoch
        }
        return 0
    }
    
    private init() {
        self.keychain = PaykitKeychainStorage()
    }
    
    /// Get or create Ed25519 identity
    public func getOrCreateIdentity() async throws -> Ed25519Keypair {
        if let secretData = keychain.retrieve(key: Keys.secretKey),
           let secretHex = String(data: secretData, encoding: .utf8) {
            return try ed25519KeypairFromSecret(secretKeyHex: secretHex)
        }
        return try await generateNewIdentity()
    }
    
    /// Generate a new Ed25519 identity
    public func generateNewIdentity() async throws -> Ed25519Keypair {
        let keypair = try generateEd25519Keypair()
        
        // Store in keychain
        try keychain.store(key: Keys.secretKey, data: keypair.secretKeyHex.data(using: .utf8)!)
        try keychain.store(key: Keys.publicKey, data: keypair.publicKeyHex.data(using: .utf8)!)
        try keychain.store(key: Keys.publicKeyZ32, data: keypair.publicKeyZ32.data(using: .utf8)!)
        
        return keypair
    }
    
    /// Get current public key in z-base32 format
    public func getCurrentPublicKeyZ32() -> String? {
        guard let data = keychain.retrieve(key: Keys.publicKeyZ32),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Get current secret key hex
    public func getSecretKeyHex() -> String? {
        guard let data = keychain.retrieve(key: Keys.secretKey),
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }
    
    /// Get secret key as bytes
    public func getSecretKeyBytes() -> Data? {
        guard let hex = getSecretKeyHex() else { return nil }
        return Data(hex: hex)
    }
    
    /// Derive X25519 keypair for Noise protocol
    public func deriveX25519Keypair(epoch: UInt32? = nil) async throws -> X25519Keypair {
        let secretHex = getSecretKeyHex() ?? throw PaykitKeyError.noIdentity
        let deviceId = self.deviceId
        let epoch = epoch ?? currentEpoch
        
        return try deriveX25519Keypair(
            ed25519SecretHex: secretHex,
            deviceId: deviceId,
            epoch: epoch
        )
    }
    
    /// Get device ID
    public func getDeviceId() -> String {
        return deviceId
    }
    
    /// Get current epoch
    public func getCurrentEpoch() -> UInt32 {
        return currentEpoch
    }
    
    /// Rotate keys by incrementing epoch
    public func rotateKeys() async throws {
        let newEpoch = currentEpoch + 1
        try keychain.store(key: Keys.epoch, data: String(newEpoch).data(using: .utf8)!)
    }
    
    /// Delete identity
    public func deleteIdentity() throws {
        try? keychain.delete(key: Keys.secretKey)
        try? keychain.delete(key: Keys.publicKey)
        try? keychain.delete(key: Keys.publicKeyZ32)
    }
    
    // MARK: - Private
    
    private func generateDeviceId() -> String {
        return UUID().uuidString
    }
}

enum PaykitKeyError: LocalizedError {
    case noIdentity
    
    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured. Please set up your identity first."
        }
    }
}

// Helper extension for Data hex conversion
extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var i = hex.startIndex
        for _ in 0..<len {
            let j = hex.index(i, offsetBy: 2)
            let bytes = hex[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}

