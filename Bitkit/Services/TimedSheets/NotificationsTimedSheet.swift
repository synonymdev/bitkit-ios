import Foundation
import SwiftUI

/// Notifications timed sheet implementation
struct NotificationsTimedSheet: TimedSheetItem {
    let id = SheetID.notifications
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = NotificationsSheetItem()

    private let appViewModel: AppViewModel

    // Notifications prompt constants
    private static let ASK_INTERVAL: TimeInterval = 7 * 24 * 60 * 60 // 7 days - how long this prompt will not show after user dismisses

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        // Check if user hasn't seen this prompt
        let notificationsIgnoreTimestamp = appViewModel.notificationsIgnoreTimestamp
        let currentTime = Date().timeIntervalSince1970
        let isTimeoutOver = currentTime - notificationsIgnoreTimestamp > Self.ASK_INTERVAL

        return isTimeoutOver
    }

    func onShown() {
        Logger.debug("Notifications sheet shown")
    }

    func onDismissed() {
        Logger.debug("Notifications sheet dismissed")
    }
}
