import SwiftUI

struct AppUpdateSheetItem: SheetItem {
    let id: SheetID = .appUpdate
    let size: SheetSize = .large
}

struct AppUpdateSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: AppUpdateSheetItem

    private let appUpdateService = AppUpdateService.shared

    var body: some View {
        Sheet(id: .appUpdate, data: config) {
            SheetIntro(
                navTitle: localizedString("other__update_nav_title"),
                title: localizedString("other__update_title"),
                description: localizedString("other__update_text"),
                image: "wand",
                continueText: localizedString("other__update_button"),
                cancelText: localizedString("common__cancel"),
                testID: "AppUpdateSheet",
                onCancel: onCancel,
                onContinue: onContinue
            )
        }
    }

    private func onContinue() {
        // Mark as seen and open app store
        app.ignoreAppUpdate()
        UIApplication.shared.open(URL(string: Env.appStoreUrl)!)
        sheets.hideSheet()
    }

    private func onCancel() {
        // Mark as seen and dismiss
        app.ignoreAppUpdate()
        sheets.hideSheet()
    }
}
