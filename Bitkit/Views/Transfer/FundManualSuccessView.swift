import SwiftUI

struct FundManualSuccessView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    // Keep in state so we don't get a new random text on each render
    @State private var randomOkText: String = localizedRandom("common__ok_random")

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__transfer_success__nav_title"), showBackButton: false)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                DisplayText(
                    t("lightning__external_success__title"),
                    accentColor: .purpleAccent
                )
                .fixedSize(horizontal: false, vertical: true)

                BodyMText(
                    t("lightning__external_success__text"),
                    textColor: .textSecondary, accentColor: .white, accentFont: Fonts.bold
                )

                Spacer()

                Image("switch")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer()

                CustomButton(
                    title: randomOkText,
                    size: .large
                ) {
                    navigation.reset()
                }
                .accessibilityIdentifier("ExternalSuccess-button")
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ExternalSuccess")
        }
        .navigationBarHidden(true)
        .interactiveDismissDisabled()
    }
}

#Preview {
    NavigationStack {
        FundManualSuccessView()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
