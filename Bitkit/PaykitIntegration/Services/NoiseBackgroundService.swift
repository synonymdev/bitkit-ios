//
//  NoiseBackgroundService.swift
//  Bitkit
//
//  Background service for handling incoming Noise protocol connections.
//  Manages background task registration and Noise server lifecycle.
//

import BackgroundTasks
import Foundation
import UserNotifications

/// Notification type for incoming Noise requests
public enum PaykitNoiseNotification {
    /// Notification payload from push notification
    public struct Payload {
        public let fromPubkey: String
        public let endpointHost: String?
        public let endpointPort: Int
        public let noisePubkey: String?
        
        public init?(userInfo: [AnyHashable: Any]) {
            guard let fromPubkey = userInfo["from_pubkey"] as? String else {
                return nil
            }
            
            self.fromPubkey = fromPubkey
            self.endpointHost = userInfo["endpoint_host"] as? String
            self.endpointPort = (userInfo["endpoint_port"] as? Int) ?? 9000
            self.noisePubkey = userInfo["noise_pubkey"] as? String
        }
    }
}

/// Service to manage Noise server background execution
public final class NoiseBackgroundService {
    
    public static let shared = NoiseBackgroundService()
    
    /// Background task identifier for Noise server
    public static let taskIdentifier = "to.bitkit.paykit.noise-server"
    
    /// Default port for Noise server
    public static let defaultPort: UInt16 = 9000
    
    private let noisePaymentService: NoisePaymentService
    private let paymentRequestStorage: PaymentRequestStorage
    
    private init() {
        self.noisePaymentService = NoisePaymentService.shared
        self.paymentRequestStorage = PaymentRequestStorage()
    }
    
    // MARK: - Background Task Registration
    
    /// Register the background task with the system.
    /// Call this from AppDelegate.didFinishLaunchingWithOptions
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let bgTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundTask(bgTask)
        }
        
        Logger.info("NoiseBackgroundService: Registered background task", context: "NoiseBackgroundService")
    }
    
    /// Handle background task execution
    private func handleBackgroundTask(_ task: BGProcessingTask) {
        Logger.info("NoiseBackgroundService: Background task started", context: "NoiseBackgroundService")
        
        // Set up task expiration handler
        task.expirationHandler = { [weak self] in
            Logger.warn("NoiseBackgroundService: Background task expired", context: "NoiseBackgroundService")
            self?.noisePaymentService.stopBackgroundServer()
        }
        
        // Start the server
        Task {
            do {
                try await startServerInBackground(port: Self.defaultPort)
                task.setTaskCompleted(success: true)
            } catch {
                Logger.error("NoiseBackgroundService: Background task failed: \(error)", context: "NoiseBackgroundService")
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    // MARK: - Noise Server Operations
    
    /// Start Noise server in background when woken by push notification
    public func startServerInBackground(port: UInt16) async throws {
        Logger.info("NoiseBackgroundService: Starting server on port \(port)", context: "NoiseBackgroundService")
        
        try await noisePaymentService.startBackgroundServer(port: port) { [weak self] request in
            self?.handleIncomingRequest(request)
        }
    }
    
    /// Handle incoming payment request from Noise channel
    private func handleIncomingRequest(_ noiseRequest: NoisePaymentRequest) {
        // Convert to BitkitPaymentRequest
        let paymentRequest = BitkitPaymentRequest(
            id: noiseRequest.receiptId,
            fromPubkey: noiseRequest.payerPubkey,
            toPubkey: noiseRequest.payeePubkey,
            amountSats: Int64(noiseRequest.amount ?? "0") ?? 0,
            currency: noiseRequest.currency ?? "BTC",
            methodId: noiseRequest.methodId,
            description: noiseRequest.description ?? "",
            createdAt: Date(),
            expiresAt: nil,
            status: .pending,
            direction: .incoming,
            invoiceNumber: noiseRequest.invoiceNumber
        )
        
        // Store the request
        do {
            try paymentRequestStorage.addRequest(paymentRequest)
            Logger.info("NoiseBackgroundService: Stored payment request \(paymentRequest.id)", context: "NoiseBackgroundService")
            
            // Show local notification
            showPaymentRequestNotification(paymentRequest)
            
        } catch {
            Logger.error("NoiseBackgroundService: Failed to store request: \(error)", context: "NoiseBackgroundService")
        }
    }
    
    /// Show a local notification for an incoming payment request
    private func showPaymentRequestNotification(_ request: BitkitPaymentRequest) {
        let content = UNMutableNotificationContent()
        content.title = "Payment Request Received"
        content.body = "Request for \(request.amountSats) sats from \(request.counterpartyName)"
        content.sound = .default
        content.userInfo = [
            "type": "paykit_payment_request",
            "request_id": request.id
        ]
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let notification = UNNotificationRequest(
            identifier: "paykit-request-\(request.id)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(notification) { error in
            if let error = error {
                Logger.error("NoiseBackgroundService: Failed to show notification: \(error)", context: "NoiseBackgroundService")
            }
        }
    }
    
    // MARK: - Push Notification Handling
    
    /// Handle incoming push notification for Noise request.
    /// Call this from AppDelegate.didReceiveRemoteNotification
    public func handleNoiseRequestNotification(_ payload: PaykitNoiseNotification.Payload) {
        Logger.info("NoiseBackgroundService: Received Noise request notification from \(payload.fromPubkey.prefix(12))...", context: "NoiseBackgroundService")
        
        // Schedule background task to start server
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.info("NoiseBackgroundService: Scheduled background task", context: "NoiseBackgroundService")
        } catch {
            Logger.error("NoiseBackgroundService: Failed to schedule background task: \(error)", context: "NoiseBackgroundService")
            
            // Fall back to immediate execution if app is in foreground
            Task {
                do {
                    try await startServerInBackground(port: UInt16(payload.endpointPort))
                } catch {
                    Logger.error("NoiseBackgroundService: Failed to start server immediately: \(error)", context: "NoiseBackgroundService")
                }
            }
        }
    }
    
    /// Check if a notification is a Noise request notification
    public static func isNoiseRequestNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String else { return false }
        return type == "paykit_noise_request"
    }
}

