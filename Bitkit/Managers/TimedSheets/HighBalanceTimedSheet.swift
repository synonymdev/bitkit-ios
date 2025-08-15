import Foundation
import SwiftUI

/// High balance warning timed sheet implementation
struct HighBalanceTimedSheet: TimedSheetItem {
    let id = SheetID.highBalance
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = HighBalanceSheetItem()

    private let walletViewModel: WalletViewModel
    private let currencyViewModel: CurrencyViewModel
    private let appViewModel: AppViewModel

    // High balance warning constants
    private static let BALANCE_THRESHOLD_USD: Double = 500
    private static let BALANCE_THRESHOLD_SATS: UInt64 = 700_000
    private static let ASK_INTERVAL: TimeInterval = 24 * 60 * 60 // 1 day - how long this prompt will not show after user dismisses
    private static let MAX_WARNINGS = 3

    init(appViewModel: AppViewModel, walletViewModel: WalletViewModel, currencyViewModel: CurrencyViewModel) {
        self.appViewModel = appViewModel
        self.walletViewModel = walletViewModel
        self.currencyViewModel = currencyViewModel
    }

    @MainActor
    func shouldShow() async -> Bool {
        let currentTime = Date().timeIntervalSince1970
        let isTimeoutOver = currentTime - appViewModel.highBalanceIgnoreTimestamp > Self.ASK_INTERVAL
        let belowMaxWarnings = appViewModel.highBalanceIgnoreCount < Self.MAX_WARNINGS

        // Get total balance
        let totalBalance = UInt64(walletViewModel.totalBalanceSats)

        // Check if threshold is reached
        let thresholdReached: Bool
        if let usdConversion = currencyViewModel.convert(sats: totalBalance, to: "USD") {
            thresholdReached = Double(truncating: usdConversion.value as NSDecimalNumber) > Self.BALANCE_THRESHOLD_USD
        } else {
            // Fallback to sats if exchange rates not available
            thresholdReached = totalBalance > Self.BALANCE_THRESHOLD_SATS
        }

        return isTimeoutOver && thresholdReached && belowMaxWarnings
    }

    func onShown() {
        Logger.debug("High balance warning sheet shown")
    }

    func onDismissed() {
        // This will be handled by the AppViewModel.ignoreHighBalance() method when the sheet is dismissed
        Logger.debug("High balance warning sheet dismissed")
    }
}
