import SwiftUI

struct SecurityChangePinSuccess: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__cp_changed_title"))

            VStack(spacing: 0) {
                BodyMText(t("security__cp_changed_text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 32)

                Spacer()

                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)

                Spacer()

                CustomButton(title: t("common__ok")) {
                    sheets.hideSheet()
                    navigation.navigateBack()
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}
