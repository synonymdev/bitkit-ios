import Foundation
import SwiftUI

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

    func unregister() {
        // Unregister from remote notifications
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    func handleNotification(_ userInfo: [AnyHashable: Any]) {
        Logger.debug("📩 Notification received: \(userInfo)")
    }
}
