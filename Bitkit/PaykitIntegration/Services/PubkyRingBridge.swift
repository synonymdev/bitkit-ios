// PubkyRingBridge.swift
// Bitkit iOS - Paykit Integration
//
// Bridge for communicating with Pubky-ring app via URL schemes.
// Handles session retrieval and noise key derivation requests.

import Foundation
import UIKit

// MARK: - PubkyRingBridge

/// Bridge service for communicating with Pubky-ring app via URL schemes.
///
/// Pubky-ring handles:
/// - Session management (sign in/sign up to homeserver)
/// - Key derivation from Ed25519 seed
/// - Profile and follows management
///
/// Communication Flow:
/// 1. Bitkit sends request via URL scheme: `pubkyring://session?callback=bitkit://paykit-session`
/// 2. Pubky-ring prompts user to select a pubky
/// 3. Pubky-ring signs in to homeserver
/// 4. Pubky-ring opens callback URL with data: `bitkit://paykit-session?pubky=...&session_secret=...`
public final class PubkyRingBridge {
    
    // MARK: - Singleton
    
    public static let shared = PubkyRingBridge()
    
    // MARK: - Constants
    
    private let pubkyRingScheme = "pubkyring"
    private let bitkitScheme = "bitkit"
    
    // Callback paths for different request types
    public struct CallbackPaths {
        public static let session = "paykit-session"
        public static let keypair = "paykit-keypair"
        public static let profile = "paykit-profile"
        public static let follows = "paykit-follows"
    }
    
    // MARK: - State
    
    /// Pending session request continuation
    private var pendingSessionContinuation: CheckedContinuation<PubkySession, Error>?
    
    /// Pending keypair request continuation
    private var pendingKeypairContinuation: CheckedContinuation<NoiseKeypair, Error>?
    
    /// Cached sessions by pubkey
    private var sessionCache: [String: PubkySession] = [:]
    
    /// Cached keypairs by derivation path
    private var keypairCache: [String: NoiseKeypair] = [:]
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Check if Pubky-ring app is installed
    public var isPubkyRingInstalled: Bool {
        guard let url = URL(string: "\(pubkyRingScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
    
    /// Request a session from Pubky-ring
    ///
    /// Opens Pubky-ring app which will:
    /// 1. Prompt user to select a pubky
    /// 2. Sign in to homeserver
    /// 3. Return session data via callback URL
    ///
    /// - Returns: PubkySession with pubkey, session secret, and capabilities
    /// - Throws: PubkyRingError if request fails or app not installed
    public func requestSession() async throws -> PubkySession {
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.session)"
        let requestUrl = "\(pubkyRingScheme)://session?callback=\(callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingSessionContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingSessionContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingSessionContinuation = nil
                    }
                }
            }
        }
    }
    
    /// Request a noise keypair derivation from Pubky-ring
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier for key derivation
    ///   - epoch: Epoch for key rotation
    /// - Returns: X25519 keypair for Noise protocol
    /// - Throws: PubkyRingError if request fails
    public func requestNoiseKeypair(deviceId: String, epoch: UInt64) async throws -> NoiseKeypair {
        // Check cache first
        let cacheKey = "\(deviceId):\(epoch)"
        if let cached = keypairCache[cacheKey] {
            return cached
        }
        
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.keypair)"
        let requestUrl = "\(pubkyRingScheme)://derive-keypair?deviceId=\(deviceId)&epoch=\(epoch)&callback=\(callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingKeypairContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingKeypairContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingKeypairContinuation = nil
                    }
                }
            }
        }
    }
    
    /// Get cached session for a pubkey
    public func getCachedSession(for pubkey: String) -> PubkySession? {
        sessionCache[pubkey]
    }
    
    /// Clear all cached data
    public func clearCache() {
        sessionCache.removeAll()
        keypairCache.removeAll()
    }
    
    // MARK: - URL Handling
    
    /// Handle incoming URL callback from Pubky-ring
    ///
    /// Call this from your AppDelegate or SceneDelegate's URL handling method.
    ///
    /// - Parameter url: The callback URL from Pubky-ring
    /// - Returns: True if the URL was handled
    @discardableResult
    public func handleCallback(url: URL) -> Bool {
        guard url.scheme == bitkitScheme else { return false }
        
        let path = url.host ?? url.path
        
        switch path {
        case CallbackPaths.session:
            return handleSessionCallback(url: url)
        case CallbackPaths.keypair:
            return handleKeypairCallback(url: url)
        default:
            return false
        }
    }
    
    // MARK: - Private Methods
    
    private func handleSessionCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingSessionContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingSessionContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        guard let pubkey = params["pubky"],
              let sessionSecret = params["session_secret"] else {
            pendingSessionContinuation?.resume(throwing: PubkyRingError.missingParameters)
            pendingSessionContinuation = nil
            return true
        }
        
        let capabilities = params["capabilities"]?.components(separatedBy: ",") ?? []
        
        let session = PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: capabilities,
            createdAt: Date()
        )
        
        // Cache the session
        sessionCache[pubkey] = session
        
        pendingSessionContinuation?.resume(returning: session)
        pendingSessionContinuation = nil
        
        return true
    }
    
    private func handleKeypairCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingKeypairContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingKeypairContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        guard let publicKey = params["public_key"],
              let secretKey = params["secret_key"],
              let deviceId = params["device_id"],
              let epochStr = params["epoch"],
              let epoch = UInt64(epochStr) else {
            pendingKeypairContinuation?.resume(throwing: PubkyRingError.missingParameters)
            pendingKeypairContinuation = nil
            return true
        }
        
        let keypair = NoiseKeypair(
            publicKey: publicKey,
            secretKey: secretKey,
            deviceId: deviceId,
            epoch: epoch
        )
        
        // Cache the keypair
        let cacheKey = "\(deviceId):\(epoch)"
        keypairCache[cacheKey] = keypair
        
        pendingKeypairContinuation?.resume(returning: keypair)
        pendingKeypairContinuation = nil
        
        return true
    }
}

// MARK: - Data Models

/// Session data returned from Pubky-ring
public struct PubkySession: Codable {
    public let pubkey: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let createdAt: Date
    
    /// Check if session has a specific capability
    public func hasCapability(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
}

/// X25519 keypair for Noise protocol
public struct NoiseKeypair: Codable {
    public let publicKey: String
    public let secretKey: String
    public let deviceId: String
    public let epoch: UInt64
}

// MARK: - Errors

public enum PubkyRingError: LocalizedError {
    case appNotInstalled
    case invalidUrl
    case failedToOpenApp
    case invalidCallback
    case missingParameters
    case timeout
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .appNotInstalled:
            return "Pubky-ring app is not installed"
        case .invalidUrl:
            return "Invalid URL for Pubky-ring request"
        case .failedToOpenApp:
            return "Failed to open Pubky-ring app"
        case .invalidCallback:
            return "Invalid callback from Pubky-ring"
        case .missingParameters:
            return "Missing parameters in Pubky-ring callback"
        case .timeout:
            return "Request to Pubky-ring timed out"
        case .cancelled:
            return "Request was cancelled"
        }
    }
}

