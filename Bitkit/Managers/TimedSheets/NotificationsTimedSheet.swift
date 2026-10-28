import Foundation
import SwiftUI

/// Notifications timed sheet implementation
struct NotificationsTimedSheet: TimedSheetItem {
    let id = SheetID.notifications
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = NotificationsSheetItem()

    private let appViewModel: AppViewModel
    private let settingsViewModel: SettingsViewModel
    private let hasActiveSubscription: @MainActor () -> Bool

    init(
        appViewModel: AppViewModel,
        settingsViewModel: SettingsViewModel,
        hasActiveSubscription: @escaping @MainActor () -> Bool
    ) {
        self.appViewModel = appViewModel
        self.settingsViewModel = settingsViewModel
        self.hasActiveSubscription = hasActiveSubscription
    }

    @MainActor
    func shouldShow() async -> Bool {
        Self.shouldShow(
            notificationsEnabled: settingsViewModel.enableNotifications,
            hasSeenIntro: appViewModel.hasSeenNotificationsIntro,
            hasActiveSubscription: hasActiveSubscription()
        )
    }

    /// Paykit subscription reminders are the notifications Bitkit posts, so the prompt waits for a subscription.
    static func shouldShow(notificationsEnabled: Bool, hasSeenIntro: Bool, hasActiveSubscription: Bool) -> Bool {
        !notificationsEnabled && !hasSeenIntro && hasActiveSubscription
    }

    func onShown() {
        Logger.debug("Notifications sheet shown")
    }

    func onDismissed() {
        Logger.debug("Notifications sheet dismissed")
    }
}
