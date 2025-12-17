//
//  PubkySDKService.swift
//  Bitkit
//
//  Service for Pubky SDK operations using pubky-core-ffi bindings
//  Provides direct homeserver access for profile/follows fetching
//

import Foundation

// MARK: - PubkySDKService

/// Service for direct Pubky homeserver operations using pubky-core-ffi bindings
public final class PubkySDKService {
    
    // MARK: - Singleton
    
    public static let shared = PubkySDKService()
    
    // MARK: - Properties
    
    private let keychainStorage = PaykitKeychainStorage.shared
    private var sessionCache: [String: PubkyCoreSession] = [:]
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
        Logger.info("PubkySDKService initialized with pubky-core-ffi", context: "PubkySDKService")
    }
    
    // MARK: - Public API
    
    /// Configure the service with a homeserver
    public func configure(homeserver: String? = nil) {
        self.homeserver = homeserver ?? PubkyConfig.defaultHomeserver
        Logger.info("PubkySDKService configured with homeserver: \(self.homeserver)", context: "PubkySDKService")
    }
    
    /// Sign in to homeserver using a secret key
    public func signin(secretKey: String) async throws -> PubkyCoreSession {
        let result = signIn(secretKey: secretKey)
        try checkResult(result)
        
        let sessionData = try parseJSON(result[1])
        let session = PubkyCoreSession(
            pubkey: sessionData["public_key"] as? String ?? "",
            sessionSecret: sessionData["session_secret"] as? String ?? "",
            capabilities: sessionData["capabilities"] as? [String] ?? [],
            expiresAt: (sessionData["expires_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        )
        
        lock.lock()
        sessionCache[session.pubkey] = session
        lock.unlock()
        
        persistSession(session)
        Logger.info("Signed in as \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    /// Sign up to homeserver
    public func signup(secretKey: String, homeserver: String? = nil, signupToken: String? = nil) async throws -> PubkyCoreSession {
        let hs = homeserver ?? self.homeserver
        let result = signUp(secretKey: secretKey, homeserver: hs, signupToken: signupToken)
        try checkResult(result)
        
        let sessionData = try parseJSON(result[1])
        let session = PubkyCoreSession(
            pubkey: sessionData["public_key"] as? String ?? "",
            sessionSecret: sessionData["session_secret"] as? String ?? "",
            capabilities: sessionData["capabilities"] as? [String] ?? [],
            expiresAt: (sessionData["expires_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        )
        
        lock.lock()
        sessionCache[session.pubkey] = session
        lock.unlock()
        
        persistSession(session)
        Logger.info("Signed up as \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    /// Revalidate a session
    public func revalidateSession(sessionSecret: String) async throws -> PubkyCoreSession {
        let result = revalidateSession(sessionSecret: sessionSecret)
        try checkResult(result)
        
        let sessionData = try parseJSON(result[1])
        let session = PubkyCoreSession(
            pubkey: sessionData["public_key"] as? String ?? "",
            sessionSecret: sessionData["session_secret"] as? String ?? "",
            capabilities: sessionData["capabilities"] as? [String] ?? [],
            expiresAt: (sessionData["expires_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        )
        
        lock.lock()
        sessionCache[session.pubkey] = session
        lock.unlock()
        
        persistSession(session)
        Logger.info("Session revalidated for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    /// Parse an auth URL
    public func parseAuthUrl(_ url: String) throws -> [String: Any] {
        let result = parseAuthUrl(url: url)
        try checkResult(result)
        return try parseJSON(result[1])
    }
    
    /// Approve an auth request
    public func approveAuth(url: String, secretKey: String) async throws {
        let result = auth(url: url, secretKey: secretKey)
        try checkResult(result)
        Logger.info("Auth approved", context: "PubkySDKService")
    }
    
    /// Get cached session for a pubkey
    public func getSession(for pubkey: String) -> PubkyCoreSession? {
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
    
    /// Get the current active session
    public var activeSession: PubkyCoreSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionCache.values.first
    }
    
    // MARK: - Session Expiration & Refresh
    
    /// Check if a session is expired or will expire soon
    public func isSessionExpired(_ session: PubkyCoreSession, bufferSeconds: TimeInterval = 300) -> Bool {
        guard let expiresAt = session.expiresAt else {
            return false // No expiration set
        }
        return Date().addingTimeInterval(bufferSeconds) >= expiresAt
    }
    
    /// Refresh a session before it expires
    public func refreshSession(for pubkey: String) async throws -> PubkyCoreSession {
        guard let session = getSession(for: pubkey) else {
            throw PubkySDKError.noSession
        }
        
        Logger.info("Refreshing session for \(pubkey.prefix(12))...", context: "PubkySDKService")
        
        do {
            let refreshedSession = try await revalidateSession(sessionSecret: session.sessionSecret)
            Logger.info("Session refreshed successfully for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return refreshedSession
        } catch {
            Logger.error("Failed to refresh session for \(pubkey.prefix(12))...: \(error)", context: "PubkySDKService")
            throw error
        }
    }
    
    /// Get a valid session, refreshing if needed
    public func getValidSession(for pubkey: String) async throws -> PubkyCoreSession {
        guard let session = getSession(for: pubkey) else {
            throw PubkySDKError.noSession
        }
        
        // Check if session needs refresh (5 minutes buffer)
        if isSessionExpired(session, bufferSeconds: 300) {
            Logger.info("Session expiring soon for \(pubkey.prefix(12))..., refreshing", context: "PubkySDKService")
            return try await refreshSession(for: pubkey)
        }
        
        return session
    }
    
    /// Check all sessions and refresh those expiring soon
    public func refreshExpiringSessions() async {
        lock.lock()
        let sessions = Array(sessionCache.values)
        lock.unlock()
        
        for session in sessions {
            if isSessionExpired(session, bufferSeconds: 600) { // 10 minute buffer
                do {
                    _ = try await refreshSession(for: session.pubkey)
                } catch {
                    Logger.error("Failed to refresh expiring session for \(session.pubkey.prefix(12))...: \(error)", context: "PubkySDKService")
                }
            }
        }
    }
    
    // MARK: - Profile Operations
    
    /// Fetch a user's profile from their homeserver
    public func fetchProfile(pubkey: String, app: String = "pubky.app") async throws -> SDKProfile {
        // Check cache first
        if let cached = profileCache[pubkey], !cached.isExpired(ttl: profileCacheTTL) {
            Logger.debug("Profile cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.profile
        }
        
        let profileUri = "pubky://\(pubkey)/pub/\(app)/profile.json"
        Logger.debug("Fetching profile from \(profileUri)", context: "PubkySDKService")
        
        let result = get(url: profileUri)
        try checkResult(result)
        
        guard let data = result[1].data(using: .utf8) else {
            throw PubkySDKError.invalidData("Invalid profile data encoding")
        }
        
        let profile = try JSONDecoder().decode(SDKProfile.self, from: data)
        
        // Cache the result
        profileCache[pubkey] = CachedProfile(profile: profile, fetchedAt: Date())
        
        Logger.info("Fetched profile for \(pubkey.prefix(12))...: \(profile.name ?? "unnamed")", context: "PubkySDKService")
        return profile
    }
    
    /// Fetch a user's follows list from their homeserver
    public func fetchFollows(pubkey: String, app: String = "pubky.app") async throws -> [String] {
        // Check cache first
        if let cached = followsCache[pubkey], !cached.isExpired(ttl: followsCacheTTL) {
            Logger.debug("Follows cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.follows
        }
        
        let followsUri = "pubky://\(pubkey)/pub/\(app)/follows/"
        Logger.debug("Fetching follows from \(followsUri)", context: "PubkySDKService")
        
        let result = list(url: followsUri)
        try checkResult(result)
        
        // Parse the JSON array of URLs
        let urls = try JSONDecoder().decode([String].self, from: result[1].data(using: .utf8) ?? Data())
        
        // Extract pubkeys from URLs
        let follows = urls.compactMap { url -> String? in
            url.components(separatedBy: "/").last
        }
        
        // Cache the result
        followsCache[pubkey] = CachedFollows(follows: follows, fetchedAt: Date())
        
        Logger.info("Fetched \(follows.count) follows for \(pubkey.prefix(12))...", context: "PubkySDKService")
        return follows
    }
    
    // MARK: - Storage Operations
    
    /// Get data from homeserver (public read)
    public func getData(uri: String) async throws -> Data? {
        let result = get(url: uri)
        
        if result[0] == "error" {
            if result[1].contains("404") || result[1].contains("Not found") {
                return nil
            }
            throw PubkySDKError.fetchFailed(result[1])
        }
        
        // Handle base64 encoded binary data
        if result[1].hasPrefix("base64:") {
            let base64String = String(result[1].dropFirst(7))
            return Data(base64Encoded: base64String)
        }
        
        return result[1].data(using: .utf8)
    }
    
    /// Put data to homeserver (requires secret key)
    public func putData(url: String, content: String, secretKey: String) async throws {
        let result = put(url: url, content: content, secretKey: secretKey)
        try checkResult(result)
        Logger.debug("Put data to \(url)", context: "PubkySDKService")
    }
    
    /// Delete data from homeserver
    public func deleteData(url: String, secretKey: String) async throws {
        let result = deleteFile(url: url, secretKey: secretKey)
        try checkResult(result)
        Logger.debug("Deleted \(url)", context: "PubkySDKService")
    }
    
    /// List directory contents
    public func listDirectory(uri: String) async throws -> [String] {
        let result = list(url: uri)
        try checkResult(result)
        return try JSONDecoder().decode([String].self, from: result[1].data(using: .utf8) ?? Data())
    }
    
    // MARK: - Key Operations
    
    /// Generate a new secret key
    public func generateSecretKey() throws -> (secretKey: String, publicKey: String, uri: String) {
        let result = generateSecretKey()
        try checkResult(result)
        
        let data = try parseJSON(result[1])
        return (
            secretKey: data["secret_key"] as? String ?? "",
            publicKey: data["public_key"] as? String ?? "",
            uri: data["uri"] as? String ?? ""
        )
    }
    
    /// Get public key from secret key
    public func getPublicKey(secretKey: String) throws -> (publicKey: String, uri: String) {
        let result = getPublicKeyFromSecretKey(secretKey: secretKey)
        try checkResult(result)
        
        let data = try parseJSON(result[1])
        return (
            publicKey: data["public_key"] as? String ?? "",
            uri: data["uri"] as? String ?? ""
        )
    }
    
    /// Get homeserver for a pubkey
    public func getHomeserver(pubkey: String) async throws -> String {
        let result = getHomeserver(pubky: pubkey)
        try checkResult(result)
        return result[1]
    }
    
    // MARK: - Recovery
    
    /// Create a recovery file
    public func createRecoveryFile(secretKey: String, passphrase: String) throws -> String {
        let result = createRecoveryFile(secretKey: secretKey, passphrase: passphrase)
        try checkResult(result)
        return result[1]
    }
    
    /// Decrypt a recovery file
    public func decryptRecoveryFile(recoveryFile: String, passphrase: String) throws -> String {
        let result = decryptRecoveryFile(recoveryFile: recoveryFile, passphrase: passphrase)
        try checkResult(result)
        return result[1]
    }
    
    // MARK: - Mnemonic
    
    /// Generate a mnemonic phrase
    public func generateMnemonic() throws -> String {
        let result = generateMnemonicPhrase()
        try checkResult(result)
        return result[1]
    }
    
    /// Convert mnemonic to keypair
    public func mnemonicToKeypair(_ mnemonic: String) throws -> (secretKey: String, publicKey: String, uri: String) {
        let result = mnemonicPhraseToKeypair(mnemonicPhrase: mnemonic)
        try checkResult(result)
        
        let data = try parseJSON(result[1])
        return (
            secretKey: data["secret_key"] as? String ?? "",
            publicKey: data["public_key"] as? String ?? "",
            uri: data["uri"] as? String ?? ""
        )
    }
    
    /// Validate mnemonic phrase
    public func validateMnemonic(_ mnemonic: String) -> Bool {
        let result = validateMnemonicPhrase(mnemonicPhrase: mnemonic)
        return result[1] == "true"
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
                let session = try JSONDecoder().decode(PubkyCoreSession.self, from: data)
                
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
        
        Logger.info("Cleared all sessions", context: "PubkySDKService")
    }
    
    /// Sign out a specific session
    public func signout(sessionSecret: String) async throws {
        let result = signOut(sessionSecret: sessionSecret)
        try checkResult(result)
        Logger.info("Signed out", context: "PubkySDKService")
    }
    
    /// Clear caches
    public func clearCaches() {
        profileCache.removeAll()
        followsCache.removeAll()
        Logger.debug("Cleared profile and follows caches", context: "PubkySDKService")
    }
    
    // MARK: - Private Helpers
    
    private func persistSession(_ session: PubkyCoreSession) {
        do {
            let data = try JSONEncoder().encode(session)
            keychainStorage.set(key: "pubky.session.\(session.pubkey)", value: data)
            Logger.debug("Persisted session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to persist session: \(error)", context: "PubkySDKService")
        }
    }
    
    private func checkResult(_ result: [String]) throws {
        if result[0] == "error" {
            throw PubkySDKError.fetchFailed(result[1])
        }
    }
    
    private func parseJSON(_ jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PubkySDKError.invalidData("Failed to parse JSON")
        }
        return json
    }
}

// MARK: - Session Model

/// Pubky Core session
public struct PubkyCoreSession: Codable {
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
