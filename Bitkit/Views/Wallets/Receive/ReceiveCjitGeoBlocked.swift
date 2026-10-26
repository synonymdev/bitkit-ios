import SwiftUI

struct ReceiveCjitGeoBlocked: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        TransferUnavailableContent(
            navTitle: t("lightning__transfer_unavailable__nav_title"),
            description: t("lightning__transfer_unavailable__text"),
            showBackButton: true
        ) {
            sheets.hideSheet()
            navigation.navigate(.fundManual(nodeUri: nil))
        }
        .navigationBarHidden(true)
        .sheetBackground()
    }
}
