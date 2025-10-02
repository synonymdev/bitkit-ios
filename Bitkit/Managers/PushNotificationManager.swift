import Foundation
import SwiftUI

enum PushNotificationError: Error {
    case deviceTokenNotAvailable
}

final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()
    @Published var deviceToken: String? = nil
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

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
