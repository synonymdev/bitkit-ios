import SwiftUI

struct FundManualSuccessView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    // Keep in state so we don't get a new random text on each render
    @State private var randomOkText: String = localizedRandom("common__ok_random")

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(
                    t("lightning__external_success__title"),
                    accentColor: .purpleAccent
                )
                .padding(.top, 16)

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
            }
            .padding(.horizontal, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .navigationTitle(t("lightning__transfer_success__nav_title"))
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        FundManualSuccessView()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
