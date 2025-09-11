import SwiftUI

struct AppUpdateSheetItem: SheetItem {
    let id: SheetID = .appUpdate
    let size: SheetSize = .large
}

struct AppUpdateSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: AppUpdateSheetItem

    var body: some View {
        Sheet(id: .appUpdate, data: config) {
            SheetIntro(
                navTitle: t("other__update_nav_title"),
                title: t("other__update_title"),
                description: t("other__update_text"),
                image: "wand",
                continueText: t("other__update_button"),
                cancelText: t("common__cancel"),
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
