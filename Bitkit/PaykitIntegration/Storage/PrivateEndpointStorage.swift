//
//  PrivateEndpointStorage.swift
//  Bitkit
//
//  Persistent storage for private endpoints using Keychain.
//

import Foundation
import PaykitMobile

/// Manages persistent storage of private payment endpoints
public class PrivateEndpointStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    // In-memory cache
    private var endpointsCache: [String: [PrivateEndpointOffer]]?
    
    private var endpointsKey: String {
        "paykit.private_endpoints.\(identityName)"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - CRUD Operations
    
    /// Get all private endpoints for a peer
    public func listForPeer(_ peerPubkey: String) -> [PrivateEndpointOffer] {
        let all = loadAllEndpoints()
        return all[peerPubkey] ?? []
    }
    
    /// Get a specific endpoint for a peer and method
    public func get(peerPubkey: String, methodId: String) -> PrivateEndpointOffer? {
        let endpoints = listForPeer(peerPubkey)
        return endpoints.first { $0.methodId == methodId }
    }
    
    /// Save a private endpoint
    public func save(_ endpoint: PrivateEndpointOffer, forPeer peerPubkey: String) throws {
        var all = loadAllEndpoints()
        
        // Get or create list for this peer
        var peerEndpoints = all[peerPubkey] ?? []
        
        // Remove existing endpoint for this method if it exists
        peerEndpoints.removeAll { $0.methodId == endpoint.methodId }
        
        // Add the new endpoint
        peerEndpoints.append(endpoint)
        
        // Update the dictionary
        all[peerPubkey] = peerEndpoints
        
        try persistAllEndpoints(all)
    }
    
    /// Remove a specific endpoint
    public func remove(peerPubkey: String, methodId: String) throws {
        var all = loadAllEndpoints()
        
        guard var peerEndpoints = all[peerPubkey] else {
            return // Nothing to remove
        }
        
        peerEndpoints.removeAll { $0.methodId == methodId }
        
        if peerEndpoints.isEmpty {
            all.removeValue(forKey: peerPubkey)
        } else {
            all[peerPubkey] = peerEndpoints
        }
        
        try persistAllEndpoints(all)
    }
    
    /// Clear all endpoints for a peer
    public func clearForPeer(_ peerPubkey: String) throws {
        var all = loadAllEndpoints()
        all.removeValue(forKey: peerPubkey)
        try persistAllEndpoints(all)
    }
    
    /// Clear all endpoints
    public func clearAll() throws {
        try persistAllEndpoints([:])
    }
    
    /// List all peers with stored endpoints
    public func listPeers() -> [String] {
        return Array(loadAllEndpoints().keys)
    }
    
    // MARK: - Private
    
    private func loadAllEndpoints() -> [String: [PrivateEndpointOffer]] {
        if let cached = endpointsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: endpointsKey) else {
                return [:]
            }
            
            // PrivateEndpointOffer is from PaykitMobile, we need to encode/decode it
            // Since it's a struct from FFI, we'll store it as a dictionary representation
            let dict = try JSONDecoder().decode([String: [[String: String]]].self, from: data)
            
            var endpoints: [String: [PrivateEndpointOffer]] = [:]
            for (peer, endpointDicts) in dict {
                endpoints[peer] = endpointDicts.compactMap { dict in
                    // Convert dictionary back to PrivateEndpointOffer
                    // This is a simplified approach - in production you'd need proper serialization
                    guard let methodId = dict["methodId"],
                          let endpoint = dict["endpoint"] else {
                        return nil
                    }
                    // Note: PrivateEndpointOffer may have more fields, adjust as needed
                    return PrivateEndpointOffer(methodId: methodId, endpoint: endpoint)
                }
            }
            
            endpointsCache = endpoints
            return endpoints
        } catch {
            Logger.error("PrivateEndpointStorage: Failed to load endpoints: \(error)", context: "PrivateEndpointStorage")
            return [:]
        }
    }
    
    private func persistAllEndpoints(_ endpoints: [String: [PrivateEndpointOffer]]) throws {
        // Convert PrivateEndpointOffer to dictionary for storage
        var dict: [String: [[String: String]]] = [:]
        for (peer, endpointList) in endpoints {
            dict[peer] = endpointList.map { endpoint in
                [
                    "methodId": endpoint.methodId,
                    "endpoint": endpoint.endpoint
                ]
            }
        }
        
        let data = try JSONEncoder().encode(dict)
        try keychain.store(key: endpointsKey, data: data)
        endpointsCache = endpoints
    }
}

