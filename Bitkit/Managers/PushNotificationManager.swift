import Foundation
import SwiftUI

enum PushNotificationError: Error {
    case deviceTokenNotAvailable
    case paymentExpired
    case nodeNotReady
    case processingFailed(String)
}

final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()
    @Published var deviceToken: String? = nil
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Currently processing incoming payment, if any
    @Published var pendingPaymentInfo: IncomingPaymentInfo? = nil

    /// Whether we're currently processing an incoming payment
    @Published var isProcessingPayment: Bool = false

    private init() {}

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                Logger.debug("Push notification permission granted, requesting device token")
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else if let error {
                Logger.error("Push notification permission denied: \(error)")
            } else {
                Logger.debug("Push notification permission denied by user")
            }
        }
    }

    func updateNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    func updateDeviceToken(_ token: String) {
        DispatchQueue.main.async {
            self.deviceToken = token
        }

        Logger.debug("✅ Device token: \(token)")
    }

    func registerWithBackend(deviceToken: String) async throws {
        try await waitForNodeToBeReady()

        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        Logger.info("Registering device for notifications")

        let isoTimestamp = ISO8601DateFormatter().string(from: Date())
        let messageToSign = "bitkit-notifications\(deviceToken)\(isoTimestamp)"
        let signature = try await LightningService.shared.sign(message: messageToSign)
        let keypair = try Crypto.generateKeyPair()

        Logger.debug("Notification encryption public key: \(keypair.publicKey.hex)")

        // New keypair for each token registration
        if try Keychain.exists(key: .pushNotificationPrivateKey) {
            try? Keychain.delete(key: .pushNotificationPrivateKey)
        }

        try Keychain.save(key: .pushNotificationPrivateKey, data: keypair.privateKey)

        let result = try await CoreService.shared.blocktank.registerDeviceForNotifications(
            deviceToken: deviceToken,
            publicKey: keypair.publicKey.hex,
            features: Env.pushNotificationFeatures.map(\.feature),
            nodeId: nodeId,
            isoTimestamp: isoTimestamp,
            signature: signature
        )

        Logger.debug("Registration result: \(result)")
        Logger.debug("🔔 PushNotificationManager: Successfully registered device token with server")
    }

    func unregister() {
        // Unregister from remote notifications
        UIApplication.shared.unregisterForRemoteNotifications()
        // Unregister from server
        // TODO: This would require a server endpoint to unregister the device
        Logger.debug("Would unregister device from notification server")
        // try await CoreService.shared.blocktank.unregisterDeviceForNotifications()
    }

    func handleNotification(_ userInfo: [AnyHashable: Any]) {
        Logger.debug("📩 Notification received: \(userInfo)")

        // Check if this notification has an associated incoming payment
        if let paymentId = userInfo["incomingPaymentId"] as? String {
            Logger.info("📩 Notification tapped for payment: \(paymentId)")
            // The incoming payment info should already be saved by the extension
            // It will be picked up when the app becomes active
        }
    }

    // MARK: - Incoming Payment Processing

    /// Checks for and processes any pending incoming payments saved by the notification extension.
    /// This should be called when the app becomes active.
    /// - Returns: The incoming payment info if one was found and is still valid
    @discardableResult
    func checkForPendingPayment() -> IncomingPaymentInfo? {
        guard let paymentInfo = IncomingPaymentInfo.load() else {
            Logger.debug("📩 No pending incoming payment found")
            return nil
        }

        Logger.info("📩 Found pending payment: type=\(paymentInfo.paymentType.rawValue), state=\(paymentInfo.state.rawValue)")

        // Check if already processed or expired
        if paymentInfo.state == .completed || paymentInfo.state == .failed {
            Logger.debug("📩 Payment already processed, clearing")
            IncomingPaymentInfo.clear()
            return nil
        }

        if paymentInfo.isExpired {
            Logger.warn("📩 Payment expired, clearing")
            var expired = paymentInfo
            expired.updateState(.expired)
            IncomingPaymentInfo.clear()
            return nil
        }

        DispatchQueue.main.async {
            self.pendingPaymentInfo = paymentInfo
        }

        return paymentInfo
    }

    /// Processes an incoming payment by ensuring the node is running and connected to the LSP.
    /// This is the main entry point for handling payments after the user opens the app.
    /// - Parameter paymentInfo: The incoming payment info to process
    /// - Parameter walletViewModel: The wallet view model for node lifecycle management
    func processIncomingPayment(_ paymentInfo: IncomingPaymentInfo, walletViewModel: WalletViewModel) async {
        Logger.info("📩 Processing incoming payment: \(paymentInfo.id)")

        guard !paymentInfo.isExpired else {
            Logger.warn("📩 Payment expired before processing could start")
            await markPaymentState(.expired)
            return
        }

        await MainActor.run {
            isProcessingPayment = true
        }

        var info = paymentInfo
        info.updateState(.processing)

        do {
            // Step 1: Ensure node is running
            Logger.debug("📩 Step 1: Ensuring node is running...")
            try await ensureNodeRunning(walletViewModel: walletViewModel)

            // Step 2: Connect to LSP peer if specified
            if let lspId = paymentInfo.lspId {
                Logger.debug("📩 Step 2: Connecting to LSP peer...")
                try await connectToLspPeer(lspId: lspId)
            }

            // Step 3: Handle specific payment types
            Logger.debug("📩 Step 3: Handling payment type \(paymentInfo.paymentType.rawValue)...")
            try await handlePaymentType(paymentInfo)

            // Payment processing initiated successfully
            // The actual payment completion will be signaled by LDK events
            Logger.info("📩 Payment processing initiated successfully")

        } catch {
            Logger.error("📩 Payment processing failed: \(error)")
            await markPaymentState(.failed)
        }

        await MainActor.run {
            isProcessingPayment = false
        }
    }

    /// Clears the pending payment after successful processing
    func clearPendingPayment() {
        IncomingPaymentInfo.clear()
        DispatchQueue.main.async {
            self.pendingPaymentInfo = nil
            self.isProcessingPayment = false
        }
        Logger.debug("📩 Cleared pending payment")
    }

    /// Marks the payment as completed (called when payment is received via LDK event)
    func markPaymentCompleted() {
        Task {
            await markPaymentState(.completed)
            clearPendingPayment()
        }
    }

    // MARK: - Private Processing Helpers

    private func markPaymentState(_ state: IncomingPaymentInfo.ProcessingState) async {
        if var info = pendingPaymentInfo {
            info.updateState(state)
            await MainActor.run {
                pendingPaymentInfo = info
            }
        }
    }

    private func ensureNodeRunning(walletViewModel: WalletViewModel) async throws {
        // Check if node is already running
        if walletViewModel.nodeLifecycleState == .running {
            Logger.debug("📩 Node already running")
            return
        }

        // Wait for node to be ready
        Logger.debug("📩 Waiting for node to start...")
        try await waitForNodeToBeReady(timeout: 60)
    }

    private func connectToLspPeer(lspId: String) async throws {
        // Find the peer in trusted peers list
        guard let peer = Env.trustedLnPeers.first(where: { $0.nodeId == lspId }) else {
            Logger.warn("📩 LSP \(lspId) not found in trusted peers")
            return // Not a fatal error, node might already be connected
        }

        // Check if already connected
        if let peers = LightningService.shared.peers, peers.contains(where: { $0.nodeId == lspId }) {
            Logger.debug("📩 Already connected to LSP")
            return
        }

        // Connect to the peer
        Logger.debug("📩 Connecting to LSP: \(lspId)")
        try await LightningService.shared.connectPeer(peer: peer)

        // Wait for connection to be established
        let maxWaitTime: TimeInterval = 10.0
        let pollInterval: TimeInterval = 0.5
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            if let peers = LightningService.shared.peers, peers.contains(where: { $0.nodeId == lspId }) {
                Logger.debug("📩 Successfully connected to LSP")
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        Logger.warn("📩 Timeout waiting for LSP connection, continuing anyway")
    }

    private func handlePaymentType(_ paymentInfo: IncomingPaymentInfo) async throws {
        switch paymentInfo.paymentType {
        case .orderPaymentConfirmed:
            // Handle channel opening
            if let orderId = paymentInfo.orderId {
                Logger.debug("📩 Opening channel for order: \(orderId)")
                _ = try await CoreService.shared.blocktank.open(orderId: orderId)
            }
        case .incomingHtlc, .cjitPaymentArrived:
            // These are handled automatically by LDK node events once connected
            Logger.debug("📩 Payment will be processed by LDK events")
        case .mutualClose:
            // Channel close is handled by LDK
            Logger.debug("📩 Channel close will be processed by LDK")
        case .wakeToTimeout, .unknown:
            // Generic wake - just ensure node is running
            Logger.debug("📩 Node running, events will be processed")
        }
    }

    func sendTestNotification() async throws {
        Logger.debug("Sending test notification to self")

        guard let deviceToken else {
            throw PushNotificationError.deviceTokenNotAvailable
        }

        do {
            let response = try await CoreService.shared.blocktank.pushNotificationTest(
                deviceToken: deviceToken,
                secretMessage: "hello",
                notificationType: BlocktankNotificationType.orderPaymentConfirmed.rawValue
            )

            Logger.debug("Test notification sent successfully: \(response)")
        } catch {
            Logger.error("Failed to send test notification: \(error)")
        }
    }

    // MARK: - Private Helpers

    /// Waits for the Lightning node to be ready before proceeding
    /// - Parameter timeout: Maximum time to wait in seconds (default: 30)
    /// - Parameter pollInterval: How often to check the status in seconds (default: 0.5)
    private func waitForNodeToBeReady(timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.5) async throws {
        let startTime = Date()
        let timeoutDate = startTime.addingTimeInterval(timeout)

        Logger.debug("⏳ Waiting for Lightning node to be ready...")

        while Date() < timeoutDate {
            // Check if node is running via the status
            if let status = LightningService.shared.status, status.isRunning {
                let waitTime = Date().timeIntervalSince(startTime)
                Logger.debug("✅ Node is ready (waited \(String(format: "%.2f", waitTime))s)")
                return
            }

            // Wait before checking again
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // Timeout reached
        let waitTime = Date().timeIntervalSince(startTime)
        Logger.error("❌ Node did not become ready within \(timeout)s (waited \(String(format: "%.2f", waitTime))s)")
        throw AppError(message: "Lightning node did not start in time", debugMessage: "Timed out after \(timeout) seconds")
    }
}
