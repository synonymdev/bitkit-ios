import SwiftUI

struct ReportSuccess: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(
                localizedString("settings__support__text_success"),
                textColor: .textSecondary
            )
            .padding(.top, 16)
            .padding(.bottom, 32)

            Spacer()

            Image("email")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)

            Spacer()

            CustomButton(
                title: localizedString("settings__support__text_success_button")
            ) {
                // TODO: Implement navigation to wallet
                dismiss()
            }
            .padding(.bottom, 16)
        }
        .navigationTitle(localizedString("settings__support__title_success"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.horizontal, 16)
    }
}
