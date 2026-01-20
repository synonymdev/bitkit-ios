import SwiftUI

struct ReceiveCjitGeoBlocked: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__receive_bitcoin"), showBackButton: true)

            BodyMText(t("lightning__funding__text_blocked_cjit"))

            Spacer()

            Image("globe-sphere")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer()

            CustomButton(title: t("lightning__funding_advanced__button_short")) {
                sheets.hideSheet()
                navigation.navigate(.fundingAdvanced)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}
