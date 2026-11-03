import Foundation
import os.log
import UserNotifications

/// Notification service extension that delivers incoming push notifications unchanged.
///
/// Blocktank's encrypted Lightning pushes are gone, so there is no payload to decrypt or rewrite.
class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    private lazy var logger: OSLog = {
        let bundleID = Bundle.main.bundleIdentifier ?? "to.bitkit.notification"
        return OSLog(subsystem: bundleID, category: "NotificationService")
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        os_log("🔔 Push received: %{public}@", log: logger, type: .info, request.identifier)

        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        deliver()
    }

    func deliver() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        deliver()
    }
}
