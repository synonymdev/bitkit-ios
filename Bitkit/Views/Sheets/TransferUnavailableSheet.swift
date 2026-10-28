import SwiftUI

/// Opens a channel with the primary node, or explains that transfers need manual setup without one.
@MainActor
func showTransferToSpending(sheets: SheetViewModel, navigation: NavigationViewModel) {
    guard let primaryNodeUri = Env.primaryNodeUri else {
        sheets.showSheet(.transferUnavailable)
        return
    }
    navigation.navigate(.fundManual(nodeUri: primaryNodeUri))
}

struct TransferUnavailableSheetItem: SheetItem {
    let id: SheetID = .transferUnavailable
    let size: SheetSize = .large
}

/// Shown instead of the Blocktank transfer to spending, which is no longer available.
struct TransferUnavailableSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    let config: TransferUnavailableSheetItem

    var body: some View {
        Sheet(id: .transferUnavailable, data: config) {
            TransferUnavailableContent(
                navTitle: t("lightning__transfer_unavailable__nav_title"),
                description: t("lightning__transfer_unavailable__text")
            ) {
                sheets.hideSheet()
                navigation.navigate(.fundManual(nodeUri: nil))
            }
        }
    }
}

struct TransferUnavailableContent: View {
    let navTitle: String
    let description: String
    var showBackButton = false
    let onContinue: () -> Void

    var body: some View {
        SheetIntro(
            navTitle: navTitle,
            title: t("lightning__transfer_unavailable__title"),
            description: description,
            image: "lightning",
            continueText: t("common__continue"),
            cancelText: t("common__learn_more"),
            accentColor: .purpleAccent,
            testID: "TransferUnavailable",
            cancelTestID: "TransferUnavailableLearnMore",
            continueTestID: "TransferUnavailableContinue",
            showBackButton: showBackButton,
            onCancel: {
                if let url = URL(string: Env.blocktankSunsetUrl) {
                    UIApplication.shared.open(url)
                }
            },
            onContinue: onContinue
        )
    }
}
