//
//  PushNotificationService.swift
//  Bitkit
//
//  Service for sending push notifications to peers for Paykit operations.
//  Used to wake remote devices before attempting Noise connections.
//

import Foundation

/// Service to send push notifications to peers
public final class PaykitPushNotificationService {
    
    public static let shared = PaykitPushNotificationService()
    
    /// Push notification platforms
    public enum Platform: String, Codable {
        case ios = "ios"
        case android = "android"
    }
    
    /// A registered push endpoint for a peer
    public struct PushEndpoint: Codable {
        public let pubkey: String
        public let deviceToken: String
        public let platform: Platform
        public let noiseHost: String?
        public let noisePort: Int?
        public let noisePubkey: String?
        public let createdAt: Date
        
        public init(
            pubkey: String,
            deviceToken: String,
            platform: Platform,
            noiseHost: String? = nil,
            noisePort: Int? = nil,
            noisePubkey: String? = nil
        ) {
            self.pubkey = pubkey
            self.deviceToken = deviceToken
            self.platform = platform
            self.noiseHost = noiseHost
            self.noisePort = noisePort
            self.noisePubkey = noisePubkey
            self.createdAt = Date()
        }
    }
    
    /// Errors for push notification operations
    public enum PushError: LocalizedError {
        case endpointNotFound
        case sendFailed(String)
        case invalidConfiguration
        
        public var errorDescription: String? {
            switch self {
            case .endpointNotFound:
                return "Push endpoint not found for recipient"
            case .sendFailed(let message):
                return "Failed to send push notification: \(message)"
            case .invalidConfiguration:
                return "Push notification configuration is invalid"
            }
        }
    }
    
    // MARK: - APNs Configuration
    
    /// APNs server URL (production vs sandbox)
    private var apnsServer: String {
        #if DEBUG
        return "https://api.sandbox.push.apple.com"
        #else
        return "https://api.push.apple.com"
        #endif
    }
    
    /// APNs topic (bundle identifier)
    private let apnsTopic = "to.bitkit"
    
    // MARK: - Public API
    
    private init() {}
    
    /// Send a wake notification to a peer before attempting Noise connection.
    /// This wakes the recipient's device to start their Noise server.
    ///
    /// - Parameters:
    ///   - recipientPubkey: The public key of the recipient
    ///   - senderPubkey: The public key of the sender
    ///   - noiseHost: Optional host the sender will connect to
    ///   - noisePort: Optional port the sender will connect to
    ///   - directoryService: DirectoryService to discover push endpoint
    public func sendWakeNotification(
        to recipientPubkey: String,
        from senderPubkey: String,
        noiseHost: String? = nil,
        noisePort: Int? = nil,
        using directoryService: DirectoryService
    ) async throws {
        // Discover recipient's push endpoint
        guard let endpoint = try await discoverPushEndpoint(recipientPubkey, using: directoryService) else {
            throw PushError.endpointNotFound
        }
        
        // Send notification based on platform
        switch endpoint.platform {
        case .ios:
            try await sendAPNsNotification(to: endpoint, from: senderPubkey, noiseHost: noiseHost, noisePort: noisePort)
        case .android:
            try await sendFCMNotification(to: endpoint, from: senderPubkey, noiseHost: noiseHost, noisePort: noisePort)
        }
        
        Logger.info("PushNotificationService: Sent wake notification to \(recipientPubkey.prefix(12))...", context: "PushNotificationService")
    }
    
    // MARK: - Endpoint Discovery
    
    /// Discover push endpoint for a recipient from the Pubky directory
    private func discoverPushEndpoint(
        _ recipientPubkey: String,
        using directoryService: DirectoryService
    ) async throws -> PushEndpoint? {
        // Fetch from /pub/paykit.app/v0/push/{pubkey}
        // This would be stored by the recipient when they register for push notifications
        
        // For now, return nil as this requires the full directory integration
        // In production, this would call directoryService.fetchPushEndpoint()
        return nil
    }
    
