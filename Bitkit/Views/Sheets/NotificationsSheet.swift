import SwiftUI

struct NotificationsSheetItem: SheetItem {
    let id: SheetID = .notifications
    let size: SheetSize = .large
}

struct NotificationsSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var notificationManager: PushNotificationManager
    @EnvironmentObject private var sheets: SheetViewModel
    let config: NotificationsSheetItem

    var body: some View {
        Sheet(id: .notifications, data: config) {
            SheetIntro(
                navTitle: t("settings__notifications__nav_title"),
                title: t("settings__notifications__intro__title"),
                description: t("settings__notifications__intro__text"),
                image: "bell-figure",
                continueText: t("settings__notifications__intro__button"),
                cancelText: t("common__later"),
                accentColor: .blueAccent,
                testID: "BackgroundPayments",
                onCancel: onLater,
                onContinue: onEnable
            )
        }
    }

    private func onEnable() {
        // Request permission and mark as seen
        notificationManager.requestPermission()
        app.hasSeenNotificationsIntro = true
        sheets.hideSheet()
    }

    private func onLater() {
        // Mark as seen and dismiss
        app.hasSeenNotificationsIntro = true
        sheets.hideSheet()
    }
}
