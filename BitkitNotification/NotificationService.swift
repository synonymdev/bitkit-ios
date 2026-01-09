import BitkitCore
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

    /// Request identifier for scheduled removal
    private var notificationIdentifier: String?

    private lazy var logger: OSLog = {
        let bundleID = Bundle.main.bundleIdentifier ?? "to.bitkit.notification"
        return OSLog(subsystem: bundleID, category: "NotificationService")
    }()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        os_log("🔔 Push received: %{public}@", log: logger, type: .info, request.identifier)

        self.contentHandler = contentHandler
        self.notificationIdentifier = request.identifier
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        Task {
            await processNotification(request)
        }
    }

    /// Processes the incoming notification
    private func processNotification(_ request: UNNotificationRequest) async {
        // Try to decrypt the payload
        let paymentInfo = await decryptAndParsePayload(request)

        if let paymentInfo {
            // Save payment info for main app to pick up
            paymentInfo.save()
            os_log("🔔 Saved payment info: type=%{public}@, id=%{public}@", log: logger, type: .info, paymentInfo.paymentType.rawValue, paymentInfo.id)

            // Configure notification with urgency messaging
            configureNotificationContent(for: paymentInfo)

            // Schedule notification removal after expiry
            scheduleNotificationRemoval(after: paymentInfo.timeRemaining, identifier: notificationIdentifier ?? request.identifier)
        } else {
            // Fallback: show generic notification if decryption fails
            configureFallbackNotification()
        }

        deliver()
    }

    /// Decrypts and parses the notification payload
    private func decryptAndParsePayload(_ request: UNNotificationRequest) async -> IncomingPaymentInfo? {
        guard let aps = request.content.userInfo["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any],
              let payload = alert["payload"] as? [String: Any],
              let cipher = payload["cipher"] as? String,
              let iv = payload["iv"] as? String,
              let publicKey = payload["publicKey"] as? String,
              let tag = payload["tag"] as? String
        else {
            os_log("🔔 Missing payload structure in notification", log: logger, type: .error)
            return nil
        }

        guard let ciphertext = Data(base64Encoded: cipher) else {
            os_log("🔔 Failed to decode cipher", log: logger, type: .error)
            return nil
        }

        guard let privateKey = try? Keychain.load(key: .pushNotificationPrivateKey) else {
            os_log("🔔 Missing pushNotificationPrivateKey in keychain", log: logger, type: .error)
            return nil
        }

        do {
            let password = try Crypto.generateSharedSecret(
                privateKey: privateKey,
                nodePubkey: publicKey,
                derivationName: "bitkit-notifications"
            )

            let decrypted = try Crypto.decrypt(
                .init(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData),
                secretKey: password
            )

            os_log("🔔 Payload decrypted successfully", log: logger, type: .info)

            return parseDecryptedPayload(decrypted)
        } catch {
            os_log("🔔 Decryption failed: %{public}@", log: logger, type: .error, error.localizedDescription)
            return nil
        }
    }

    /// Parses the decrypted JSON payload into IncomingPaymentInfo
    private func parseDecryptedPayload(_ data: Data) -> IncomingPaymentInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            os_log("🔔 Failed to parse decrypted JSON", log: logger, type: .error)
            return nil
        }

        guard let typeStr = json["type"] as? String else {
            os_log("🔔 Missing 'type' in decrypted payload", log: logger, type: .error)
            return nil
        }

        let payload = json["payload"] as? [String: Any]

        let paymentType = IncomingPaymentInfo.PaymentType(from: typeStr)
        let paymentHash = payload?["paymentHash"] as? String
        let orderId = payload?["orderId"] as? String
        let lspId = payload?["lspId"] as? String
        let amountMsat = payload?["amountMsat"] as? UInt64

        os_log(
            "🔔 Parsed payload: type=%{public}@, paymentHash=%{public}@",
            log: logger,
            type: .info,
            typeStr,
            paymentHash ?? "nil"
        )

        return IncomingPaymentInfo(
            paymentType: paymentType,
            paymentHash: paymentHash,
            orderId: orderId,
            lspId: lspId,
            amountMsat: amountMsat
        )
    }

    /// Configures the notification content with urgency messaging
    private func configureNotificationContent(for paymentInfo: IncomingPaymentInfo) {
        guard let content = bestAttemptContent else { return }

        content.title = paymentInfo.notificationTitle
        content.body = paymentInfo.notificationBody
        content.sound = .default

        // Set time-sensitive interruption level for urgent notifications (iOS 15+)
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }

        // Add category for potential custom actions
        content.categoryIdentifier = "INCOMING_PAYMENT"

        // Store payment info ID in userInfo for the app to reference
        var userInfo = content.userInfo
        userInfo["incomingPaymentId"] = paymentInfo.id
        userInfo["paymentType"] = paymentInfo.paymentType.rawValue
        content.userInfo = userInfo

        os_log("🔔 Configured notification: title=%{public}@", log: logger, type: .info, content.title)
    }

    /// Configures a fallback notification when decryption fails
    private func configureFallbackNotification() {
        guard let content = bestAttemptContent else { return }

        content.title = "Bitkit"
        content.body = "Open Bitkit to check for new activity"
        content.sound = .default

        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        os_log("🔔 Using fallback notification content", log: logger, type: .info)
    }

    /// Schedules the notification to be removed after expiry
    /// This prevents stale notifications since the payment window has closed
    private func scheduleNotificationRemoval(after delay: TimeInterval, identifier: String) {
        guard delay > 0 else {
            os_log("🔔 Payment already expired, removing immediately", log: logger, type: .info)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }

        // Schedule removal slightly after expiry to ensure it's shown until the last moment
        let removalDelay = delay + 5 // Add 5 seconds buffer

        os_log("🔔 Scheduling notification removal in %.0f seconds", log: logger, type: .info, removalDelay)

        DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            os_log("🔔 Removed expired notification: %{public}@", log: self.logger, type: .info, identifier)
        }
    }

    /// Delivers the notification to the user
    private func deliver() {
        if let contentHandler, let content = bestAttemptContent {
            contentHandler(content)
            os_log("🔔 Notification delivered", log: logger, type: .info)
        } else {
            os_log("🔔 Failed to deliver: missing handler or content", log: logger, type: .error)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        os_log("🔔 Extension time expiring, delivering best attempt", log: logger, type: .info)

        // Deliver whatever we have before the system terminates us
        if let contentHandler, let content = bestAttemptContent {
            // If we haven't configured the content yet, use fallback
            if content.title.isEmpty {
                configureFallbackNotification()
            }
            contentHandler(content)
        }
    }
}

