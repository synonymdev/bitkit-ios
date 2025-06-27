import SwiftUI

struct NotificationsSheetItem: SheetItem {
    let id: SheetID = .notifications
    let size: SheetSize = .large
}

struct NotificationsSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: NotificationsSheetItem

    var body: some View {
        Sheet(id: .notifications, data: config) {
            SheetIntro(
                navTitle: localizedString("other__notifications_nav_title"),
                title: localizedString("other__notifications_title"),
                description: localizedString("other__notifications_text"),
                image: "bell",
                continueText: localizedString("other__notifications_button"),
                cancelText: localizedString("common__later"),
                accentColor: .blueAccent,
                testID: "NotificationsSheet",
                onCancel: onLater,
                onContinue: onEnable
            )
        }
    }

    private func onEnable() {
        // Mark as seen and show dialog
        app.ignoreNotifications()
        sheets.hideSheet()

        // Show dialog to enable notifications
        Task {
            if UserDefaults.standard.string(forKey: "deviceToken") == nil {
                StartupHandler.requestPushNotificationPermission { granted, error in
                    // If granted AppDelegate will receive the token and handle registration
                    if let error {
                        Logger.error(error, context: "Failed to request push notification permission")
                        app.toast(error)
                        return
                    }

                    if granted {
                        Logger.debug("Push notification permission granted, requesting device token")
                        Task {
                            do {
                                // Sleep 1 second to ensure token is saved in AppDelegate
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                                try await blocktank.registerDeviceForNotifications()
                            } catch {
                                Logger.error(error, context: "Failed to register device for notifications, will retry on next app launch")
                            }
                        }
                    }
                }
            }
        }
    }

    private func onLater() {
        // Mark as seen and dismiss
        app.ignoreNotifications()
        sheets.hideSheet()
    }
}
