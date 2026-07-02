import Foundation
import SwiftUI

/// Priority levels for timed sheets (higher number = higher priority)
enum TimedSheetPriority: Int, CaseIterable {
    case low = 1
    case medium = 2
    case high = 3
}

/// Protocol for timed sheet items
protocol TimedSheetItem {
    var id: SheetID { get }
    var priority: TimedSheetPriority { get }
    var sheetItem: any SheetItem { get }

    /// Check if this sheet should be shown based on current app state
    func shouldShow() async -> Bool

    /// Called when the sheet is shown (for tracking/analytics)
    func onShown()

    /// Called when the sheet is dismissed
    func onDismissed()
}

/// Manager for handling timed sheets with priority queue
@MainActor
class TimedSheetManager: ObservableObject {
    static let shared = TimedSheetManager()

    private let checkDelay: TimeInterval = 2.0 // 2 seconds delay
    private var settleTimer: Timer?
    private var queuedSheets: [any TimedSheetItem] = []
    private var isOnPrimaryScreen = false
    private var currentlyShowingSheet: (any TimedSheetItem)?

    private weak var sheetViewModel: SheetViewModel?

    private init() {}

    /// Configure the manager and register all timed sheets
    func setup(
        sheetViewModel: SheetViewModel,
        appViewModel: AppViewModel,
        settingsViewModel: SettingsViewModel,
        walletViewModel: WalletViewModel,
        currencyViewModel: CurrencyViewModel
    ) {
        // Configure the manager
        self.sheetViewModel = sheetViewModel

        // Register all timed sheets
        let appUpdateSheet = AppUpdateTimedSheet(appViewModel: appViewModel)
        registerSheet(appUpdateSheet)

        let backupSheet = BackupTimedSheet(appViewModel: appViewModel, walletViewModel: walletViewModel)
        registerSheet(backupSheet)

        let highBalanceSheet = HighBalanceTimedSheet(
            appViewModel: appViewModel,
            walletViewModel: walletViewModel,
            currencyViewModel: currencyViewModel
        )
        registerSheet(highBalanceSheet)

        let notificationsSheet = NotificationsTimedSheet(
            appViewModel: appViewModel,
            settingsViewModel: settingsViewModel,
            walletViewModel: walletViewModel
        )
        registerSheet(notificationsSheet)

        let quickpaySheet = QuickpayTimedSheet(appViewModel: appViewModel, walletViewModel: walletViewModel)
        registerSheet(quickpaySheet)

        Logger.debug("TimedSheetManager setup complete with \(queuedSheets.count) registered sheets")
    }

    /// Register a timed sheet to be checked
    func registerSheet(_ sheet: any TimedSheetItem) {
        // Remove existing sheet with same ID if present
        queuedSheets.removeAll { $0.id == sheet.id }

        // Add new sheet and sort by priority (highest first)
        queuedSheets.append(sheet)
        queuedSheets.sort { $0.priority.rawValue > $1.priority.rawValue }

        Logger.debug("Registered timed sheet: \(sheet.id.rawValue) with priority: \(sheet.priority.rawValue)")
    }

    /// Remove a sheet from the queue
    func removeSheet(withId id: SheetID) {
        queuedSheets.removeAll { $0.id == id }
        Logger.debug("Removed timed sheet: \(id.rawValue)")
    }

    /// Call this when a primary screen appears.
    ///
    /// A primary screen is a top-level screen where timed sheets are allowed to surface:
    /// the home screen (wallet flow) or the onboarding root (no wallet yet). The app-update
    /// prompt is the only registered sheet whose `shouldShow()` can pass without a wallet, so
    /// onboarding only ever surfaces that one (see issue #460).
    func onPrimaryScreenEntered() {
        guard !isOnPrimaryScreen else { return }

        isOnPrimaryScreen = true
        Logger.debug("Entered primary screen, starting timer")

        scheduleSettleCheck()
    }

    /// Re-check the timed-sheet queue after async state changes that may have made a sheet newly
    /// eligible (for example, the app-update info arriving after the initial settle check). No-ops
    /// unless on a primary screen with no sheet already open.
    func reevaluate() {
        guard isOnPrimaryScreen, !(sheetViewModel?.isAnySheetOpen ?? false) else { return }
        Logger.debug("Re-evaluating timed sheets after external state change")
        scheduleSettleCheck()
    }

    /// Call this when the primary screen disappears.
    func onPrimaryScreenExited() {
        guard isOnPrimaryScreen else { return }

        isOnPrimaryScreen = false
        Logger.debug("Exited primary screen, cancelling timer")

        // Cancel timer
        settleTimer?.invalidate()
        settleTimer = nil
    }

    /// Call this when any sheet is shown (to prevent showing timed sheets)
    func onSheetShown() {
        // If a sheet is shown, cancel any pending timed sheet checks
        settleTimer?.invalidate()
        settleTimer = nil
    }

    /// Call this when a sheet is dismissed
    func onSheetDismissed() {
        // Mark current sheet as dismissed
        if let currentSheet = currentlyShowingSheet {
            currentSheet.onDismissed()
            currentlyShowingSheet = nil
        }
    }

    /// (Re)start the settle timer that runs the queue check after a short delay.
    private func scheduleSettleCheck() {
        // Cancel any existing timer
        settleTimer?.invalidate()

        // Start timer to check for sheets after delay
        settleTimer = Timer.scheduledTimer(withTimeInterval: checkDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAndShowNextSheet()
            }
        }
    }

    /// Check the queue and show the highest priority sheet that should be shown
    private func checkAndShowNextSheet() async {
        guard let sheetViewModel else {
            Logger.error("SheetViewModel not configured for TimedSheetManager")
            return
        }

        // Don't show if any sheet is already open
        guard !sheetViewModel.isAnySheetOpen else {
            Logger.debug("Sheet already open, skipping timed sheet check")
            return
        }

        // Don't show if no longer on a primary screen
        guard isOnPrimaryScreen else {
            Logger.debug("No longer on a primary screen, skipping timed sheet check")
            return
        }

        // Find the highest priority sheet that should be shown
        for sheet in queuedSheets {
            if await sheet.shouldShow() {
                Logger.debug("Showing timed sheet: \(sheet.id.rawValue) with priority: \(sheet.priority.rawValue)")

                // Show the sheet
                currentlyShowingSheet = sheet
                sheet.onShown()

                // Show the sheet using the SheetID directly
                sheetViewModel.showSheet(sheet.id, data: sheet.sheetItem)

                // Remove from queue (one-time show)
                removeSheet(withId: sheet.id)
                return
            }
        }

        Logger.debug("No timed sheets need to be shown")
    }

    /// Get current queue status (for debugging)
    func getQueueStatus() -> [(id: SheetID, priority: Int)] {
        return queuedSheets.map { (id: $0.id, priority: $0.priority.rawValue) }
    }
}