// MARK: - Keychain Access (Shared with main app via App Group)

/// Minimal Keychain access for the notification extension
/// Mirrors the main app's Keychain class but only includes what's needed
private enum KeychainEntryType {
    case pushNotificationPrivateKey

    var storageKey: String {
        switch self {
        case .pushNotificationPrivateKey:
            return "push_notification_private_key"
        }
    }
}

private class Keychain {
    /// Keychain access group shared between app and extension
    private static let keychainGroup = "KYH47R284B.to.bitkit"

    class func load(key: KeychainEntryType) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.storageKey,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: keychainGroup,
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == noErr else {
            throw KeychainError.failedToLoad
        }

        return dataTypeRef as? Data
    }

    enum KeychainError: Error {
        case failedToLoad
    }
}

// MARK: - IncomingPaymentInfo (Shared with main app via App Group)

/// Represents an incoming payment notification that needs to be processed by the app.
/// NOTE: This must be kept in sync with the main app's IncomingPaymentInfo model.
private struct IncomingPaymentInfo: Codable {
    enum PaymentType: String, Codable {
        case incomingHtlc
        case cjitPaymentArrived
        case orderPaymentConfirmed
        case mutualClose
        case wakeToTimeout
        case unknown

        init(from blocktankType: String) {
            self = PaymentType(rawValue: blocktankType) ?? .unknown
        }
    }

    enum ProcessingState: String, Codable {
        case pending
        case processing
        case completed
        case expired
        case failed
    }

    let id: String
    let paymentType: PaymentType
    let paymentHash: String?
    let orderId: String?
    let lspId: String?
    let amountMsat: UInt64?
    let receivedAt: Date
    let expiresAt: Date
    var state: ProcessingState

    var notificationTitle: String {
        switch paymentType {
        case .incomingHtlc, .cjitPaymentArrived:
            return "Incoming Payment"
        case .orderPaymentConfirmed:
            return "Spending Balance Ready"
        case .mutualClose:
            return "Channel Closing"
        case .wakeToTimeout:
            return "Payment Pending"
        case .unknown:
            return "Notification"
        }
    }

    var notificationBody: String {
        switch paymentType {
        case .incomingHtlc, .cjitPaymentArrived:
            return "Open Bitkit now to receive your payment"
        case .orderPaymentConfirmed:
            return "Open Bitkit now to complete setup"
        case .mutualClose:
            return "Your spending balance is being transferred"
        case .wakeToTimeout:
            return "Open Bitkit to process pending payment"
        case .unknown:
            return "Open Bitkit to continue"
        }
    }

    static let defaultExpiryDuration: TimeInterval = 2 * 60

    private static let storageKey = "incomingPaymentInfo"
    private static let appGroupUserDefaults = UserDefaults(suiteName: "group.bitkit")

    init(
        paymentType: PaymentType,
        paymentHash: String? = nil,
        orderId: String? = nil,
        lspId: String? = nil,
        amountMsat: UInt64? = nil,
        expiryDuration: TimeInterval = IncomingPaymentInfo.defaultExpiryDuration
    ) {
        self.id = UUID().uuidString
        self.paymentType = paymentType
        self.paymentHash = paymentHash
        self.orderId = orderId
        self.lspId = lspId
        self.amountMsat = amountMsat
        self.receivedAt = Date()
        self.expiresAt = Date().addingTimeInterval(expiryDuration)
        self.state = .pending
    }

    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(self)
            Self.appGroupUserDefaults?.set(data, forKey: Self.storageKey)
            Self.appGroupUserDefaults?.synchronize()
        } catch {
            print("IncomingPaymentInfo: Failed to save: \(error)")
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
