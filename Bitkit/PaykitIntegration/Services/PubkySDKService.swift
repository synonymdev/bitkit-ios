//
//  PubkySDKService.swift
//  Bitkit
//
//  Wrapper service for Pubky SDK operations
//  Provides direct homeserver access for profile/follows fetching
//  Uses existing Paykit FFI for storage operations
//

import Foundation

// MARK: - PubkySDKService

/// Service for direct Pubky homeserver operations
/// Wraps the existing Paykit FFI storage adapters with higher-level methods
public final class PubkySDKService {
    
    // MARK: - Singleton
    
    public static let shared = PubkySDKService()
    
    // MARK: - Properties
    
    private let keychainStorage = PaykitKeychainStorage.shared
    private var unauthenticatedAdapter: PubkyUnauthenticatedStorageAdapter?
    private var authenticatedAdapter: PubkyAuthenticatedStorageAdapter?
    private var sessionCache: [String: PubkySession] = [:]
    private let lock = NSLock()
    
    // MARK: - Configuration
    
    /// Current homeserver pubkey
    public private(set) var homeserver: String = PubkyConfig.defaultHomeserver
    
    /// Profile cache to avoid repeated fetches
    private var profileCache: [String: CachedProfile] = [:]
    private let profileCacheTTL: TimeInterval = 300 // 5 minutes
    
    /// Follows cache
    private var followsCache: [String: CachedFollows] = [:]
    private let followsCacheTTL: TimeInterval = 300 // 5 minutes
    
    // MARK: - Initialization
    
    private init() {
        setupUnauthenticatedAdapter()
    }
    