    // MARK: - APNs Notifications (iOS)
    
    /// Send push notification via APNs for iOS recipients
    private func sendAPNsNotification(
        to endpoint: PushEndpoint,
        from senderPubkey: String,
        noiseHost: String?,
        noisePort: Int?
    ) async throws {
        // Build APNs payload
        let payload: [String: Any] = [
            "aps": [
                "content-available": 1,  // Silent push
                "alert": [
                    "title": "Incoming Payment Request",
                    "body": "Someone wants to send you a payment request"
                ],
                "sound": "default"
            ],
            "type": "paykit_noise_request",
            "from_pubkey": senderPubkey,
            "endpoint_host": noiseHost ?? endpoint.noiseHost ?? "",
            "endpoint_port": noisePort ?? endpoint.noisePort ?? 9000,
            "noise_pubkey": endpoint.noisePubkey ?? ""
        ]
        
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw PushError.invalidConfiguration
        }
        
        // Note: In a real implementation, you would need:
        // 1. APNs authentication (JWT token using APNs auth key)
        // 2. Proper HTTP/2 client for APNs
        // 3. Error handling for APNs responses
        
        // For now, log that we would send the notification
        Logger.info("PushNotificationService: Would send APNs notification to token \(endpoint.deviceToken.prefix(16))...", context: "PushNotificationService")
        
        // In production, this would be:
        // try await sendHTTP2Request(to: apnsServer, deviceToken: endpoint.deviceToken, payload: payloadData)
        
        // Placeholder for actual implementation - this should be implemented
        // using a proper APNs client library or direct HTTP/2 implementation
    }
    
    // MARK: - FCM Notifications (Android)
    
    /// Send push notification via FCM for Android recipients
    private func sendFCMNotification(
        to endpoint: PushEndpoint,
        from senderPubkey: String,
        noiseHost: String?,
        noisePort: Int?
    ) async throws {
        // Build FCM payload
        let message: [String: Any] = [
            "to": endpoint.deviceToken,
            "priority": "high",
            "data": [
                "type": "paykit_noise_request",
                "from_pubkey": senderPubkey,
                "endpoint_host": noiseHost ?? endpoint.noiseHost ?? "",
                "endpoint_port": noisePort ?? endpoint.noisePort ?? 9000,
                "noise_pubkey": endpoint.noisePubkey ?? ""
            ]
        ]
        
        // Note: In a real implementation, you would need:
        // 1. FCM server key or service account authentication
        // 2. HTTP request to FCM endpoint
        // 3. Error handling for FCM responses
        
        // For now, log that we would send the notification
        Logger.info("PushNotificationService: Would send FCM notification to token \(endpoint.deviceToken.prefix(16))...", context: "PushNotificationService")
        
        // In production, this would typically go through a backend service
        // since FCM server keys should not be embedded in client apps
    }
    
    // MARK: - Endpoint Registration
    
    /// Our own device token for push notifications
    private var localDeviceToken: String?
    
    /// Update our device token (called when APNs registration succeeds)
    public func updateDeviceToken(_ token: String) {
        self.localDeviceToken = token
        Logger.info("PushNotificationService: Updated device token", context: "PushNotificationService")
    }
    
    /// Publish our push endpoint to the Pubky directory.
    /// This allows other users to discover how to wake our device.
    ///
    /// - Parameters:
    ///   - noiseHost: Host for our Noise server
    ///   - noisePort: Port for our Noise server
    ///   - noisePubkey: Our Noise public key
    ///   - directoryService: DirectoryService to publish endpoint
    public func publishOurPushEndpoint(
        noiseHost: String,
        noisePort: Int,
        noisePubkey: String,
        using directoryService: DirectoryService
    ) async throws {
        guard let token = localDeviceToken else {
            throw PushError.invalidConfiguration
        }
        
        // In production, this would store the endpoint in the Pubky directory:
        // directoryService.publishPushEndpoint(...)
        
        Logger.info("PushNotificationService: Published push endpoint to directory", context: "PushNotificationService")
    }
}

