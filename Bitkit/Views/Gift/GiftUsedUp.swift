import SwiftUI

struct GiftUsedUp: View {
    @Binding var navigationPath: [GiftRoute]
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("Out of Gifts"))

            VStack(spacing: 0) {
                BodyMText(tTodo("Sorry, you’re too late! All gifts for this code have already been claimed."))
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
        .accessibilityIdentifier("GiftUsedUp")
    }
}
