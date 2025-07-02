import Foundation
import SwiftUI

/// Quickpay intro timed sheet implementation
struct QuickpayTimedSheet: TimedSheetItem {
    let id = SheetID.quickpay
    let priority = TimedSheetPriority.low
    let sheetItem: any SheetItem = QuickpaySheetItem()

    private let walletViewModel: WalletViewModel
    private let appViewModel: AppViewModel

    init(appViewModel: AppViewModel, walletViewModel: WalletViewModel) {
        self.appViewModel = appViewModel
        self.walletViewModel = walletViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        // Check if user hasn't seen this prompt
        let quickpayIntroSeen = appViewModel.hasSeenQuickpayIntro

        // Check if has spending balance
        let hasSpendingBalance = walletViewModel.totalLightningSats > 0

        return !quickpayIntroSeen && hasSpendingBalance
    }

    func onShown() {
        Logger.debug("Quickpay sheet shown")
    }

    func onDismissed() {
        Logger.debug("Quickpay sheet dismissed")
    }
}
