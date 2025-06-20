import SwiftUI

struct ReportError: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(
                localizedString("settings__support__text_unsuccess"),
                textColor: .textSecondary
            )
            .padding(.top, 16)
            .padding(.bottom, 32)

            Spacer()

            Image("cross")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)

            Spacer()

            CustomButton(
                title: localizedString("settings__support__text_unsuccess_button")
            ) {
                dismiss()
            }
            .padding(.bottom, 16)
        }
        .navigationTitle(localizedString("settings__support__title_unsuccess"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.horizontal, 16)
    }
}
