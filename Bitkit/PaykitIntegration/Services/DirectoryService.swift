//
//  DirectoryService.swift
//  Bitkit
//
//  Directory Service for Noise Endpoint Discovery
//  Uses PaykitClient FFI methods for directory operations
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

// MARK: - Pubky Homeserver Configuration

/// Configuration for Pubky homeserver connections
public struct PubkyConfig {
    /// Production homeserver pubkey (Synonym mainnet)
    public static let productionHomeserver = "8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty"
    
    /// Staging homeserver pubkey (Synonym staging)
    public static let stagingHomeserver = "ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy"
    
    /// Default homeserver to use
    public static let defaultHomeserver = productionHomeserver
    
    /// Pubky app URL for production
    public static let productionAppUrl = "https://pubky.app"
    
    /// Pubky app URL for staging
    public static let stagingAppUrl = "https://staging.pubky.app"
    
    /// Get the homeserver base URL for directory operations
    public static func homeserverUrl(for homeserver: String = defaultHomeserver) -> String {
        // The homeserver pubkey is used as the base for directory operations
        return homeserver
    }
}

/// Service for interacting with the Pubky directory
/// Uses PaykitClient FFI methods for directory operations
public final class DirectoryService {
    
    public static let shared = DirectoryService()
    
    private var paykitClient: PaykitClient?
    private var directoryOps: DirectoryOperationsAsync?
    private var unauthenticatedTransport: UnauthenticatedTransportFfi?
    private var authenticatedTransport: AuthenticatedTransportFfi?
    private var homeserverBaseURL: String?
    
    private init() {
        // Create directory operations manager
        directoryOps = try? DirectoryOperationsAsync()
    }
    
