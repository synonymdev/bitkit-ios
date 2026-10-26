import SwiftUI

struct ReceiveCjitGeoBlocked: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        TransferUnavailableContent(
            navTitle: t("wallet__receive_bitcoin"),
            description: t("lightning__transfer_unavailable__text_receive"),
            showBackButton: true
        ) {
            sheets.hideSheet()
            navigation.navigate(.fundManual(nodeUri: nil))
        }
        .navigationBarHidden(true)
        .sheetBackground()
    }
}
