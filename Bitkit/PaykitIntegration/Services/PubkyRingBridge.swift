// PubkyRingBridge.swift
// Bitkit iOS - Paykit Integration
//
// Bridge for communicating with Pubky-ring app via URL schemes.
// Handles session retrieval and noise key derivation requests.
// Supports both same-device and cross-device authentication flows.

import Foundation
import UIKit
import CoreImage

// MARK: - PubkyRingBridge

/// Bridge service for communicating with Pubky-ring app via URL schemes.
///
/// Pubky-ring handles:
/// - Session management (sign in/sign up to homeserver)
/// - Key derivation from Ed25519 seed
/// - Profile and follows management
///
/// Communication Flows:
///
/// **Same Device:**
/// 1. Bitkit sends request via URL scheme: `pubkyring://session?callback=bitkit://paykit-session`
/// 2. Pubky-ring prompts user to select a pubky
/// 3. Pubky-ring signs in to homeserver
/// 4. Pubky-ring opens callback URL with data: `bitkit://paykit-session?pubky=...&session_secret=...`
///
/// **Cross Device (QR/Link):**
/// 1. Bitkit generates a session request URL/QR with request_id
/// 2. User scans QR or opens link on device with Pubky-ring
/// 3. Pubky-ring processes request and publishes session to relay/homeserver
/// 4. Bitkit polls relay for session response using request_id
public final class PubkyRingBridge {
    
    // MARK: - Singleton
    
    public static let shared = PubkyRingBridge()
    
    // MARK: - Constants
    
    private let pubkyRingScheme = "pubkyring"
    private let bitkitScheme = "bitkit"
    
    /// Web URL for cross-device authentication
    public static var crossDeviceWebUrl: String {
        if let envUrl = ProcessInfo.processInfo.environment["PUBKY_CROSS_DEVICE_URL"] {
            return envUrl
        }
        return "https://pubky.app/auth"
    }
    
    /// Relay endpoint for cross-device session exchange
    public static var sessionRelayUrl: String {
        if let envUrl = ProcessInfo.processInfo.environment["PUBKY_RELAY_URL"] {
            return envUrl
        }
        // Default production relay
        return "https://relay.pubky.app/sessions"
    }
    
    // Callback paths for different request types
    public struct CallbackPaths {
        public static let session = "paykit-session"
        public static let keypair = "paykit-keypair"
        public static let profile = "paykit-profile"
        public static let follows = "paykit-follows"
        public static let crossDeviceSession = "paykit-cross-session"
    }
    
    // MARK: - State
    
    /// Pending session request continuation
    private var pendingSessionContinuation: CheckedContinuation<PubkySession, Error>?
    
    /// Pending keypair request continuation
    private var pendingKeypairContinuation: CheckedContinuation<NoiseKeypair, Error>?
    
    /// Pending cross-device request ID
    private var pendingCrossDeviceRequestId: String?
    
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
    
    // MARK: - Cross-Device Authentication
    
    /// Generate a cross-device session request that can be shared as a link or QR
    ///
    /// This creates a unique request ID and returns both a URL and QR code data
    /// that can be used on another device running Pubky-ring.
    ///
    /// - Returns: CrossDeviceRequest with URL, QR code, and request ID
    public func generateCrossDeviceRequest() -> CrossDeviceRequest {
        let requestId = UUID().uuidString.lowercased()
        pendingCrossDeviceRequestId = requestId
        
        // Build the URL for cross-device auth
        // Format: https://pubky.app/auth?request_id=xxx&callback_scheme=bitkit&app_name=Bitkit
        var components = URLComponents(string: PubkyRingBridge.crossDeviceWebUrl)!
        components.queryItems = [
            URLQueryItem(name: "request_id", value: requestId),
            URLQueryItem(name: "callback_scheme", value: bitkitScheme),
            URLQueryItem(name: "app_name", value: "Bitkit"),
            URLQueryItem(name: "relay_url", value: PubkyRingBridge.sessionRelayUrl)
        ]
        
        let url = components.url!
        let qrImage = generateQRCode(from: url.absoluteString)
        
        return CrossDeviceRequest(
            requestId: requestId,
            url: url,
            qrCodeImage: qrImage,
            expiresAt: Date().addingTimeInterval(300) // 5 minutes
        )
    }
    
    /// Poll for a cross-device session response
    ///
    /// After the user scans the QR or opens the link on another device,
    /// Pubky-ring will publish the session to the relay. This method polls
    /// the relay for the response.
    ///
    /// - Parameters:
    ///   - requestId: The request ID from generateCrossDeviceRequest()
    ///   - timeout: Maximum time to wait (default 5 minutes)
    /// - Returns: PubkySession if successful
    /// - Throws: PubkyRingError on timeout or failure
    public func pollForCrossDeviceSession(requestId: String, timeout: TimeInterval = 300) async throws -> PubkySession {
        let startTime = Date()
        let pollInterval: TimeInterval = 2.0 // Poll every 2 seconds
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if session arrived via direct callback
            if let session = sessionCache.values.first(where: { _ in pendingCrossDeviceRequestId == nil }) {
                return session
            }
            
            // Poll relay for session
            if let session = try? await pollRelayForSession(requestId: requestId) {
                sessionCache[session.pubkey] = session
                pendingCrossDeviceRequestId = nil
                return session
            }
            
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        pendingCrossDeviceRequestId = nil
        throw PubkyRingError.timeout
    }
    
