import SwiftUI

struct HighBalanceSheetItem: SheetItem {
    let id: SheetID = .highBalance
    let size: SheetSize = .large
}

struct HighBalanceSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: HighBalanceSheetItem

    var body: some View {
        Sheet(id: .highBalance, data: config) {
            SheetIntro(
                navTitle: localizedString("other__high_balance__nav_title"),
                title: localizedString("other__high_balance__title"),
                description: localizedString("other__high_balance__text"),
                image: "exclamation-mark",
                continueText: localizedString("other__high_balance__continue"),
                cancelText: localizedString("other__high_balance__cancel"),
                accentColor: .yellowAccent,
                accentFont: Fonts.bold,
                testID: "HighBalanceSheet",
                onCancel: onLearnMore,
                onContinue: onDismiss
            )
        }
    }

    private func onDismiss() {
        app.ignoreHighBalance()
        sheets.hideSheet()
    }

    private func onLearnMore() {
        UIApplication.shared.open(URL(string: "https://en.bitcoin.it/wiki/Storing_bitcoins")!)
    }
}
