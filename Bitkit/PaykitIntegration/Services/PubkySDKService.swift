//  PubkySDKService.swift
//  Bitkit
//
//  Service for managing Pubky SDK operations (sign-in, session management, storage)
//
//  NOTE: This is currently a stub implementation. Full pubky SDK FFI integration
//  will be added in a future update when BitkitCore exposes the complete pubky SDK FFI.

import Foundation

// MARK: - PubkySDKService

public final class PubkySDKService {
    public static let shared = PubkySDKService()
    
    private var homeserver: String = ""
    
    private init() {
        Logger.info("PubkySDKService initialized (stub implementation)", context: "PubkySDKService")
    }
    
    // MARK: - Configuration
    
    public func configure(homeserver: String = "https://demo.httprelay.io/pubky") {
        self.homeserver = homeserver
        Logger.info("PubkySDKService configured with homeserver: \(self.homeserver)", context: "PubkySDKService")
    }
    
    // MARK: - Session Management (Stubs)
    
    public func refreshExpiringSessions() async {
        // Stub: No-op for now
        Logger.debug("refreshExpiringSessions called (stub)", context: "PubkySDKService")
    }
    
    // MARK: - Profile & Contacts (Stubs)
    
    public func fetchProfile(pubkey: String) async throws -> PubkyProfile {
        // Stub: Return empty profile
        Logger.debug("fetchProfile called for \(pubkey) (stub)", context: "PubkySDKService")
        throw PubkySDKError.notImplemented("fetchProfile is not yet implemented")
    }
    
    public func fetchFollows(pubkey: String) async throws -> [String] {
        // Stub: Return empty array
        Logger.debug("fetchFollows called for \(pubkey) (stub)", context: "PubkySDKService")
        throw PubkySDKError.notImplemented("fetchFollows is not yet implemented")
    }
    
    // MARK: - Persistence (Stubs)
    
    public func storeSessions() {
        // Stub: No-op for now
    }
    
    public func restoreSessions() {
        // Stub: No-op for now
    }
}

// MARK: - Supporting Types

public struct PubkySessionInfo {
    public let pubkey: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let expiresAt: UInt64?
}

public struct PubkyProfile: Codable {
    public let name: String?
    public let bio: String?
    public let image: String?
    public let links: [String]?
    public let status: String?
}

public enum PubkySDKError: Error, LocalizedError {
    case notImplemented(String)
    case invalidInput(String)
    case sessionNotFound(String)
    case networkError(String)
    
    public var errorDescription: String? {
        switch self {
        case .notImplemented(let message):
            return "Not implemented: \(message)"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .sessionNotFound(let message):
            return "Session not found: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
    
    public var userFriendlyMessage: String {
        switch self {
        case .notImplemented:
            return "This feature is not yet available"
        case .invalidInput:
            return "Invalid input provided"
        case .sessionNotFound:
            return "Session not found. Please sign in again."
        case .networkError:
            return "Network error. Please check your connection."
        }
    }
}
