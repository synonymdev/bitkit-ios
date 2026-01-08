import SwiftUI

struct SweepPromptSheetItem: SheetItem {
    let id: SheetID = .sweepPrompt
    let size: SheetSize = .large
}

struct SweepPromptSheet: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    let config: SweepPromptSheetItem

    var body: some View {
        Sheet(id: .sweepPrompt, data: config) {
            SheetIntro(
                navTitle: t("sweep__prompt_title"),
                title: t("sweep__prompt_headline"),
                description: t("sweep__prompt_description"),
                image: "coin-stack",
                continueText: t("sweep__prompt_sweep"),
                cancelText: t("common__cancel"),
                testID: "SweepPromptSheet",
                onCancel: {
                    sheets.hideSheet()
                },
                onContinue: {
                    sheets.hideSheet()
                    navigation.navigate(.sweep)
                }
            )
        }
    }
}

#Preview {
    SweepPromptSheet(config: SweepPromptSheetItem())
        .environmentObject(NavigationViewModel())
        .environmentObject(SheetViewModel())
}
