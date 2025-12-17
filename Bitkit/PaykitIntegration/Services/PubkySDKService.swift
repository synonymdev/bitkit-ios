//
//  PubkySDKService.swift
//  Bitkit
//
//  Service for Pubky SDK operations using real UniFFI bindings
//  Provides direct homeserver access for profile/follows fetching
//

import Foundation

// MARK: - PubkySDKService

/// Service for direct Pubky homeserver operations using real FFI bindings
public final class PubkySDKService {
    
    // MARK: - Singleton
    
    public static let shared = PubkySDKService()
    
    // MARK: - Properties
    
    private let keychainStorage = PaykitKeychainStorage.shared
    private var sdk: Sdk?
    private var sessionCache: [String: PubkySession] = [:]
    private var legacySessionCache: [String: LegacyPubkySession] = [:] // For compatibility with existing code
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
        do {
            sdk = try Sdk()
            Logger.info("PubkySDKService initialized with real FFI SDK", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to initialize FFI SDK: \(error)", context: "PubkySDKService")
        }
    }
    
    // MARK: - Public API
    
    /// Configure the service with a homeserver
    /// - Parameter homeserver: The homeserver pubkey (defaults to production)
    public func configure(homeserver: String? = nil) {
        self.homeserver = homeserver ?? PubkyConfig.defaultHomeserver
        Logger.info("PubkySDKService configured with homeserver: \(self.homeserver)", context: "PubkySDKService")
    }
    
