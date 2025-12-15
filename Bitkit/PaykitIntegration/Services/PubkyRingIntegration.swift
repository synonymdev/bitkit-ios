//
//  PubkyRingIntegration.swift
//  Bitkit
//
//  Pubky Ring Integration for key derivation
//  Uses PaykitMobile FFI to derive X25519 keys from Ed25519 identity
//

import Foundation
import PaykitMobile

/// Integration for X25519 key derivation from Ed25519 identity
/// Uses PaykitMobile FFI to derive keys deterministically from identity seed
public final class PubkyRingIntegration {
    
    public static let shared = PubkyRingIntegration()
    
    private let keyManager: PaykitKeyManager
    private let noiseKeyCache: NoiseKeyCache
    
    private init() {
        self.keyManager = PaykitKeyManager.shared
        self.noiseKeyCache = NoiseKeyCache.shared
    }
    
    /// Get or derive X25519 keypair with caching
    /// This method first checks the NoiseKeyCache, then requests from
    /// PaykitMobile FFI if not cached.
    public func getOrDeriveKeypair(deviceId: String, epoch: UInt32) async throws -> X25519Keypair {
        // Check cache first
        if let cached = noiseKeyCache.getKey(deviceId: deviceId, epoch: epoch) {
            // Reconstruct keypair from cached secret
            // Note: We need the public key, so we'll derive again
            // In production, cache could store full keypair
        }
        
        // Derive via PaykitMobile FFI
        guard let ed25519SecretHex = keyManager.getSecretKeyHex() else {
            throw PaykitRingError.noIdentity("No Ed25519 identity configured in Bitkit.")
        }
        
        let keypair = try deriveX25519Keypair(
            ed25519SecretHex: ed25519SecretHex,
            deviceId: deviceId,
            epoch: epoch
        )
        
        // Cache the secret key bytes
        if let secretBytes = Data(hex: keypair.secretKeyHex) {
            noiseKeyCache.setKey(secretBytes, deviceId: deviceId, epoch: epoch)
        }
        
        return keypair
    }
}

enum PaykitRingError: LocalizedError {
    case noIdentity(String)
    case derivationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noIdentity(let msg):
            return msg
        case .derivationFailed(let msg):
            return "Failed to derive X25519 keypair: \(msg)"
        }
    }
}

