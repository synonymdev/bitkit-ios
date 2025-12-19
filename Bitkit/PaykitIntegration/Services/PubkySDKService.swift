//  PubkySDKService.swift
//  Bitkit
//
//  Service for managing Pubky SDK operations (sign-in, session management, storage)
//  Uses BitkitCore FFI bindings for pubky SDK functionality.

import Foundation
import BitkitCore

// MARK: - PubkySDKService

public final class PubkySDKService {
    public static let shared = PubkySDKService()
    
    private var isInitialized = false
    
    private init() {
        Logger.info("PubkySDKService initializing", context: "PubkySDKService")
    }
    
    // MARK: - Initialization
    
    public func configure(useTestnet: Bool = false) {
        guard !isInitialized else { return }
        
        do {
            if useTestnet {
                try BitkitCore.pubkyInitializeTestnet()
            } else {
                try BitkitCore.pubkyInitialize()
            }
            isInitialized = true
            Logger.info("PubkySDKService configured (testnet: \(useTestnet))", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to initialize PubkySDK: \(error)", context: "PubkySDKService")
        }
    }
    
    // MARK: - Authentication
    
    public func signIn(secretKeyHex: String) async throws -> BitkitCore.PubkySessionInfo {
        ensureInitialized()
        let session = try await BitkitCore.pubkySignin(secretKeyHex: secretKeyHex)
        Logger.info("Signed in as \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    public func signUp(secretKeyHex: String, homeserverPubkey: String, signupToken: String? = nil) async throws -> BitkitCore.PubkySessionInfo {
        ensureInitialized()
        let options = signupToken.map { BitkitCore.PubkySignupOptions(signupToken: $0) }
        let session = try await BitkitCore.pubkySignup(secretKeyHex: secretKeyHex, homeserverPubkey: homeserverPubkey, options: options)
        Logger.info("Signed up as \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    public func signOut(pubkey: String) async throws {
        try await BitkitCore.pubkySignout(pubkey: pubkey)
        Logger.info("Signed out \(pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    /// Import a session from Pubky Ring
    /// - Parameters:
    ///   - pubkey: The z-base32 encoded public key
    ///   - sessionSecret: The session secret (cookie) from Pubky Ring
    public func importSession(pubkey: String, sessionSecret: String) throws -> BitkitCore.PubkySessionInfo {
        ensureInitialized()
        // This is now synchronous - it uses the Tokio runtime internally
        let session = try pubkyImportSession(pubkey: pubkey, sessionSecret: sessionSecret)
        Logger.info("Imported session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    // MARK: - Session Management
    
    public func hasSession(pubkey: String) async -> Bool {
        return await BitkitCore.pubkyHasSession(pubkey: pubkey)
    }
    
    public func getSession(pubkey: String) async throws -> BitkitCore.PubkySessionInfo? {
        return try await BitkitCore.pubkyGetSession(pubkey: pubkey)
    }
    
    public func listSessions() async -> [String] {
        return await BitkitCore.pubkyListSessions()
    }
    
    public func refreshExpiringSessions() async {
        // Sessions are managed in-memory by the Rust SDK
        Logger.debug("refreshExpiringSessions called", context: "PubkySDKService")
    }
    
    // MARK: - Session Storage
    
    public func sessionGet(pubkey: String, path: String) throws -> Data {
        return try pubkySessionGet(pubkey: pubkey, path: path)
    }
    
    public func sessionPut(pubkey: String, path: String, content: Data) throws {
        try pubkySessionPut(pubkey: pubkey, path: path, content: content)
    }
    
    public func sessionDelete(pubkey: String, path: String) throws {
        try pubkySessionDelete(pubkey: pubkey, path: path)
    }
    
    public func sessionList(pubkey: String, path: String) throws -> [BitkitCore.PubkyListItem] {
        return try pubkySessionList(pubkey: pubkey, path: path)
    }
    
    // MARK: - Public Storage (No Authentication)
    
    public func publicGet(uri: String) async throws -> Data {
        ensureInitialized()
        return try await BitkitCore.pubkyPublicGet(uri: uri)
    }
    
    public func publicList(uri: String) async throws -> [BitkitCore.PubkyListItem] {
        ensureInitialized()
        return try await BitkitCore.pubkyPublicList(uri: uri)
    }
    
    // MARK: - Profile & Contacts
    
    public func fetchProfile(pubkey: String) async throws -> BitkitCore.PubkyProfile {
        ensureInitialized()
        return try await BitkitCore.pubkyFetchProfile(pubkey: pubkey)
    }
    
    public func fetchFollows(pubkey: String) async throws -> [String] {
        ensureInitialized()
        return try await BitkitCore.pubkyFetchFollows(pubkey: pubkey)
    }
    
    // MARK: - Key Management
    
    public static func generateKeypair() -> BitkitCore.PubkyKeypair {
        return BitkitCore.pubkyGenerateKeypair()
    }
    
    public static func publicKeyFromSecret(secretKeyHex: String) throws -> String {
        return try BitkitCore.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
    }
    
    // MARK: - DNS Resolution
    
    public func resolveHomeserver(pubkey: String) async throws -> String? {
        ensureInitialized()
        return try await BitkitCore.pubkyResolveHomeserver(pubkey: pubkey)
    }
    
    // MARK: - Persistence
    
    public func storeSessions() {
        // Session persistence will be implemented when needed
    }
    
    public func restoreSessions() {
        // Session restoration will be implemented when needed
    }
    
    // MARK: - Helpers
    
    private func ensureInitialized() {
        if !isInitialized {
            configure()
        }
    }
}

// MARK: - Error Extensions

extension PubkyError {
    // Note: PubkyError already conforms to LocalizedError in generated bindings
    // This extension adds a user-friendly message property
    
    public var userFriendlyMessage: String {
        switch self {
        case .Auth:
            return "Authentication failed. Please try again."
        case .Network:
            return "Network error. Please check your connection."
        case .InvalidInput:
            return "Invalid input provided."
        case .Session:
            return "Session error. Please sign in again."
        case .Build:
            return "Service initialization failed."
        case .Storage:
            return "Storage operation failed."
        case .NotFound:
            return "The requested resource was not found."
        }
    }
}
