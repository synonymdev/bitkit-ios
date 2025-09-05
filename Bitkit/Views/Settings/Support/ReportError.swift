import SwiftUI

struct ReportError: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("settings__support__title_unsuccess"))
                .padding(.bottom, 16)

            BodyMText(t("settings__support__text_unsuccess"))

            Spacer()

            Image("cross")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)

            Spacer()

            CustomButton(
                title: t("settings__support__text_unsuccess_button")
            ) {
                dismiss()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}
