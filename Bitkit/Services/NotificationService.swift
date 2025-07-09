import Foundation
import SwiftUI

class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private init() {}

    // Callback to notify about registration status changes
    var onRegistrationStatusChanged: ((Bool) -> Void)?

    // Callback to notify about registration failures
    var onRegistrationFailed: ((Error) -> Void)?

    func requestPushNotificationPermission() {
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions
        ) { granted, error in
            if granted {
                Logger.debug("Push notification permission granted, requesting device token")
                // Request a fresh token - it will be automatically registered when received
                self.requestDeviceToken()
            } else if let error = error {
                Logger.error("Push notification permission denied: \(error)")
            } else {
                Logger.debug("Push notification permission denied by user")
            }
        }
    }

    func registerDeviceForNotifications(deviceToken: String, completion: @escaping (Bool) -> Void = { _ in }) async throws {
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
            features: Env.pushNotificationFeatures.map { $0.feature },
            nodeId: nodeId,
            isoTimestamp: isoTimestamp,
            signature: signature
        )

        Logger.debug("Registration result: \(result)")

        Logger.debug("Device successfully registered for notifications")
        completion(true)

        // Notify via callback on main thread
        await MainActor.run {
            self.onRegistrationStatusChanged?(true)
        }
    }

    func pushNotificationTest(deviceToken: String) async throws {
        Logger.debug("Sending test notification to self")

        let _ = try await CoreService.shared.blocktank.pushNotificationTest(
            deviceToken: deviceToken,
            secretMessage: "hello",
            notificationType: BlocktankNotificationType.orderPaymentConfirmed.rawValue
        )
    }

    func requestDeviceToken() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func unregisterFromRemoteNotifications() {
        UIApplication.shared.unregisterForRemoteNotifications()
        Logger.debug("Unregistered from remote notifications")
    }

    func unregisterFromServer() async throws {
        // Note: This would require a server endpoint to unregister the device
        // For now, we just log that we would unregister
        Logger.debug("Would unregister device from notification server")
        // TODO: Implement server unregistration when endpoint is available
        // try await CoreService.shared.blocktank.unregisterDeviceForNotifications()
    }

    func checkNotificationPermission(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let status = settings.authorizationStatus
                Logger.debug("Notification authorization status: \(String(describing: status))", context: "NotificationService")
                completion(status)
            }
        }
    }
}
