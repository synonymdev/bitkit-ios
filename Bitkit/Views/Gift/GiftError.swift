import SwiftUI

struct GiftFailed: View {
    @Binding var navigationPath: [GiftRoute]
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("other__gift__error__title"))

            VStack(spacing: 0) {
                BodyMText(t("other__gift__error__text"))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Image("exclamation-mark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()
            }

            CustomButton(
                title: t("common__ok")
            ) {
                sheets.hideSheet()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .accessibilityIdentifier("GiftError")
    }
}