    private func setupUnauthenticatedAdapter() {
        unauthenticatedAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserver)
    }
    
    // MARK: - Public API
    
    /// Configure the service with a homeserver
    /// - Parameter homeserver: The homeserver pubkey (defaults to production)
    public func configure(homeserver: String? = nil) {
        self.homeserver = homeserver ?? PubkyConfig.defaultHomeserver
        setupUnauthenticatedAdapter()
        Logger.info("PubkySDKService configured with homeserver: \(self.homeserver)", context: "PubkySDKService")
    }
    
    /// Set a session from Pubky-ring callback
    /// - Parameter session: The session to cache and persist
    public func setSession(_ session: PubkySession) {
        lock.lock()
        defer { lock.unlock() }
        
        sessionCache[session.pubkey] = session
        persistSession(session)
        
        // Create authenticated adapter for writes
        authenticatedAdapter = PubkyAuthenticatedStorageAdapter(
            sessionId: session.sessionSecret,
            homeserverBaseURL: homeserver
        )
        
        Logger.info("Session set for pubkey: \(session.pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    /// Get cached session for a pubkey
    /// - Parameter pubkey: The pubkey to get session for
    /// - Returns: The session if available
    public func getSession(for pubkey: String) -> PubkySession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionCache[pubkey]
    }
    
    /// Check if we have an active session
    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sessionCache.isEmpty
    }
    
    /// Get the current active session (first available)
    public var activeSession: PubkySession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionCache.values.first
    }
    
    // MARK: - Profile Operations
    
    /// Fetch a user's profile from their homeserver
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - app: The app namespace (default: pubky.app)
    /// - Returns: The user's profile
    public func fetchProfile(pubkey: String, app: String = "pubky.app") async throws -> SDKProfile {
        // Check cache first
        if let cached = profileCache[pubkey], !cached.isExpired(ttl: profileCacheTTL) {
            Logger.debug("Profile cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.profile
        }
        
        guard let adapter = unauthenticatedAdapter else {
            throw PubkySDKError.notConfigured
        }
        
        let profilePath = "/pub/\(app)/profile.json"
        Logger.debug("Fetching profile from \(pubkey.prefix(12))...\(profilePath)", context: "PubkySDKService")
        
        let result = adapter.get(ownerPubkey: pubkey, path: profilePath)
        
        guard result.success else {
            if let error = result.error {
                throw PubkySDKError.fetchFailed(error)
            }
            throw PubkySDKError.fetchFailed("Unknown error")
        }
        
        guard let content = result.content else {
            throw PubkySDKError.notFound("Profile not found for \(pubkey.prefix(12))...")
        }
        
        guard let data = content.data(using: .utf8) else {
            throw PubkySDKError.invalidData("Invalid profile data encoding")
        }
        
        let profile = try JSONDecoder().decode(SDKProfile.self, from: data)
        
        // Cache the result
        profileCache[pubkey] = CachedProfile(profile: profile, fetchedAt: Date())
        
        Logger.info("Fetched profile for \(pubkey.prefix(12))...: \(profile.name ?? "unnamed")", context: "PubkySDKService")
        return profile
    }
    
    /// Fetch a user's follows list from their homeserver
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - app: The app namespace (default: pubky.app)
    /// - Returns: List of followed pubkeys
    public func fetchFollows(pubkey: String, app: String = "pubky.app") async throws -> [String] {
        // Check cache first
        if let cached = followsCache[pubkey], !cached.isExpired(ttl: followsCacheTTL) {
            Logger.debug("Follows cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.follows
        }
        
        guard let adapter = unauthenticatedAdapter else {
            throw PubkySDKError.notConfigured
        }
        
        let followsPath = "/pub/\(app)/follows/"
        Logger.debug("Fetching follows from \(pubkey.prefix(12))...\(followsPath)", context: "PubkySDKService")
        
        let result = adapter.list(ownerPubkey: pubkey, prefix: followsPath)
        
        guard result.success else {
            if let error = result.error {
                throw PubkySDKError.fetchFailed(error)
            }
            throw PubkySDKError.fetchFailed("Unknown error")
        }
        
        // The entries are file names in the follows directory
        // Each file name is a pubkey
        let follows = result.entries.compactMap { entry -> String? in
            // Remove any path prefix to get just the pubkey
            let pubkey = entry.components(separatedBy: "/").last
            return pubkey?.isEmpty == false ? pubkey : nil
        }
        
        // Cache the result
        followsCache[pubkey] = CachedFollows(follows: follows, fetchedAt: Date())
        
        Logger.info("Fetched \(follows.count) follows for \(pubkey.prefix(12))...", context: "PubkySDKService")
        return follows
    }
    
    // MARK: - Storage Operations
    
    /// Get data from homeserver (public read)
    /// - Parameters:
    ///   - uri: The pubky:// URI or path
    ///   - ownerPubkey: The owner's pubkey (required for path-only)
    /// - Returns: The data if found
    public func get(uri: String, ownerPubkey: String? = nil) async throws -> Data? {
        guard let adapter = unauthenticatedAdapter else {
            throw PubkySDKError.notConfigured
        }
        
        // Parse URI if full pubky:// format
        let (pubkey, path) = try parseUri(uri, defaultPubkey: ownerPubkey)
        
        let result = adapter.get(ownerPubkey: pubkey, path: path)
        
        guard result.success else {
            if let error = result.error {
                throw PubkySDKError.fetchFailed(error)
            }
            return nil
        }
        
        return result.content?.data(using: .utf8)
    }
    
    /// Put data to homeserver (requires session)
    /// - Parameters:
    ///   - path: The storage path
    ///   - data: The data to store
    public func put(path: String, data: Data) async throws {
        guard let adapter = authenticatedAdapter else {
            throw PubkySDKError.noSession
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw PubkySDKError.invalidData("Cannot encode data as UTF-8")
        }
        
        let result = adapter.put(path: path, content: content)
        
        guard result.success else {
            if let error = result.error {
                throw PubkySDKError.writeFailed(error)
            }
            throw PubkySDKError.writeFailed("Unknown error")
        }
        
        Logger.debug("Put data to \(path)", context: "PubkySDKService")
    }
    
    /// List directory contents
    /// - Parameters:
    ///   - prefix: The directory path prefix
    ///   - ownerPubkey: The owner's pubkey
    /// - Returns: List of entries
    public func listDirectory(prefix: String, ownerPubkey: String) async throws -> [String] {
        guard let adapter = unauthenticatedAdapter else {
            throw PubkySDKError.notConfigured
        }
        
        let result = adapter.list(ownerPubkey: ownerPubkey, prefix: prefix)
        
        guard result.success else {
            if let error = result.error {
                throw PubkySDKError.fetchFailed(error)
            }
            throw PubkySDKError.fetchFailed("Unknown error")
        }
        
        return result.entries
    }
    
    // MARK: - Session Persistence
    
    /// Restore sessions from keychain on app launch
    public func restoreSessions() {
        lock.lock()
        defer { lock.unlock() }
        
        let sessionKeys = keychainStorage.listKeys(withPrefix: "pubky.session.")
        
        for key in sessionKeys {
            do {
                guard let data = keychainStorage.get(key: key) else { continue }
                let session = try JSONDecoder().decode(PubkySession.self, from: data)
                
                // Check if session is expired
                if let expiresAt = session.expiresAt, expiresAt < Date() {
                    Logger.info("Session expired for \(session.pubkey.prefix(12))..., removing", context: "PubkySDKService")
                    keychainStorage.deleteQuietly(key: key)
                    continue
                }
                
                sessionCache[session.pubkey] = session
                Logger.info("Restored session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
            } catch {
                Logger.error("Failed to restore session from \(key): \(error)", context: "PubkySDKService")
            }
        }
        
        // Setup authenticated adapter if we have a session
        if let session = sessionCache.values.first {
            authenticatedAdapter = PubkyAuthenticatedStorageAdapter(
                sessionId: session.sessionSecret,
                homeserverBaseURL: homeserver
            )
        }
        
        Logger.info("Restored \(sessionCache.count) sessions from keychain", context: "PubkySDKService")
    }
    
    /// Clear all cached sessions
    public func clearSessions() {
        lock.lock()
        defer { lock.unlock() }
        
        for pubkey in sessionCache.keys {
            keychainStorage.deleteQuietly(key: "pubky.session.\(pubkey)")
        }
        sessionCache.removeAll()
        authenticatedAdapter = nil
        
        Logger.info("Cleared all sessions", context: "PubkySDKService")
    }
    
    /// Clear caches
    public func clearCaches() {
        profileCache.removeAll()
        followsCache.removeAll()
        Logger.debug("Cleared profile and follows caches", context: "PubkySDKService")
    }
    
    // MARK: - Private Helpers
    
    private func persistSession(_ session: PubkySession) {
        do {
            let data = try JSONEncoder().encode(session)
            keychainStorage.set(key: "pubky.session.\(session.pubkey)", value: data)
            Logger.debug("Persisted session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to persist session: \(error)", context: "PubkySDKService")
        }
    }
    
    private func parseUri(_ uri: String, defaultPubkey: String?) throws -> (pubkey: String, path: String) {
        if uri.hasPrefix("pubky://") {
            // Parse full URI: pubky://{pubkey}/path
            let withoutScheme = String(uri.dropFirst("pubky://".count))
            guard let slashIndex = withoutScheme.firstIndex(of: "/") else {
                throw PubkySDKError.invalidUri(uri)
            }
            let pubkey = String(withoutScheme[..<slashIndex])
            let path = String(withoutScheme[slashIndex...])
            return (pubkey, path)
        } else if let pubkey = defaultPubkey {
            // Path only, use default pubkey
            return (pubkey, uri)
        } else {
            throw PubkySDKError.invalidUri("URI requires pubkey: \(uri)")
        }
    }
}

// MARK: - Error Types

public enum PubkySDKError: LocalizedError {
    case notConfigured
    case noSession
    case fetchFailed(String)
    case writeFailed(String)
    case notFound(String)
    case invalidData(String)
    case invalidUri(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PubkySDKService is not configured"
        case .noSession:
            return "No active session - authenticate with Pubky-ring first"
        case .fetchFailed(let msg):
            return "Fetch failed: \(msg)"
        case .writeFailed(let msg):
            return "Write failed: \(msg)"
        case .notFound(let msg):
            return "Not found: \(msg)"
        case .invalidData(let msg):
            return "Invalid data: \(msg)"
        case .invalidUri(let msg):
            return "Invalid URI: \(msg)"
        }
    }
}

// MARK: - Data Models

/// Pubky SDK profile data (maps to homeserver format)
public struct SDKProfile: Codable {
    public let name: String?
    public let bio: String?
    public let image: String?
    public let links: [SDKProfileLink]?
    
    public init(name: String? = nil, bio: String? = nil, image: String? = nil, links: [SDKProfileLink]? = nil) {
        self.name = name
        self.bio = bio
        self.image = image
        self.links = links
    }
}

/// SDK Profile link
public struct SDKProfileLink: Codable {
    public let title: String
    public let url: String
}

// MARK: - Cache Types

private struct CachedProfile {
    let profile: SDKProfile
    let fetchedAt: Date
    
    func isExpired(ttl: TimeInterval) -> Bool {
        return Date().timeIntervalSince(fetchedAt) > ttl
    }
}

private struct CachedFollows {
    let follows: [String]
    let fetchedAt: Date
    
    func isExpired(ttl: TimeInterval) -> Bool {
        return Date().timeIntervalSince(fetchedAt) > ttl
    }
}