    /// Import a session manually (for offline/manual cross-device flow)
    ///
    /// Users can manually enter session data if QR/link flow isn't available.
    ///
    /// - Parameters:
    ///   - pubkey: The z-base32 encoded public key
    ///   - sessionSecret: The session secret from Pubky-ring
    ///   - capabilities: Optional list of capabilities
    /// - Returns: Imported PubkySession
    public func importSession(pubkey: String, sessionSecret: String, capabilities: [String] = []) -> PubkySession {
        let session = PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: capabilities,
            createdAt: Date()
        )
        sessionCache[pubkey] = session
        return session
    }
    
    /// Generate a shareable link for cross-device auth
    public func generateShareableLink() -> URL {
        let request = generateCrossDeviceRequest()
        return request.url
    }
    
    // MARK: - Private Cross-Device Helpers
    
    private func pollRelayForSession(requestId: String) async throws -> PubkySession? {
        let urlString = "\(PubkyRingBridge.sessionRelayUrl)/\(requestId)"
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            
            if httpResponse.statusCode == 404 {
                // Session not yet available
                return nil
            }
            
            if httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let session = try decoder.decode(PubkySession.self, from: data)
                return session
            }
            
            return nil
        } catch {
            Logger.debug("Relay poll failed: \(error)", context: "PubkyRingBridge")
            return nil
        }
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)
        
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up the QR code for better resolution
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)
        
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Graceful Degradation Helpers
    
    /// Get the current authentication availability status
    public var authenticationStatus: AuthenticationStatus {
        if isPubkyRingInstalled {
            return .pubkyRingAvailable
        } else {
            return .crossDeviceOnly
        }
    }
    
    /// Check if any authentication method is available
    public var canAuthenticate: Bool {
        true // Cross-device is always available as fallback
    }
    
    /// Get recommended authentication method
    public var recommendedAuthMethod: AuthMethod {
        if isPubkyRingInstalled {
            return .sameDevice
        } else {
            return .crossDevice
        }
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
        case CallbackPaths.crossDeviceSession:
            return handleCrossDeviceSessionCallback(url: url)
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
    
    private func handleCrossDeviceSessionCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return false
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        // Verify request ID matches
        if let requestId = params["request_id"], requestId != pendingCrossDeviceRequestId {
            Logger.warn("Cross-device request ID mismatch", context: "PubkyRingBridge")
            return false
        }
        
        guard let pubkey = params["pubky"],
              let sessionSecret = params["session_secret"] else {
            return false
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
        pendingCrossDeviceRequestId = nil
        
        // Note: For cross-device, the session is stored in cache
        // The polling task will pick it up
        
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
    case crossDeviceFailed(String)
    
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
        case .crossDeviceFailed(let reason):
            return "Cross-device authentication failed: \(reason)"
        }
    }
    
    /// User-friendly message for UI display
    public var userMessage: String {
        switch self {
        case .appNotInstalled:
            return "Pubky-ring is not installed on this device. You can use the QR code option to authenticate from another device."
        case .invalidUrl, .invalidCallback, .missingParameters:
            return "Something went wrong. Please try again."
        case .failedToOpenApp:
            return "Could not open Pubky-ring. Please make sure it's installed correctly."
        case .timeout:
            return "The request timed out. Please try again."
        case .cancelled:
            return "Authentication was cancelled."
        case .crossDeviceFailed:
            return "Cross-device authentication failed. Please try again."
        }
    }
}

// MARK: - Cross-Device Authentication Models

/// Cross-device session request data
public struct CrossDeviceRequest {
    /// Unique request identifier
    public let requestId: String
    
    /// URL to share or open in browser
    public let url: URL
    
    /// QR code image for scanning
    public let qrCodeImage: UIImage?
    
    /// When this request expires
    public let expiresAt: Date
    
    /// Whether this request has expired
    public var isExpired: Bool {
        Date() > expiresAt
    }
    
    /// Time remaining until expiration
    public var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}

/// Authentication method
public enum AuthMethod {
    /// Direct communication with Pubky-ring on same device
    case sameDevice
    
    /// QR code/link for authentication from another device
    case crossDevice
    
    /// Manual session entry
    case manual
}

/// Current authentication availability status
public enum AuthenticationStatus {
    /// Pubky-ring is installed and available
    case pubkyRingAvailable
    
    /// Only cross-device authentication is available
    case crossDeviceOnly
    
    /// User-friendly description
    public var description: String {
        switch self {
        case .pubkyRingAvailable:
            return "Pubky-ring is available on this device"
        case .crossDeviceOnly:
            return "Use QR code to authenticate from another device"
        }
    }
}

