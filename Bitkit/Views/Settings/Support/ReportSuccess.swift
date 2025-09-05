import SwiftUI

struct ReportSuccess: View {
    @EnvironmentObject private var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("settings__support__title_success"))
                .padding(.bottom, 16)

            BodyMText(t("settings__support__text_success"))

            Spacer()

            Image("email")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)

            Spacer()

            CustomButton(title: t("settings__support__text_success_button")) {
                navigation.reset()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}