    /// Sign in to homeserver using a key provider
    /// - Parameters:
    ///   - secretKey: The 32-byte secret key
    ///   - homeserver: The homeserver pubkey (uses default if nil)
    /// - Returns: Session info
    public func signin(secretKey: Data, homeserver: String? = nil) async throws -> LegacyPubkySession {
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let keyProvider = SecretKeyProvider(secretKey: secretKey)
        let hs = homeserver ?? self.homeserver
        
        let ffiSession = try await sdk.signin(keyProvider: keyProvider, homeserver: hs)
        
        lock.lock()
        defer { lock.unlock() }
        
        let info = ffiSession.info()
        sessionCache[info.pubkey] = ffiSession
        
        // Create compatible LegacyPubkySession
        let session = LegacyPubkySession(
            pubkey: info.pubkey,
            sessionSecret: info.sessionSecret ?? "",
            capabilities: info.capabilities,
            expiresAt: info.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        legacySessionCache[info.pubkey] = session
        persistSession(session)
        
        Logger.info("Signed in as \(info.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    /// Sign up to homeserver
    /// - Parameters:
    ///   - secretKey: The 32-byte secret key
    ///   - homeserver: The homeserver pubkey
    ///   - signupToken: Optional signup token
    /// - Returns: Session info
    public func signup(secretKey: Data, homeserver: String? = nil, signupToken: UInt64? = nil) async throws -> LegacyPubkySession {
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let keyProvider = SecretKeyProvider(secretKey: secretKey)
        let hs = homeserver ?? self.homeserver
        
        var options: SignupOptions? = nil
        if let token = signupToken {
            options = SignupOptions(capabilities: nil, signupToken: token)
        }
        
        let ffiSession = try await sdk.signup(keyProvider: keyProvider, homeserver: hs, options: options)
        
        lock.lock()
        defer { lock.unlock() }
        
        let info = ffiSession.info()
        sessionCache[info.pubkey] = ffiSession
        
        // Create compatible LegacyPubkySession
        let session = LegacyPubkySession(
            pubkey: info.pubkey,
            sessionSecret: info.sessionSecret ?? "",
            capabilities: info.capabilities,
            expiresAt: info.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        legacySessionCache[info.pubkey] = session
        persistSession(session)
        
        Logger.info("Signed up as \(info.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    /// Start auth flow for QR/deeplink authentication
    /// - Parameter capabilities: List of capability paths
    /// - Returns: Auth flow info with authorization URL
    public func startAuthFlow(capabilities: [String]) throws -> (authorizationUrl: String, requestId: String) {
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let flowInfo = try sdk.startAuthFlow(capabilities: capabilities)
        return (flowInfo.authorizationUrl, flowInfo.requestId)
    }
    
    /// Await approval of auth flow
    /// - Parameter requestId: The request ID from startAuthFlow
    /// - Returns: Session after approval
    public func awaitApproval(requestId: String) async throws -> LegacyPubkySession {
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let ffiSession = try await sdk.awaitApproval(requestId: requestId)
        
        lock.lock()
        defer { lock.unlock() }
        
        let info = ffiSession.info()
        sessionCache[info.pubkey] = ffiSession
        
        // Create compatible LegacyPubkySession
        let session = LegacyPubkySession(
            pubkey: info.pubkey,
            sessionSecret: info.sessionSecret ?? "",
            capabilities: info.capabilities,
            expiresAt: info.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        legacySessionCache[info.pubkey] = session
        persistSession(session)
        
        Logger.info("Auth flow approved for \(info.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    /// Set a session from Pubky-ring callback (for compatibility)
    /// - Parameter session: The session to cache and persist
    public func setSession(_ session: LegacyPubkySession) {
        lock.lock()
        defer { lock.unlock() }
        
        legacySessionCache[session.pubkey] = session
        persistSession(session)
        
        Logger.info("Session set for pubkey: \(session.pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    /// Get cached session for a pubkey
    /// - Parameter pubkey: The pubkey to get session for
    /// - Returns: The session if available
    public func getSession(for pubkey: String) -> LegacyPubkySession? {
        lock.lock()
        defer { lock.unlock() }
        return legacySessionCache[pubkey]
    }
    
    /// Check if we have an active session
    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !legacySessionCache.isEmpty || !sessionCache.isEmpty
    }
    
    /// Get the current active session (first available)
    public var activeSession: LegacyPubkySession? {
        lock.lock()
        defer { lock.unlock() }
        return legacySessionCache.values.first
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
        
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let profileUri = "pubky://\(pubkey)/pub/\(app)/profile.json"
        Logger.debug("Fetching profile from \(profileUri)", context: "PubkySDKService")
        
        let publicStorage = sdk.publicStorage()
        let data = try await publicStorage.get(uri: profileUri)
        
        let profile = try JSONDecoder().decode(SDKProfile.self, from: Data(data))
        
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
        
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let followsUri = "pubky://\(pubkey)/pub/\(app)/follows/"
        Logger.debug("Fetching follows from \(followsUri)", context: "PubkySDKService")
        
        let publicStorage = sdk.publicStorage()
        let items = try await publicStorage.list(uri: followsUri)
        
        // Extract pubkeys from entry names
        let follows = items.compactMap { item -> String? in
            // Remove any path prefix to get just the pubkey
            return item.name.isEmpty ? nil : item.name
        }
        
        // Cache the result
        followsCache[pubkey] = CachedFollows(follows: follows, fetchedAt: Date())
        
        Logger.info("Fetched \(follows.count) follows for \(pubkey.prefix(12))...", context: "PubkySDKService")
        return follows
    }
    
    // MARK: - Storage Operations
    
    /// Get data from homeserver (public read)
    /// - Parameter uri: The pubky:// URI
    /// - Returns: The data if found
    public func get(uri: String) async throws -> Data? {
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let publicStorage = sdk.publicStorage()
        do {
            let data = try await publicStorage.get(uri: uri)
            return Data(data)
        } catch {
            // Return nil for not found
            return nil
        }
    }
    
    /// Put data to homeserver (requires session)
    /// - Parameters:
    ///   - path: The storage path
    ///   - data: The data to store
    ///   - pubkey: The owner pubkey (must have active session)
    public func put(path: String, data: Data, pubkey: String) async throws {
        lock.lock()
        let ffiSession = sessionCache[pubkey]
        lock.unlock()
        
        guard let session = ffiSession else {
            throw PubkySDKError.noSession
        }
        
        let storage = session.storage()
        try await storage.put(path: path, content: [UInt8](data))
        
        Logger.debug("Put data to \(path)", context: "PubkySDKService")
    }
    
    /// Delete data from homeserver (requires session)
    /// - Parameters:
    ///   - path: The storage path
    ///   - pubkey: The owner pubkey (must have active session)
    public func delete(path: String, pubkey: String) async throws {
        lock.lock()
        let ffiSession = sessionCache[pubkey]
        lock.unlock()
        
        guard let session = ffiSession else {
            throw PubkySDKError.noSession
        }
        
        let storage = session.storage()
        try await storage.delete(path: path)
        
        Logger.debug("Deleted \(path)", context: "PubkySDKService")
    }
    
    /// List directory contents
    /// - Parameter uri: The pubky:// URI
    /// - Returns: List of items
    public func listDirectory(uri: String) async throws -> [ListItem] {
        guard let sdk = sdk else {
            throw PubkySDKError.notConfigured
        }
        
        let publicStorage = sdk.publicStorage()
        return try await publicStorage.list(uri: uri)
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
                let session = try JSONDecoder().decode(LegacyPubkySession.self, from: data)
                
                // Check if session is expired
                if let expiresAt = session.expiresAt, expiresAt < Date() {
                    Logger.info("Session expired for \(session.pubkey.prefix(12))..., removing", context: "PubkySDKService")
                    keychainStorage.deleteQuietly(key: key)
                    continue
                }
                
                legacySessionCache[session.pubkey] = session
                Logger.info("Restored session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
            } catch {
                Logger.error("Failed to restore session from \(key): \(error)", context: "PubkySDKService")
            }
        }
        
        Logger.info("Restored \(legacySessionCache.count) sessions from keychain", context: "PubkySDKService")
    }
    
    /// Clear all cached sessions
    public func clearSessions() {
        lock.lock()
        defer { lock.unlock() }
        
        for pubkey in legacySessionCache.keys {
            keychainStorage.deleteQuietly(key: "pubky.session.\(pubkey)")
        }
        legacySessionCache.removeAll()
        sessionCache.removeAll()
        
        Logger.info("Cleared all sessions", context: "PubkySDKService")
    }
    
    /// Sign out a specific session
    public func signout(pubkey: String) async throws {
        lock.lock()
        let ffiSession = sessionCache[pubkey]
        lock.unlock()
        
        if let session = ffiSession {
            try session.signout()
        }
        
        lock.lock()
        sessionCache.removeValue(forKey: pubkey)
        legacySessionCache.removeValue(forKey: pubkey)
        keychainStorage.deleteQuietly(key: "pubky.session.\(pubkey)")
        lock.unlock()
        
        Logger.info("Signed out \(pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    /// Clear caches
    public func clearCaches() {
        profileCache.removeAll()
        followsCache.removeAll()
        Logger.debug("Cleared profile and follows caches", context: "PubkySDKService")
    }
    
    // MARK: - Private Helpers
    
    private func persistSession(_ session: LegacyPubkySession) {
        do {
            let data = try JSONEncoder().encode(session)
            keychainStorage.set(key: "pubky.session.\(session.pubkey)", value: data)
            Logger.debug("Persisted session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to persist session: \(error)", context: "PubkySDKService")
        }
    }
}

// MARK: - Legacy Session (for compatibility with existing code)

/// Legacy session struct for compatibility with existing Paykit code
public struct LegacyPubkySession: Codable {
    public let pubkey: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let expiresAt: Date?
    
    public init(pubkey: String, sessionSecret: String, capabilities: [String], expiresAt: Date?) {
        self.pubkey = pubkey
        self.sessionSecret = sessionSecret
        self.capabilities = capabilities
        self.expiresAt = expiresAt
    }
}

// MARK: - Key Provider

/// Key provider implementation for FFI
private class SecretKeyProvider: KeyProvider {
    private let key: Data
    
    init(secretKey: Data) {
        self.key = secretKey
    }
    
    func secretKey() throws -> [UInt8] {
        guard key.count == 32 else {
            throw PubkyError.InvalidInput(message: "Secret key must be 32 bytes")
        }
        return [UInt8](key)
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
