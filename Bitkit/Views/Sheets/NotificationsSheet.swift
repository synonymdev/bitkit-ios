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
                navTitle: localizedString("settings__notifications__nav_title"),
                title: localizedString("settings__notifications__intro__title"),
                description: localizedString("settings__notifications__intro__text"),
                image: "bell-figure",
                continueText: localizedString("settings__notifications__intro__button"),
                cancelText: localizedString("common__later"),
                accentColor: .blueAccent,
                testID: "NotificationsSheet",
                onCancel: onLater,
                onContinue: onEnable
            )
        }
    }

    private func onEnable() {
        // Request permission and mark as seen
        NotificationService.shared.requestPushNotificationPermission()
        app.hasSeenNotificationsIntro = true
        sheets.hideSheet()
    }

    private func onLater() {
        // Mark as seen and dismiss
        app.hasSeenNotificationsIntro = true
        sheets.hideSheet()
    }
}