    /// Public initializer for creating a new instance
    public convenience init(paykitClient: PaykitClient? = nil) {
        self.init()
        if let client = paykitClient {
            self.paykitClient = client
        }
    }
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    /// Configure Pubky transport for directory operations
    /// - Parameter homeserverBaseURL: The homeserver pubkey (defaults to PubkyConfig.defaultHomeserver)
    public func configurePubkyTransport(homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL ?? PubkyConfig.defaultHomeserver
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: self.homeserverBaseURL)
        unauthenticatedTransport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
    }
    
    /// Configure authenticated transport with session
    /// - Parameters:
    ///   - sessionId: The session ID from Pubky-ring
    ///   - ownerPubkey: The owner's public key
    ///   - homeserverBaseURL: The homeserver pubkey (defaults to PubkyConfig.defaultHomeserver)
    public func configureAuthenticatedTransport(sessionId: String, ownerPubkey: String, homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL ?? PubkyConfig.defaultHomeserver
        let adapter = PubkyAuthenticatedStorageAdapter(sessionId: sessionId, homeserverBaseURL: self.homeserverBaseURL)
        authenticatedTransport = AuthenticatedTransportFfi.fromCallback(callback: adapter, ownerPubkey: ownerPubkey)
    }
    
    /// Configure transport using a Pubky session from Pubky-ring
    public func configureWithPubkySession(_ session: PubkySession) {
        homeserverBaseURL = PubkyConfig.defaultHomeserver
        
        // Configure authenticated transport
        let adapter = PubkyAuthenticatedStorageAdapter(sessionId: session.sessionSecret, homeserverBaseURL: homeserverBaseURL)
        authenticatedTransport = AuthenticatedTransportFfi.fromCallback(callback: adapter, ownerPubkey: session.pubkey)
        
        // Also configure unauthenticated transport
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        unauthenticatedTransport = UnauthenticatedTransportFfi.fromCallback(callback: unauthAdapter)
        
        Logger.info("Configured DirectoryService with Pubky session for \(session.pubkey)", context: "DirectoryService")
    }
    
    /// Discover noise endpoints for a recipient
    public func discoverNoiseEndpoint(for recipientPubkey: String) async throws -> NoiseEndpointInfo? {
        guard paykitClient != nil else {
            throw DirectoryError.notConfigured
        }
        
        let transport = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        do {
            return try Bitkit.discoverNoiseEndpoint(transport: transport, recipientPubkey: recipientPubkey)
        } catch {
            Logger.error("Failed to discover Noise endpoint for \(recipientPubkey): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    /// Publish our noise endpoint
    public func publishNoiseEndpoint(host: String, port: UInt16, noisePubkey: String, metadata: String? = nil) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try Bitkit.publishNoiseEndpoint(transport: transport, host: host, port: port, noisePubkey: noisePubkey, metadata: metadata)
            Logger.info("Published Noise endpoint: \(host):\(port)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to publish Noise endpoint: \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Remove noise endpoint from directory
    public func removeNoiseEndpoint() async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try Bitkit.removeNoiseEndpoint(transport: transport)
            Logger.info("Removed Noise endpoint", context: "DirectoryService")
        } catch {
            Logger.error("Failed to remove Noise endpoint: \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Discover payment methods for a pubkey
    public func discoverPaymentMethods(for pubkey: String) async throws -> [PaymentMethod] {
        guard paykitClient != nil, let ops = directoryOps else {
            throw DirectoryError.notConfigured
        }
        
        let transport = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        do {
            return try ops.fetchSupportedPayments(transport: transport, ownerPubkey: pubkey)
        } catch {
            Logger.error("Failed to discover payment methods for \(pubkey): \(error)", context: "DirectoryService")
            return []
        }
    }
    
    /// Publish a payment method to the directory
    public func publishPaymentMethod(methodId: String, endpoint: String) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport, let ops = directoryOps else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try ops.publishPaymentEndpoint(transport: transport, methodId: methodId, endpointData: endpoint)
            Logger.info("Published payment method: \(methodId)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to publish payment method \(methodId): \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Remove a payment method from the directory
    public func removePaymentMethod(methodId: String) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport, let ops = directoryOps else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try ops.removePaymentEndpoint(transport: transport, methodId: methodId)
            Logger.info("Removed payment method: \(methodId)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to remove payment method \(methodId): \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Profile Operations
    
    /// Fetch profile for a pubkey from Pubky directory
    /// Uses PubkySDKService first, falls back to direct FFI if unavailable
    public func fetchProfile(for pubkey: String) async throws -> PubkyProfile? {
        // Try PubkySDKService first (preferred, direct homeserver access)
        do {
            let sdkProfile = try await PubkySDKService.shared.fetchProfile(pubkey: pubkey)
            // Convert to local PubkyProfile type
            return PubkyProfile(
                name: sdkProfile.name,
                bio: sdkProfile.bio,
                avatar: sdkProfile.image,
                links: sdkProfile.links?.map { PubkyProfileLink(title: $0.title, url: $0.url) }
            )
        } catch {
            Logger.debug("PubkySDKService profile fetch failed: \(error)", context: "DirectoryService")
        }
        
        // Try PubkyRingBridge if Pubky-ring is installed (user interaction required)
        if PubkyRingBridge.shared.isPubkyRingInstalled {
            do {
                if let profile = try await PubkyRingBridge.shared.requestProfile(pubkey: pubkey) {
                    Logger.debug("Got profile from Pubky-ring", context: "DirectoryService")
                    return profile
                }
            } catch {
                Logger.debug("PubkyRingBridge profile fetch failed: \(error)", context: "DirectoryService")
            }
        }
        
        // Fallback to direct FFI
        return try await fetchProfileViaFFI(for: pubkey)
    }
    
    /// Fetch profile using direct FFI (fallback)
    private func fetchProfileViaFFI(for pubkey: String) async throws -> PubkyProfile? {
        let adapter = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        let profilePath = "/pub/pubky.app/profile.json"
        let pubkyStorage = PubkyStorageAdapter.shared
        
        do {
            if let data = try await pubkyStorage.readFile(path: profilePath, adapter: adapter, ownerPubkey: pubkey) {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return PubkyProfile(
                        name: json["name"] as? String,
                        bio: json["bio"] as? String,
                        avatar: json["avatar"] as? String,
                        links: (json["links"] as? [[String: String]])?.compactMap { dict in
                            guard let title = dict["title"], let url = dict["url"] else { return nil }
                            return PubkyProfileLink(title: title, url: url)
                        }
                    )
                }
            }
            return nil
        } catch {
            Logger.error("Failed to fetch profile for \(pubkey): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    /// Publish profile to Pubky directory
    public func publishProfile(_ profile: PubkyProfile) async throws {
        guard let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let profilePath = "/pub/pubky.app/profile.json"
        
        var profileDict: [String: Any] = [:]
        if let name = profile.name { profileDict["name"] = name }
        if let bio = profile.bio { profileDict["bio"] = bio }
        if let avatar = profile.avatar { profileDict["avatar"] = avatar }
        if let links = profile.links {
            profileDict["links"] = links.map { ["title": $0.title, "url": $0.url] }
        }
        
        let data = try JSONSerialization.data(withJSONObject: profileDict)
        try await pubkyStorage.writeFile(path: profilePath, data: data, transport: transport)
        Logger.info("Published profile to Pubky directory", context: "DirectoryService")
    }
    
    // MARK: - Follows Operations
    
    /// Fetch list of pubkeys user follows
    /// Uses PubkySDKService first, falls back to direct FFI if unavailable
    public func fetchFollows() async throws -> [String] {
        guard let ownerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            return []
        }
        
        // Try PubkySDKService first (preferred, direct homeserver access)
        do {
            return try await PubkySDKService.shared.fetchFollows(pubkey: ownerPubkey)
        } catch {
            Logger.debug("PubkySDKService follows fetch failed: \(error)", context: "DirectoryService")
        }
        
        // Try PubkyRingBridge if Pubky-ring is installed (user interaction required)
        if PubkyRingBridge.shared.isPubkyRingInstalled {
            do {
                let follows = try await PubkyRingBridge.shared.requestFollows()
                if !follows.isEmpty {
                    Logger.debug("Got \(follows.count) follows from Pubky-ring", context: "DirectoryService")
                    return follows
                }
            } catch {
                Logger.debug("PubkyRingBridge follows fetch failed: \(error)", context: "DirectoryService")
            }
        }
        
        // Fallback to direct FFI
        return try await fetchFollowsViaFFI(ownerPubkey: ownerPubkey)
    }
    
    /// Fetch follows using direct FFI (fallback)
    private func fetchFollowsViaFFI(ownerPubkey: String) async throws -> [String] {
        let adapter = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let followsPath = "/pub/pubky.app/follows/"
        let unauthenticatedAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        
        return try await pubkyStorage.listDirectory(path: followsPath, adapter: unauthenticatedAdapter, ownerPubkey: ownerPubkey)
    }
    
    /// Add a follow to the Pubky directory
    public func addFollow(pubkey: String) async throws {
        guard let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let followPath = "/pub/pubky.app/follows/\(pubkey)"
        let data = "{}".data(using: .utf8)!
        
        try await pubkyStorage.writeFile(path: followPath, data: data, transport: transport)
        Logger.info("Added follow: \(pubkey)", context: "DirectoryService")
    }
    
    /// Remove a follow from the Pubky directory
    public func removeFollow(pubkey: String) async throws {
        guard let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let followPath = "/pub/pubky.app/follows/\(pubkey)"
        
        try await pubkyStorage.deleteFile(path: followPath, transport: transport)
        Logger.info("Removed follow: \(pubkey)", context: "DirectoryService")
    }
    
    /// Discover contacts from Pubky follows directory
    public func discoverContactsFromFollows() async throws -> [DirectoryDiscoveredContact] {
        guard let ownerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            return []
        }
        
        // Create unauthenticated adapter for reading follows
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        // Fetch follows list from Pubky
        let followsPath = "/pub/pubky.app/follows/"
        let followsList = try await pubkyStorage.listDirectory(path: followsPath, adapter: unauthAdapter, ownerPubkey: ownerPubkey)
        
        var discovered: [DirectoryDiscoveredContact] = []
        
        for followPubkey in followsList {
            // Check if this follow has payment methods
            let paymentMethods = try await discoverPaymentMethods(for: followPubkey)
            if !paymentMethods.isEmpty {
                discovered.append(
                    DirectoryDiscoveredContact(
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
    
    // MARK: - Pending Requests Discovery
    
    private static let paykitPathPrefix = "/pub/paykit.app/v0/"
    
    /// Discover pending payment requests from the Pubky directory
    public func discoverPendingRequests(for ownerPubkey: String) async throws -> [DiscoveredRequest] {
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        let requestsPath = "\(Self.paykitPathPrefix)requests/\(ownerPubkey)/"
        
        do {
            let requestFiles = try await pubkyStorage.listDirectory(path: requestsPath, adapter: unauthAdapter, ownerPubkey: ownerPubkey)
            
            var requests: [DiscoveredRequest] = []
            for requestId in requestFiles {
                if let request = await parsePaymentRequest(requestId: requestId, path: requestsPath + requestId, adapter: unauthAdapter, ownerPubkey: ownerPubkey) {
                    requests.append(request)
                }
            }
            return requests
        } catch {
            Logger.error("Failed to discover pending requests for \(ownerPubkey): \(error)", context: "DirectoryService")
            return []
        }
    }
    
    /// Discover subscription proposals from the Pubky directory
    public func discoverSubscriptionProposals(for ownerPubkey: String) async throws -> [DiscoveredSubscriptionProposal] {
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        let proposalsPath = "\(Self.paykitPathPrefix)subscriptions/proposals/\(ownerPubkey)/"
        
        do {
            let proposalFiles = try await pubkyStorage.listDirectory(path: proposalsPath, adapter: unauthAdapter, ownerPubkey: ownerPubkey)
            
            var proposals: [DiscoveredSubscriptionProposal] = []
            for proposalId in proposalFiles {
                if let proposal = await parseSubscriptionProposal(proposalId: proposalId, path: proposalsPath + proposalId, adapter: unauthAdapter, ownerPubkey: ownerPubkey) {
                    proposals.append(proposal)
                }
            }
            return proposals
        } catch {
            Logger.error("Failed to discover subscription proposals for \(ownerPubkey): \(error)", context: "DirectoryService")
            return []
        }
    }
    
    private func parsePaymentRequest(requestId: String, path: String, adapter: PubkyUnauthenticatedStorageAdapter, ownerPubkey: String) async -> DiscoveredRequest? {
        let pubkyStorage = PubkyStorageAdapter.shared
        
        do {
            guard let data = try await pubkyStorage.readFile(path: path, adapter: adapter, ownerPubkey: ownerPubkey) else {
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            return DiscoveredRequest(
                requestId: requestId,
                type: .paymentRequest,
                fromPubkey: json["from_pubkey"] as? String ?? "",
                amountSats: (json["amount_sats"] as? Int64) ?? 0,
                description: json["description"] as? String,
                createdAt: Date(timeIntervalSince1970: TimeInterval((json["created_at"] as? Int64) ?? Int64(Date().timeIntervalSince1970)))
            )
        } catch {
            Logger.error("Failed to parse payment request \(requestId): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    private func parseSubscriptionProposal(proposalId: String, path: String, adapter: PubkyUnauthenticatedStorageAdapter, ownerPubkey: String) async -> DiscoveredSubscriptionProposal? {
        let pubkyStorage = PubkyStorageAdapter.shared
        
        do {
            guard let data = try await pubkyStorage.readFile(path: path, adapter: adapter, ownerPubkey: ownerPubkey) else {
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            return DiscoveredSubscriptionProposal(
                subscriptionId: proposalId,
                providerPubkey: json["provider_pubkey"] as? String ?? "",
                amountSats: (json["amount_sats"] as? Int64) ?? 0,
                description: json["description"] as? String,
                frequency: json["frequency"] as? String ?? "monthly",
                createdAt: Date(timeIntervalSince1970: TimeInterval((json["created_at"] as? Int64) ?? Int64(Date().timeIntervalSince1970)))
            )
        } catch {
            Logger.error("Failed to parse subscription proposal \(proposalId): \(error)", context: "DirectoryService")
            return nil
        }
    }
}

/// Discovered contact from directory with health tracking
public struct DirectoryDiscoveredContact: Identifiable {
    public var id: String { pubkey }
    public let pubkey: String
    public let name: String?
    public let hasPaymentMethods: Bool
    public let supportedMethods: [String]
    public var endpointHealth: [String: Bool]
    public var lastHealthCheckDates: [String: Date]
    
    public init(
        pubkey: String,
        name: String?,
        hasPaymentMethods: Bool,
        supportedMethods: [String],
        endpointHealth: [String: Bool] = [:],
        lastHealthCheckDates: [String: Date] = [:]
    ) {
        self.pubkey = pubkey
        self.name = name
        self.hasPaymentMethods = hasPaymentMethods
        self.supportedMethods = supportedMethods
        
        // Default all endpoints to healthy if not specified
        if endpointHealth.isEmpty {
            var health: [String: Bool] = [:]
            for method in supportedMethods {
                health[method] = true
            }
            self.endpointHealth = health
        } else {
            self.endpointHealth = endpointHealth
        }
        
        self.lastHealthCheckDates = lastHealthCheckDates
    }
}

/// Profile from Pubky directory
public struct PubkyProfile: Codable {
    public let name: String?
    public let bio: String?
    public let avatar: String?
    public let links: [PubkyProfileLink]?
    
    public init(name: String? = nil, bio: String? = nil, avatar: String? = nil, links: [PubkyProfileLink]? = nil) {
        self.name = name
        self.bio = bio
        self.avatar = avatar
        self.links = links
    }
}

public struct PubkyProfileLink: Codable {
    public let title: String
    public let url: String
    
    public init(title: String, url: String) {
        self.title = title
        self.url = url
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
