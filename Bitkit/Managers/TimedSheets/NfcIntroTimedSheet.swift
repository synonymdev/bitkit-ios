import Foundation

/// Shows the NFC payments intro once, on devices that can read NFC tags.
struct NfcIntroTimedSheet: TimedSheetItem {
    let id = SheetID.nfcIntro
    let priority = TimedSheetPriority.low
    let sheetItem: any SheetItem = NfcIntroSheetItem()

    private let appViewModel: AppViewModel
    private let walletViewModel: WalletViewModel
    private let isNfcReadingAvailable: @MainActor () -> Bool

    init(
        appViewModel: AppViewModel,
        walletViewModel: WalletViewModel,
        isNfcReadingAvailable: @escaping @MainActor () -> Bool = { NfcReader.shared.isAvailable }
    ) {
        self.appViewModel = appViewModel
        self.walletViewModel = walletViewModel
        self.isNfcReadingAvailable = isNfcReadingAvailable
    }

    @MainActor
    func shouldShow() async -> Bool {
        !appViewModel.hasSeenNfcIntro && walletViewModel.walletExists == true && isNfcReadingAvailable()
    }

    func onShown() {
        Logger.debug("NFC intro sheet shown")
    }

    func onDismissed() {
        Logger.debug("NFC intro sheet dismissed")
    }
}
