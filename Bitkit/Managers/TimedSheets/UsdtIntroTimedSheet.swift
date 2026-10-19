import Foundation

struct UsdtIntroTimedSheet: TimedSheetItem {
    let id = SheetID.usdtIntro
    let priority = TimedSheetPriority.medium
    let sheetItem: any SheetItem = UsdtIntroSheetItem()
    let wallet: WalletViewModel
    let settings: SettingsViewModel

    @MainActor
    func shouldShow() async -> Bool {
        Env.isUsdtEnabled && wallet.walletExists == true && settings.usdtPreference == .undecided && !settings.hasSeenUsdtIntro
    }

    func onShown() {}
    func onDismissed() {}
}
