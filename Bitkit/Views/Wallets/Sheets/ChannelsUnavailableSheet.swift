import SwiftUI

struct ChannelsUnavailableSheetItem: SheetItem {
    let id: SheetID = .channelsUnavailable
    let size: SheetSize = .large
}

/// Shown where the app used to start a transfer to spending: Blocktank no longer opens new channels, so it points to
/// opening one with another provider instead.
struct ChannelsUnavailableSheet: View {
    let config: ChannelsUnavailableSheetItem

    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        Sheet(id: .channelsUnavailable, data: config) {
            SheetIntro(
                navTitle: t("lightning__channels_unavailable__nav_title"),
                title: t("lightning__channels_unavailable__title"),
                description: t("lightning__channels_unavailable__text"),
                image: "lightning",
                continueText: t("common__continue"),
                cancelText: t("common__cancel"),
                accentColor: .purpleAccent,
                testID: "ChannelsUnavailableSheet",
                onCancel: { sheets.hideSheet() },
                onContinue: {
                    sheets.hideSheet()
                    navigation.navigate(.chooseLsp)
                }
            )
        }
    }
}
