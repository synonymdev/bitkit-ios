//
//  PaykitPollingService.swift
//  Bitkit
//
//  Service for periodically polling the Pubky directory for pending payment requests.
//  Uses BGAppRefreshTask for background polling when app is suspended.
//

import BackgroundTasks
import Foundation
import UserNotifications

/// Service for discovering pending payment requests from the Pubky directory.
///
/// This service periodically polls for:
/// - Incoming payment requests
/// - Subscription proposals
/// - Pending approvals
///
/// When a new request is found, it can:
/// 1. Trigger a local notification to the user
/// 2. Evaluate auto-pay rules and execute payment if approved
/// 3. Queue the request for manual review
public final class PaykitPollingService {
    
    // MARK: - Singleton
    
    public static let shared = PaykitPollingService()
    
    // MARK: - Constants
    
    /// Background task identifier - must be registered in Info.plist
    public static let taskIdentifier = "to.bitkit.paykit.polling"
    
    /// Minimum interval between polls (15 minutes - iOS minimum)
    private let minimumPollInterval: TimeInterval = 15 * 60
    
    /// Foreground poll interval (5 minutes)
    private let foregroundPollInterval: TimeInterval = 5 * 60
    
    // MARK: - State
    
    /// Currently polling
    private var isPolling = false
    
    /// Timer for foreground polling
    private var foregroundTimer: Timer?
    
    /// Last poll timestamp
    private var lastPollTime: Date?
    
    /// Discovered request IDs (to avoid duplicate notifications)
    private var seenRequestIds: Set<String> = []
    
    // MARK: - Dependencies
    
    private let directoryService: DirectoryService
    
    // MARK: - Initialization
    
    private init() {
        self.directoryService = DirectoryService.shared
    }
    
    // MARK: - Public API
    
