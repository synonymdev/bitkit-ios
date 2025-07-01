import SwiftUI

struct QuickpaySheetItem: SheetItem {
    let id: SheetID = .quickpay
    let size: SheetSize = .large
}

struct QuickpaySheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    let config: QuickpaySheetItem

    var body: some View {
        Sheet(id: .quickpay, data: config) {
            SheetIntro(
                navTitle: localizedString("settings__quickpay__nav_title"),
                title: localizedString("settings__quickpay__intro__title"),
                description: localizedString("settings__quickpay__intro__description"),
                image: "fast-forward",
                continueText: localizedString("common__learn_more"),
                cancelText: localizedString("common__later"),
                accentColor: .greenAccent,
                testID: "QuickpaySheet",
                onCancel: onLater,
                onContinue: onLearnMore
            )
        }
    }

    private func onLearnMore() {
        // Mark as seen and navigate to quickpay settings
        app.hasSeenQuickpayIntro = true
        sheets.hideSheet()
        navigation.navigate(.quickpay)
    }

    private func onLater() {
        // Mark as seen and dismiss
        app.hasSeenQuickpayIntro = true
        sheets.hideSheet()
    }
}
