import Foundation
import SwiftUI

/// Notifications timed sheet implementation
struct NotificationsTimedSheet: TimedSheetItem {
    let id = SheetID.notifications
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = NotificationsSheetItem()

    private let appViewModel: AppViewModel
    private let settingsViewModel: SettingsViewModel
    private let walletViewModel: WalletViewModel

    init(appViewModel: AppViewModel, settingsViewModel: SettingsViewModel, walletViewModel: WalletViewModel) {
        self.appViewModel = appViewModel
        self.settingsViewModel = settingsViewModel
        self.walletViewModel = walletViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        // Check if user hasn't been asked for permission yet
        let isPermissionUndetermined = settingsViewModel.notificationAuthorizationStatus == .notDetermined

        // Check if user hasn't seen this prompt
        let hasSeenNotificationsIntro = appViewModel.hasSeenNotificationsIntro

        // Check if user has spending balance
        let hasSpendingBalance = walletViewModel.totalLightningSats > 0

        return isPermissionUndetermined && !hasSeenNotificationsIntro && hasSpendingBalance
    }

    func onShown() {
        Logger.debug("Notifications sheet shown")
    }

    func onDismissed() {
        Logger.debug("Notifications sheet dismissed")
    }
}
