//
//  NoiseKeyCache.swift
//  Bitkit
//
//  X25519 Key Cache for Noise Protocol
//

import Foundation

/// Cache for X25519 Noise protocol keys
public final class NoiseKeyCache {
    
    public static let shared = NoiseKeyCache()
    
    private let keychain: PaykitKeychainStorage
    private var memoryCache: [String: Data] = [:]
    private let cacheQueue = DispatchQueue(label: "to.bitkit.paykit.noise.cache", attributes: .concurrent)
    
    public var maxCachedEpochs: Int = 5
    
    private init() {
        self.keychain = PaykitKeychainStorage()
    }
    
    /// Get a cached key if available
    public func getKey(deviceId: String, epoch: UInt32) -> Data? {
        let key = cacheKey(deviceId: deviceId, epoch: epoch)
        
        // Check memory cache first
        var result: Data?
        cacheQueue.sync {
            result = memoryCache[key]
        }
        
        if let cached = result {
            return cached
        }
        
        // Check persistent cache
        if let keyData = try? keychain.retrieve(key: key) {
            cacheQueue.async(flags: .barrier) {
                self.memoryCache[key] = keyData
            }
            return keyData
        }
        
        return nil
    }
    
    /// Store a key in the cache
    public func setKey(_ keyData: Data, deviceId: String, epoch: UInt32) {
        let key = cacheKey(deviceId: deviceId, epoch: epoch)
        
        // Store in memory cache
        cacheQueue.async(flags: .barrier) {
            self.memoryCache[key] = keyData
        }
        
        // Store in keychain
        try? keychain.store(key: key, data: keyData)
        
        // Cleanup old epochs if needed
        cleanupOldEpochs(deviceId: deviceId, currentEpoch: epoch)
    }
    
    /// Clear all cached keys
    public func clearAll() {
        cacheQueue.async(flags: .barrier) {
            self.memoryCache.removeAll()
        }
    }
    
    // MARK: - Private
    
    private func cacheKey(deviceId: String, epoch: UInt32) -> String {
        return "noise.key.cache.\(deviceId).\(epoch)"
    }
    
    private func cleanupOldEpochs(deviceId: String, currentEpoch: UInt32) {
        // Implementation would clean up old epochs beyond maxCachedEpochs
        // Simplified for now
    }
}

