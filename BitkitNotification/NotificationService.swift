import Foundation
import os.log
import UserNotifications

/// Notification service extension for alert pushes. A wake in one is decrypted and acknowledged here, and the alert is
/// delivered as the gateway sent it. It never starts the node: background wakes reach the app delegate instead.
class NotificationService: UNNotificationServiceExtension {
    private let delivery = NotificationDelivery()

    private lazy var logger: OSLog = {
        let bundleID = Bundle.main.bundleIdentifier ?? "to.bitkit.notification"
        return OSLog(subsystem: bundleID, category: "NotificationService")
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        os_log("🔔 Push received: %{public}@", log: logger, type: .info, request.identifier)

        delivery.prepare(content: request.content, contentHandler: contentHandler)
        guard let pushJson = WakePush.json(from: request.content.userInfo) else {
            delivery.deliver()
            return
        }

        Task { [delivery] in
            _ = await WakeReceiver(handlers: .notificationExtension).receive(pushJson: pushJson)
            delivery.deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        delivery.deliver()
    }
}

/// Hands the content to the system once, whichever of the wake work and the expiry warning comes first.
private final class NotificationDelivery {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    func prepare(content: UNNotificationContent, contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            self.content = content.mutableCopy() as? UNMutableNotificationContent ?? content
            self.contentHandler = contentHandler
        }
    }

    func deliver() {
        let pending: (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)? = lock.withLock {
            defer {
                contentHandler = nil
                content = nil
            }
            guard let contentHandler, let content else { return nil }
            return (contentHandler, content)
        }
        if let pending {
            pending.handler(pending.content)
        }
    }
}
