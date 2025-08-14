import Foundation
import SwiftUI

/// App update timed sheet implementation
struct AppUpdateTimedSheet: TimedSheetItem {
    let id = SheetID.appUpdate
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = AppUpdateSheetItem()

    private let appViewModel: AppViewModel
    private let appUpdateService = AppUpdateService.shared

    // App update constants
    private static let ASK_INTERVAL: TimeInterval = 12 * 60 * 60 // 12 hours - how long this prompt will not show after user dismisses

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        // Check if enough time has passed since last ignore
        let currentTime = Date().timeIntervalSince1970
        let isTimeoutOver = currentTime - appViewModel.appUpdateIgnoreTimestamp > Self.ASK_INTERVAL

        // Don't show if timeout hasn't passed
        guard isTimeoutOver else {
            return false
        }

        // Don't show if no update is available
        guard let update = appUpdateService.availableUpdate else {
            return false
        }

        // Don't show critical updates through timed sheets (they should be handled differently)
        guard !update.critical else {
            return false
        }

        return true
    }

    func onShown() {
        Logger.debug("App update sheet shown")
    }

    func onDismissed() {
        Logger.debug("App update sheet dismissed")
    }
}
