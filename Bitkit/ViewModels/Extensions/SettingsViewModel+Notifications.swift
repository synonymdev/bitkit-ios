import Foundation
import SwiftUI
import UserNotifications

// MARK: - Notification Management

extension SettingsViewModel {
    func checkNotificationPermission() {
        NotificationService.shared.checkNotificationPermission { status in
            self.notificationAuthorizationStatus = status
        }
    }
}
