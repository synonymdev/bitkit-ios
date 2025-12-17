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
                try pubkyInitializeTestnet()
            } else {
                try pubkyInitialize()
            }
            isInitialized = true
            Logger.info("PubkySDKService configured (testnet: \(useTestnet))", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to initialize PubkySDK: \(error)", context: "PubkySDKService")
        }
    }
    
    // MARK: - Authentication
    
    public func signIn(secretKeyHex: String) async throws -> PubkySessionInfo {
        ensureInitialized()
        let session = try await pubkySignin(secretKeyHex: secretKeyHex)
        Logger.info("Signed in as \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    public func signUp(secretKeyHex: String, homeserverPubkey: String, signupToken: String? = nil) async throws -> PubkySessionInfo {
        ensureInitialized()
        let options = signupToken.map { PubkySignupOptions(signupToken: $0) }
        let session = try await pubkySignup(secretKeyHex: secretKeyHex, homeserverPubkey: homeserverPubkey, options: options)
        Logger.info("Signed up as \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        return session
    }
    
    public func signOut(pubkey: String) async throws {
        try await pubkySignout(pubkey: pubkey)
        Logger.info("Signed out \(pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    // MARK: - Session Management
    
    public func hasSession(pubkey: String) async -> Bool {
        return await pubkyHasSession(pubkey: pubkey)
    }
    
    public func getSession(pubkey: String) async throws -> PubkySessionInfo? {
        return try await pubkyGetSession(pubkey: pubkey)
    }
    
    public func listSessions() async -> [String] {
        return await pubkyListSessions()
    }
    
    public func refreshExpiringSessions() async {
        // Sessions are managed in-memory by the Rust SDK
        Logger.debug("refreshExpiringSessions called", context: "PubkySDKService")
    }
    
    // MARK: - Session Storage
    
    public func sessionGet(pubkey: String, path: String) async throws -> Data {
        return try await pubkySessionGet(pubkey: pubkey, path: path)
    }
    
    public func sessionPut(pubkey: String, path: String, content: Data) async throws {
        try await pubkySessionPut(pubkey: pubkey, path: path, content: content)
    }
    
    public func sessionDelete(pubkey: String, path: String) async throws {
        try await pubkySessionDelete(pubkey: pubkey, path: path)
    }
    
    public func sessionList(pubkey: String, path: String) async throws -> [PubkyListItem] {
        return try await pubkySessionList(pubkey: pubkey, path: path)
    }
    
    // MARK: - Public Storage (No Authentication)
    
    public func publicGet(uri: String) async throws -> Data {
        ensureInitialized()
        return try await pubkyPublicGet(uri: uri)
    }
    
    public func publicList(uri: String) async throws -> [PubkyListItem] {
        ensureInitialized()
        return try await pubkyPublicList(uri: uri)
    }
    
    // MARK: - Profile & Contacts
    
    public func fetchProfile(pubkey: String) async throws -> PubkyProfile {
        ensureInitialized()
        return try await pubkyFetchProfile(pubkey: pubkey)
    }
    
    public func fetchFollows(pubkey: String) async throws -> [String] {
        ensureInitialized()
        return try await pubkyFetchFollows(pubkey: pubkey)
    }
    
    // MARK: - Key Management
    
    public static func generateKeypair() -> PubkyKeypair {
        return pubkyGenerateKeypair()
    }
    
    public static func publicKeyFromSecret(secretKeyHex: String) throws -> String {
        return try pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
    }
    
    // MARK: - DNS Resolution
    
    public func resolveHomeserver(pubkey: String) async throws -> String? {
        ensureInitialized()
        return try await pubkyResolveHomeserver(pubkey: pubkey)
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

extension PubkyError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .Auth(let message):
            return "Authentication error: \(message)"
        case .Network(let message):
            return "Network error: \(message)"
        case .InvalidInput(let message):
            return "Invalid input: \(message)"
        case .Session(let message):
            return "Session error: \(message)"
        case .Build(let message):
            return "Build error: \(message)"
        case .Storage(let message):
            return "Storage error: \(message)"
        case .NotFound(let message):
            return "Not found: \(message)"
        }
    }
    
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
