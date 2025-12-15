//
//  DirectoryService.swift
//  Bitkit
//
//  Directory Service for Noise Endpoint Discovery
//

import Foundation
import PaykitMobile

/// Service for interacting with the Pubky directory
public final class DirectoryService {
    
    public static let shared = DirectoryService()
    
    private var paykitClient: PaykitClient?
    
    private init() {}
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    /// Discover noise endpoints for a recipient
    public func discoverNoiseEndpoint(for recipientPubkey: String) async throws -> NoiseEndpointInfo? {
        guard let client = paykitClient else {
            throw DirectoryError.notConfigured
        }
        
        // Use PaykitClient's directory methods
        // This is a simplified implementation
        // In production, would use client.createDirectoryService() and fetch endpoints
        
        return nil
    }
    
    /// Publish our noise endpoint
    public func publishNoiseEndpoint(_ endpoint: NoiseEndpointInfo) async throws {
        guard let client = paykitClient else {
            throw DirectoryError.notConfigured
        }
        
        // Use PaykitClient's directory methods to publish
    }
    
    /// Fetch payment methods for a pubkey
    public func fetchPaymentMethods(for pubkey: String) async throws -> [String] {
        guard let client = paykitClient else {
            throw DirectoryError.notConfigured
        }
        
        // Use PaykitClient's directory methods
        return []
    }
    
    /// Discover contacts from Pubky follows directory
    public func discoverContactsFromFollows() async throws -> [DiscoveredContact] {
        guard let client = paykitClient else {
            throw DirectoryError.notConfigured
        }
        
        // TODO: Implement actual discovery from Pubky follows directory
        // This would use PubkyStorageAdapter to fetch follows and then
        // check each follow for published payment endpoints
        return []
    }
}

public enum DirectoryError: LocalizedError {
    case notConfigured
    case networkError(String)
    case parseError(String)
    case notFound(String)
    case publishFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Directory service not configured"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        case .notFound(let resource):
            return "Not found: \(resource)"
        case .publishFailed(let msg):
            return "Publish failed: \(msg)"
        }
    }
}

