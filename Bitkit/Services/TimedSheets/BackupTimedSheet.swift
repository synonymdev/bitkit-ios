import Foundation
import SwiftUI

/// Backup prompt timed sheet implementation
struct BackupTimedSheet: TimedSheetItem {
    let id = SheetID.backup
    let priority = TimedSheetPriority.high
    let sheetItem: any SheetItem = BackupSheetItem(initialRoute: .intro)

    private let walletViewModel: WalletViewModel
    private let appViewModel: AppViewModel

    // Backup prompt constants
    private static let ASK_INTERVAL: TimeInterval = 24 * 60 * 60 // 1 day - how long this prompt will not show after user dismisses

    init(appViewModel: AppViewModel, walletViewModel: WalletViewModel) {
        self.appViewModel = appViewModel
        self.walletViewModel = walletViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        // Check if backup has been verified
        let backupVerified = appViewModel.backupVerified

        // Check if user has not seen this prompt for ASK_INTERVAL
        let ignoreTimestamp = appViewModel.backupIgnoreTimestamp
        let currentTime = Date().timeIntervalSince1970
        let isTimeoutOver = currentTime - ignoreTimestamp > Self.ASK_INTERVAL

        // Check if wallet has balance
        let hasBalance = walletViewModel.totalBalanceSats > 0

        return isTimeoutOver && backupVerified != true && hasBalance
    }

    func onShown() {
        Logger.debug("Backup prompt sheet shown")
    }

    func onDismissed() {
        // This will be handled by the AppViewModel.ignoreBackup() method when the sheet is dismissed
        Logger.debug("Backup prompt sheet dismissed")
    }
}
