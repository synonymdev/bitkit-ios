import Foundation
import SwiftUI

/// App update timed sheet implementation
struct AppUpdateTimedSheet: TimedSheetItem {
    let id = SheetID.appUpdate
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = AppUpdateSheetItem()

    private let appViewModel: AppViewModel
    private let appUpdateService = AppUpdateService.shared

    /// App update constants
    static let ASK_INTERVAL: TimeInterval = 12 * 60 * 60 // 12 hours - how long this prompt will not show after user dismisses

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        Self.shouldShow(
            update: appUpdateService.availableUpdate,
            ignoreTimestamp: appViewModel.appUpdateIgnoreTimestamp,
            now: Date().timeIntervalSince1970,
            isE2E: Env.isE2E
        )
    }

    /// Pure eligibility check, extracted so it can be unit-tested without an `AppViewModel` or the shared service.
    static func shouldShow(update: AppUpdateInfo?, ignoreTimestamp: TimeInterval, now: TimeInterval, isE2E: Bool) -> Bool {
        // Don't show in e2e test environment
        guard !isE2E else {
            return false
        }

        // Don't show until enough time has passed since the user last ignored the prompt
        guard now - ignoreTimestamp > ASK_INTERVAL else {
            return false
        }

        // Don't show if no update is available
        guard let update else {
            return false
        }

        // Don't show critical updates through timed sheets; they're handled at the top level in AppScene
        return !update.critical
    }

    func onShown() {
        Logger.debug("App update sheet shown")
    }

    func onDismissed() {
        Logger.debug("App update sheet dismissed")
    }
}
