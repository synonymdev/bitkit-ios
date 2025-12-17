//  PubkySDKService.swift
//  Bitkit
//
//  Service for managing Pubky SDK operations.
//  Note: Full FFI integration requires pushing bitkit-core changes to BitcoinErrorLog/bitkit-core.
//  Until then, this uses local type definitions and will be updated when FFI is available.

import Foundation

// MARK: - Local Type Definitions (until BitkitCore FFI is updated)

/// Session information from pubky SDK
public struct PubkySessionInfo: Codable {
    public let pubkey: String
    public let capabilities: [String]
    public let createdAt: UInt64
}

/// Keypair from pubky SDK
public struct PubkyKeypair: Codable {
    public let secretKeyHex: String
    public let publicKey: String
}

/// List item from pubky storage
public struct PubkyListItem: Codable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
}

// Note: PubkyProfile is defined in DirectoryService.swift

/// Signup options
public struct PubkySignupOptions {
    public let signupToken: String?
}

/// Error types for pubky SDK operations
public enum PubkySDKError: Error, LocalizedError {
    case notInitialized
    case authenticationFailed(String)
    case networkError(String)
    case sessionNotFound
    case storageError(String)
    case invalidInput(String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Pubky SDK not initialized"
        case .authenticationFailed(let msg):
            return "Authentication failed: \(msg)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .sessionNotFound:
            return "Session not found"
        case .storageError(let msg):
            return "Storage error: \(msg)"
        case .invalidInput(let msg):
            return "Invalid input: \(msg)"
        }
    }
    
    public var userFriendlyMessage: String {
        switch self {
        case .notInitialized:
            return "Service not initialized. Please restart the app."
        case .authenticationFailed:
            return "Sign in failed. Please try again."
        case .networkError:
            return "Network error. Please check your connection."
        case .sessionNotFound:
            return "Session not found. Please sign in again."
        case .storageError:
            return "Storage operation failed."
        case .invalidInput:
            return "Invalid input provided."
        }
    }
}

// MARK: - PubkySDKService

public final class PubkySDKService {
    public static let shared = PubkySDKService()
    
    private var isInitialized = false
    private var sessions: [String: PubkySessionInfo] = [:]
    
    private init() {
        Logger.info("PubkySDKService initializing", context: "PubkySDKService")
    }
    
    // MARK: - Initialization
    
    public func configure(useTestnet: Bool = false) {
        guard !isInitialized else { return }
        isInitialized = true
        Logger.info("PubkySDKService configured (testnet: \(useTestnet))", context: "PubkySDKService")
        Logger.info("Note: Full pubky SDK requires BitkitCore FFI update", context: "PubkySDKService")
    }
    
    // MARK: - Authentication (Placeholder until FFI available)
    
    public func signIn(secretKeyHex: String) async throws -> PubkySessionInfo {
        ensureInitialized()
        // TODO: Replace with actual FFI call when BitkitCore is updated
        // return try await pubkySignin(secretKeyHex: secretKeyHex)
        Logger.warn("PubkySDKService.signIn: FFI not available yet", context: "PubkySDKService")
        throw PubkySDKError.notInitialized
    }
    
    public func signUp(secretKeyHex: String, homeserverPubkey: String, signupToken: String? = nil) async throws -> PubkySessionInfo {
        ensureInitialized()
        // TODO: Replace with actual FFI call when BitkitCore is updated
        Logger.warn("PubkySDKService.signUp: FFI not available yet", context: "PubkySDKService")
        throw PubkySDKError.notInitialized
    }
    
    public func signOut(pubkey: String) async throws {
        sessions.removeValue(forKey: pubkey)
        Logger.info("Signed out \(pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    // MARK: - Session Management
    
    public func hasSession(pubkey: String) async -> Bool {
        return sessions[pubkey] != nil
    }
    
    public func getSession(pubkey: String) async throws -> PubkySessionInfo? {
        return sessions[pubkey]
    }
    
    public func listSessions() async -> [String] {
        return Array(sessions.keys)
    }
    
    public func refreshExpiringSessions() async {
        Logger.debug("refreshExpiringSessions called", context: "PubkySDKService")
    }
    
    // MARK: - Key Management (Can work locally)
    
    public static func generateKeypair() -> PubkyKeypair {
        // Generate a random 32-byte secret key
        var secretBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes)
        let secretKeyHex = secretBytes.map { String(format: "%02x", $0) }.joined()
        
        // For the public key, we'd need the actual derivation
        // This is a placeholder - the real implementation would use the FFI
        let publicKey = "placeholder_pubkey_\(secretKeyHex.prefix(16))"
        
        return PubkyKeypair(secretKeyHex: secretKeyHex, publicKey: publicKey)
    }
    
    public static func publicKeyFromSecret(secretKeyHex: String) throws -> String {
        // TODO: Replace with actual FFI call
        // return try pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        guard secretKeyHex.count == 64 else {
            throw PubkySDKError.invalidInput("Secret key must be 64 hex characters (32 bytes)")
        }
        return "placeholder_pubkey_\(secretKeyHex.prefix(16))"
    }
    
    // MARK: - Storage Operations (Placeholder)
    
    public func sessionGet(pubkey: String, path: String) async throws -> Data {
        throw PubkySDKError.notInitialized
    }
    
    public func sessionPut(pubkey: String, path: String, content: Data) async throws {
        throw PubkySDKError.notInitialized
    }
    
    public func sessionDelete(pubkey: String, path: String) async throws {
        throw PubkySDKError.notInitialized
    }
    
    public func sessionList(pubkey: String, path: String) async throws -> [PubkyListItem] {
        throw PubkySDKError.notInitialized
    }
    
    // MARK: - Public Storage (Placeholder)
    
    public func publicGet(uri: String) async throws -> Data {
        throw PubkySDKError.notInitialized
    }
    
    public func publicList(uri: String) async throws -> [PubkyListItem] {
        throw PubkySDKError.notInitialized
    }
    
    // MARK: - Profile & Contacts (Placeholder)
    
    /// Fetch profile from pubky.app
    public func fetchProfile(pubkey: String) async throws -> PubkyProfile {
        throw PubkySDKError.notInitialized
    }
    
    public func fetchFollows(pubkey: String) async throws -> [String] {
        throw PubkySDKError.notInitialized
    }
    
    // MARK: - DNS Resolution (Placeholder)
    
    public func resolveHomeserver(pubkey: String) async throws -> String? {
        throw PubkySDKError.notInitialized
    }
    
    // MARK: - Persistence
    
    public func storeSessions() {
        // TODO: Implement session persistence
    }
    
    public func restoreSessions() {
        // TODO: Implement session restoration
    }
    
    // MARK: - Helpers
    
    private func ensureInitialized() {
        if !isInitialized {
            configure()
        }
    }
}
