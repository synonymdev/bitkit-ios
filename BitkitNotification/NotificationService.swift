import Foundation
import os.log
import UserNotifications

/// Lightweight notification service extension that handles incoming push notifications.
///
/// IMPORTANT: This extension does NOT start the LDK node due to iOS memory (~24MB) and time (~30s) constraints.
/// Instead, it:
/// 1. Decrypts the notification payload
/// 2. Displays a time-sensitive notification with urgency messaging
/// 3. Saves payment info for the main app to process when opened
///
/// The main app handles actual Lightning payment processing when the user opens it.
class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    private lazy var logger: OSLog = {
        let bundleID = Bundle.main.bundleIdentifier ?? "to.bitkit.notification"
        return OSLog(subsystem: bundleID, category: "NotificationService")
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        os_log("🚨 Push received! %{public}@", log: logger, type: .error, request.identifier)
        os_log("🔔 UserInfo: %{public}@", log: logger, type: .error, request.content.userInfo)

        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard !StateLocker.isLocked(.lightning) else {
            os_log("🔔 LDK-node process already locked, app likely in foreground", log: logger, type: .error)
            return
        }

        Task {
            do {
                let (notificationType, payload) = try await self.decryptPayload(request)

                // Configure notification content based on type
                configureNotificationContent(for: notificationType, payload: payload)
                deliver()
            } catch {
                // Fallback notification if decryption fails
                os_log(
                    "🔔 Failed to decrypt notification payload: %{public}@",
                    log: logger,
                    type: .error,
                    error.localizedDescription
                )
                configureFallbackNotification()
                deliver()
            }
        }
    }

    func decryptPayload(_ request: UNNotificationRequest) async throws -> (BlocktankNotificationType, [String: Any]) {
        guard let aps = request.content.userInfo["aps"] as? AnyObject else {
            os_log("🔔 Failed to decrypt payload: missing aps payload", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing aps payload"])
        }

        guard let alert = aps["alert"] as? AnyObject,
              let payload = alert["payload"] as? AnyObject,
              let cipher = payload["cipher"] as? String,
              let iv = payload["iv"] as? String,
              let publicKey = payload["publicKey"] as? String,
              let tag = payload["tag"] as? String
        else {
            os_log("🔔 Failed to decrypt payload: missing details", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing payload details"])
        }

        guard let ciphertext = Data(base64Encoded: cipher) else {
            os_log("🔔 Failed to decrypt payload: failed to decode cipher", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to decode cipher"])
        }

        guard let privateKey = try Keychain.load(key: .pushNotificationPrivateKey) else {
            os_log("🔔 Failed to decrypt payload: missing pushNotificationPrivateKey", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing pushNotificationPrivateKey"])
        }

        let password = try Crypto.generateSharedSecret(privateKey: privateKey, nodePubkey: publicKey, derivationName: "bitkit-notifications")
        let decrypted = try Crypto.decrypt(.init(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData), secretKey: password)

        guard let jsonData = try JSONSerialization.jsonObject(with: decrypted, options: []) as? [String: Any] else {
            os_log("🔔 Failed to decrypt payload: failed to convert decrypted data to utf8", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to convert decrypted data to utf8"])
        }

        guard let payload = jsonData["payload"] as? [String: Any] else {
            os_log("🔔 Failed to decrypt payload: missing payload", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing payload"])
        }

        guard let typeStr = jsonData["type"] as? String, let type = BlocktankNotificationType(rawValue: typeStr) else {
            os_log("🔔 Failed to decrypt payload: missing type", log: logger, type: .error)
            throw NSError(domain: "NotificationService", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing type"])
        }

        os_log("🔔 Decrypted payload: type=%{public}@, payload=%{public}@", log: logger, type: .info, typeStr, payload)

        return (type, payload)
    }

    /// Configures notification content based on the notification type
    /// - Parameters:
    ///   - notificationType: The type of notification received
    ///   - payload: Optional payload data containing additional information (amount, payment hash, etc.)
    private func configureNotificationContent(for notificationType: BlocktankNotificationType, payload: [String: Any]?) {
        guard let content = bestAttemptContent else { return }

        switch notificationType {
        case .incomingHtlc:
            content.title = "Incoming Payment"
            content.body = "Open Bitkit now to receive your payment"

        case .cjitPaymentArrived:
            content.title = "Incoming Payment"
            content.body = "Open Bitkit now to receive your payment"

        case .orderPaymentConfirmed:
            content.title = "Spending Balance Ready"
            content.body = "Open Bitkit to start paying anyone, anywhere."

        case .mutualClose:
            content.title = "Spending Balance Expired"
            content.body = "Open Bitkit to move funds from spending to savings"

        case .wakeToTimeout:
            content.title = "Payment Pending"
            content.body = "Open Bitkit to process pending payment"

        @unknown default:
            content.title = "Bitkit"
            content.body = "Open Bitkit to check for new activity"
        }

        // Set time-sensitive interruption level for urgent notifications
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0

        // Store notification type in userInfo for the app to reference
        var userInfo = content.userInfo
        userInfo["notificationType"] = notificationType.rawValue
        content.userInfo = userInfo

        os_log("🔔 Configured notification: type=%{public}@, title=%{public}@", log: logger, type: .info, notificationType.rawValue, content.title)
    }

    /// Configures a fallback notification when decryption fails
    private func configureFallbackNotification() {
        guard let content = bestAttemptContent else { return }

        content.title = "Bitkit"
        content.body = "Open Bitkit to check for new activity"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        os_log("🔔 Using fallback notification content", log: logger, type: .info)
    }

    func deliver() {
        Task {
            if let contentHandler, let bestAttemptContent {
                contentHandler(bestAttemptContent)
                os_log("🔔 Notification delivered successfully", log: logger, type: .error)
            } else {
                os_log("🔔 Missing contentHandler or bestAttemptContent", log: logger, type: .error)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        os_log("🔔 NotificationService: Delivering notification before timeout", log: logger, type: .error)

        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}

// MARK: - String Extension for Hex Conversion

private extension String {
    var hexaData: Data {
        var data = Data()
        var hex = self

        // Remove any spaces or non-hex characters
        hex = hex.replacingOccurrences(of: " ", with: "")

        // Ensure even number of characters
        if hex.count % 2 != 0 {
            hex = "0" + hex
        }

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index ..< nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }

        return data
    }
}
