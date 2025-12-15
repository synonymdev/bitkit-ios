//
//  DirectoryService.swift
//  Bitkit
//
//  Directory Service for Noise Endpoint Discovery
//  Uses PaykitClient FFI methods for directory operations
//

import Foundation
import PaykitMobile

/// Service for interacting with the Pubky directory
/// Uses PaykitClient FFI methods for directory operations
public final class DirectoryService {
    
    public static let shared = DirectoryService()
    
    private var paykitClient: PaykitClient?
    private var unauthenticatedTransport: UnauthenticatedTransportFfi?
    private var authenticatedTransport: AuthenticatedTransportFfi?
    private var homeserverBaseURL: String?
    
    private init() {}
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    /// Configure Pubky transport for directory operations
    public func configurePubkyTransport(homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        unauthenticatedTransport = UnauthenticatedTransportFfi.fromCallback(adapter)
    }
    
    /// Configure authenticated transport with session
    public func configureAuthenticatedTransport(sessionId: String, ownerPubkey: String, homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL
        let adapter = PubkyAuthenticatedStorageAdapter(sessionId: sessionId, homeserverBaseURL: homeserverBaseURL)
        authenticatedTransport = AuthenticatedTransportFfi.fromCallback(adapter, ownerPubkey: ownerPubkey)
    }
    
    /// Discover noise endpoints for a recipient
    public func discoverNoiseEndpoint(for recipientPubkey: String) async throws -> NoiseEndpointInfo? {
        guard paykitClient != nil else {
            throw DirectoryError.notConfigured
        }
        
        let transport = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        do {
            return try discoverNoiseEndpoint(transport: transport, recipientPubkey: recipientPubkey)
        } catch {
            Logger.error("Failed to discover Noise endpoint for \(recipientPubkey)", error: error, context: "DirectoryService")
            return nil
        }
    }
    
    /// Publish our noise endpoint
    public func publishNoiseEndpoint(host: String, port: UInt16, noisePubkey: String, metadata: String? = nil) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try publishNoiseEndpoint(transport: transport, host: host, port: port, noisePubkey: noisePubkey, metadata: metadata)
            Logger.info("Published Noise endpoint: \(host):\(port)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to publish Noise endpoint", error: error, context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Remove noise endpoint from directory
    public func removeNoiseEndpoint() async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try removeNoiseEndpoint(transport: transport)
            Logger.info("Removed Noise endpoint", context: "DirectoryService")
        } catch {
            Logger.error("Failed to remove Noise endpoint", error: error, context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Discover payment methods for a pubkey
    public func discoverPaymentMethods(for pubkey: String) async throws -> [PaymentMethod] {
        guard paykitClient != nil else {
            throw DirectoryError.notConfigured
        }
        
        let transport = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        do {
            return try fetchSupportedPayments(transport: transport, ownerPubkey: pubkey)
        } catch {
            Logger.error("Failed to discover payment methods for \(pubkey)", error: error, context: "DirectoryService")
            return []
        }
    }
    
    /// Publish a payment method to the directory
    public func publishPaymentMethod(methodId: String, endpoint: String) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try publishPaymentEndpoint(transport: transport, methodId: methodId, endpoint: endpoint)
            Logger.info("Published payment method: \(methodId)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to publish payment method \(methodId)", error: error, context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Remove a payment method from the directory
    public func removePaymentMethod(methodId: String) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try removePaymentEndpointFromDirectory(transport: transport, methodId: methodId)
            Logger.info("Removed payment method: \(methodId)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to remove payment method \(methodId)", error: error, context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Discover contacts from Pubky follows directory
    public func discoverContactsFromFollows() async throws -> [DiscoveredContact] {
        guard let ownerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            return []
        }
        
        // Create unauthenticated adapter for reading follows
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        // Fetch follows list from Pubky
        let followsPath = "/pub/pubky.app/follows/"
        let followsList = try await pubkyStorage.listDirectory(path: followsPath, adapter: unauthAdapter, ownerPubkey: ownerPubkey)
        
        var discovered: [DiscoveredContact] = []
        
        for followPubkey in followsList {
            // Check if this follow has payment methods
            let paymentMethods = try await discoverPaymentMethods(for: followPubkey)
            if !paymentMethods.isEmpty {
                discovered.append(
                    DiscoveredContact(
                        pubkey: followPubkey,
                        name: nil, // Could fetch from Pubky profile
                        hasPaymentMethods: true,
                        supportedMethods: paymentMethods.map { $0.methodId }
                    )
                )
            }
        }
        
        return discovered
    }
}

/// Discovered contact from directory
public struct DiscoveredContact {
    public let pubkey: String
    public let name: String?
    public let hasPaymentMethods: Bool
    public let supportedMethods: [String]
    
    public init(pubkey: String, name: String?, hasPaymentMethods: Bool, supportedMethods: [String]) {
        self.pubkey = pubkey
        self.name = name
        self.hasPaymentMethods = hasPaymentMethods
        self.supportedMethods = supportedMethods
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