    /// Register background task with the system.
    /// Call this from AppDelegate's didFinishLaunchingWithOptions.
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PaykitPollingService.taskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundPoll(task: task as! BGAppRefreshTask)
        }
        Logger.info("PaykitPollingService: Registered background task", context: "PaykitPollingService")
    }
    
    /// Verify that background task is scheduled
    private func verifyBackgroundTaskScheduled() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let hasPollingTask = requests.contains { $0.identifier == Self.taskIdentifier }
            if hasPollingTask {
                Logger.debug("PaykitPollingService: Background task verified as scheduled", context: "PaykitPollingService")
            } else {
                Logger.warn("PaykitPollingService: Background task not found in pending requests", context: "PaykitPollingService")
            }
        }
    }
    
    /// Schedule a background app refresh task.
    /// Call this when the app enters the background.
    public func scheduleBackgroundPoll() {
        let request = BGAppRefreshTaskRequest(identifier: PaykitPollingService.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumPollInterval)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.info("PaykitPollingService: Scheduled background poll for \(request.earliestBeginDate?.description ?? "unknown")", context: "PaykitPollingService")
            
            // Verify scheduling
            verifyBackgroundTaskScheduled()
        } catch {
            Logger.error("PaykitPollingService: Failed to schedule background poll: \(error)", context: "PaykitPollingService")
        }
    }
    
    /// Start foreground polling.
    /// Call this when the app enters the foreground.
    public func startForegroundPolling() {
        stopForegroundPolling()
        
        // Poll immediately
        Task {
            await poll()
        }
        
        // Schedule periodic polling
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: foregroundPollInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.poll()
            }
        }
        
        Logger.info("PaykitPollingService: Started foreground polling", context: "PaykitPollingService")
    }
    
    /// Stop foreground polling.
    /// Call this when the app enters the background.
    public func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
        Logger.info("PaykitPollingService: Stopped foreground polling", context: "PaykitPollingService")
    }
    
    /// Manually trigger a poll.
    @MainActor
    public func pollNow() async {
        await poll()
    }
    
    // MARK: - Background Task Handler
    
    private func handleBackgroundPoll(task: BGAppRefreshTask) {
        Logger.info("PaykitPollingService: Starting background poll", context: "PaykitPollingService")
        
        // Schedule next poll
        scheduleBackgroundPoll()
        
        // Set expiration handler
        task.expirationHandler = { [weak self] in
            Logger.warn("PaykitPollingService: Background poll expired", context: "PaykitPollingService")
            self?.isPolling = false
            task.setTaskCompleted(success: false)
        }
        
        Task {
            do {
                let newRequests = try await performPoll()
                
                // Process new requests
                for request in newRequests {
                    await handleNewRequest(request)
                }
                
                Logger.info("PaykitPollingService: Background poll completed, found \(newRequests.count) new requests", context: "PaykitPollingService")
                task.setTaskCompleted(success: true)
            } catch {
                Logger.error("PaykitPollingService: Background poll failed: \(error)", context: "PaykitPollingService")
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    // MARK: - Polling Logic
    
    private func poll() async {
        guard !isPolling else {
            Logger.debug("PaykitPollingService: Already polling, skipping", context: "PaykitPollingService")
            return
        }
        
        isPolling = true
        defer { isPolling = false }
        
        do {
            let newRequests = try await performPoll()
            
            for request in newRequests {
                await handleNewRequest(request)
            }
            
            lastPollTime = Date()
            Logger.info("PaykitPollingService: Poll completed, found \(newRequests.count) new requests", context: "PaykitPollingService")
        } catch {
            Logger.error("PaykitPollingService: Poll failed: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func performPoll() async throws -> [DiscoveredRequest] {
        var newRequests: [DiscoveredRequest] = []
        
        // Get our pubkey from Paykit
        guard let ownerPubkey = PaykitManager.shared.ownerPubkey else {
            Logger.warn("PaykitPollingService: No owner pubkey configured", context: "PaykitPollingService")
            return []
        }
        
        // Discover pending payment requests from directory
        let paymentRequests = try await directoryService.discoverPendingRequests(for: ownerPubkey)
        for request in paymentRequests {
            // Filter out requests we've already seen
            if !seenRequestIds.contains(request.requestId) {
                seenRequestIds.insert(request.requestId)
                newRequests.append(request)
            }
        }
        
        Logger.debug("PaykitPollingService: Found \(paymentRequests.count) payment requests, \(newRequests.count) new", context: "PaykitPollingService")
        
        // Discover subscription proposals
        let proposals = try await directoryService.discoverSubscriptionProposals(for: ownerPubkey)
        for proposal in proposals {
            let request = DiscoveredRequest(
                requestId: proposal.subscriptionId,
                type: .subscriptionProposal,
                fromPubkey: proposal.providerPubkey,
                amountSats: proposal.amountSats,
                description: proposal.description,
                createdAt: proposal.createdAt
            )
            if !seenRequestIds.contains(request.requestId) {
                seenRequestIds.insert(request.requestId)
                newRequests.append(request)
            }
        }
        
        Logger.debug("PaykitPollingService: Found \(proposals.count) subscription proposals", context: "PaykitPollingService")
        
        return newRequests
    }
    
    private func handleNewRequest(_ request: DiscoveredRequest) async {
        Logger.info("PaykitPollingService: Handling new request \(request.requestId) of type \(request.type)", context: "PaykitPollingService")
        
        switch request.type {
        case .paymentRequest:
            await handlePaymentRequest(request)
        case .subscriptionProposal:
            await handleSubscriptionProposal(request)
        }
    }
    
    private func handlePaymentRequest(_ request: DiscoveredRequest) async {
        // Check auto-pay rules
        let autoPayDecision = await evaluateAutoPay(for: request)
        
        switch autoPayDecision {
        case .approved(let ruleName):
            Logger.info("PaykitPollingService: Auto-pay approved for request \(request.requestId) by rule: \(ruleName ?? "default")", context: "PaykitPollingService")
            
            // Execute payment
            do {
                try await executePayment(for: request)
                await sendPaymentSuccessNotification(for: request)
            } catch {
                Logger.error("PaykitPollingService: Auto-pay failed for request \(request.requestId): \(error)", context: "PaykitPollingService")
                await sendPaymentFailureNotification(for: request, error: error)
            }
            
        case .denied(let reason):
            Logger.info("PaykitPollingService: Auto-pay denied for request \(request.requestId): \(reason)", context: "PaykitPollingService")
            await sendManualApprovalNotification(for: request)
            
        case .needsManualApproval:
            await sendManualApprovalNotification(for: request)
        }
    }
    
    private func handleSubscriptionProposal(_ request: DiscoveredRequest) async {
        // Subscription proposals always need manual approval
        await sendSubscriptionProposalNotification(for: request)
    }
    
    // MARK: - Auto-Pay Evaluation
    
    private func evaluateAutoPay(for request: DiscoveredRequest) async -> AutoPayDecision {
        // Check if auto-pay is enabled via AutoPayStorage
        let autoPayStorage = AutoPayStorage.shared
        
        guard autoPayStorage.isEnabled else {
            return .needsManualApproval
        }
        
        // Check spending limits
        do {
            let checkResult = try SpendingLimitManager.shared.wouldExceedLimit(
                peerPubkey: request.fromPubkey,
                amountSats: request.amountSats
            )
            
            if checkResult.wouldExceed {
                return .denied(reason: "Would exceed spending limit")
            }
            
            // Check if peer is in allowed list
            if let rule = autoPayStorage.getRule(for: request.fromPubkey) {
                // If rule has max amount, check against it
                if let maxAmount = rule.maxAmountSats, request.amountSats > maxAmount {
                    return .denied(reason: "Amount exceeds rule limit")
                }
                return .approved(ruleName: rule.name)
            }
            
            return .needsManualApproval
        } catch {
            Logger.error("PaykitPollingService: Auto-pay evaluation failed: \(error)", context: "PaykitPollingService")
            return .needsManualApproval
        }
    }
    
    // MARK: - Payment Execution
    
    private func executePayment(for request: DiscoveredRequest) async throws {
        // Ensure node is ready
        try await waitForNodeReady()
        
        // Execute payment via PaykitPaymentService with spending limit enforcement
        _ = try await PaykitPaymentService.shared.pay(
            to: request.fromPubkey,
            amountSats: UInt64(request.amountSats),
            peerPubkey: request.fromPubkey // Use peer pubkey for spending limit
        )
    }
    
    private func waitForNodeReady() async throws {
        // Wait for LDK node to be ready (node instance exists)
        var attempts = 0
        let maxAttempts = 30  // 30 seconds timeout
        
        while attempts < maxAttempts {
            if LightningService.shared.node != nil {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            attempts += 1
        }
        
        throw PaykitPollingError.nodeNotReady
    }
    
    // MARK: - Notifications
    
    private func sendManualApprovalNotification(for request: DiscoveredRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("payment_request_received", comment: "")
        content.body = String(format: NSLocalizedString("payment_request_from", comment: ""), 
                              formatPubkey(request.fromPubkey), 
                              formatSats(request.amountSats))
        content.sound = .default
        content.userInfo = [
            "type": "paykit_payment_request",
            "requestId": request.requestId
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_request_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
            Logger.debug("PaykitPollingService: Sent approval notification for request \(request.requestId)", context: "PaykitPollingService")
        } catch {
            Logger.error("PaykitPollingService: Failed to send notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func sendPaymentSuccessNotification(for request: DiscoveredRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("payment_sent_auto", comment: "")
        content.body = String(format: NSLocalizedString("payment_sent_to", comment: ""), 
                              formatSats(request.amountSats),
                              formatPubkey(request.fromPubkey))
        content.sound = .default
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_success_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            Logger.error("PaykitPollingService: Failed to send success notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func sendPaymentFailureNotification(for request: DiscoveredRequest, error: Error) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("payment_failed", comment: "")
        content.body = String(format: NSLocalizedString("payment_failed_for", comment: ""), 
                              formatSats(request.amountSats),
                              error.localizedDescription)
        content.sound = .default
        content.userInfo = [
            "type": "paykit_payment_failed",
            "requestId": request.requestId
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_failure_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            Logger.error("PaykitPollingService: Failed to send failure notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func sendSubscriptionProposalNotification(for request: DiscoveredRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("subscription_proposal", comment: "")
        content.body = String(format: NSLocalizedString("subscription_proposal_from", comment: ""), 
                              formatPubkey(request.fromPubkey),
                              formatSats(request.amountSats))
        content.sound = .default
        content.userInfo = [
            "type": "paykit_subscription_proposal",
            "subscriptionId": request.requestId
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_sub_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            Logger.error("PaykitPollingService: Failed to send subscription notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    // MARK: - Helpers
    
    private func formatPubkey(_ pubkey: String) -> String {
        if pubkey.count > 12 {
            return "\(pubkey.prefix(6))...\(pubkey.suffix(6))"
        }
        return pubkey
    }
    
    private func formatSats(_ sats: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: sats)) ?? String(sats)) sats"
    }
}

// MARK: - Data Models

/// A discovered payment request or subscription proposal
public struct DiscoveredRequest {
    public let requestId: String
    public let type: DiscoveredRequestType
    public let fromPubkey: String
    public let amountSats: Int64
    public let description: String?
    public let createdAt: Date
}

public enum DiscoveredRequestType {
    case paymentRequest
    case subscriptionProposal
}

/// Result of auto-pay evaluation
public enum AutoPayDecision {
    case approved(ruleName: String?)
    case denied(reason: String)
    case needsManualApproval
}

/// Subscription proposal discovered from directory
public struct DiscoveredSubscriptionProposal {
    public let subscriptionId: String
    public let providerPubkey: String
    public let amountSats: Int64
    public let description: String?
    public let frequency: String
    public let createdAt: Date
}

// MARK: - Errors

public enum PaykitPollingError: LocalizedError {
    case nodeNotReady
    case paymentFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .nodeNotReady:
            return "Lightning node is not ready"
        case .paymentFailed(let reason):
            return "Payment failed: \(reason)"
        }
    }
}
