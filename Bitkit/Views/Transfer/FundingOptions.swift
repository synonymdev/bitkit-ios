import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__funding__nav_title"))
                .padding(.bottom, 16)

            DisplayText(
                t("lightning__funding__title"),
                accentColor: .purpleAccent
            )
            .padding(.bottom, 8)

            BodyMText(t("lightning__transfer_unavailable__text"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)

            RectangleButton(
                icon: "pencil",
                title: t("lightning__funding__button3"),
                testID: "FundManual"
            ) {
                navigation.navigate(.fundManual(nodeUri: nil))
            }

            Spacer()

            CustomButton(title: t("common__learn_more"), variant: .secondary) {
                if let url = URL(string: Env.blocktankSunsetUrl) {
                    UIApplication.shared.open(url)
                }
            }
            .accessibilityIdentifier("FundLearnMore")
            .padding(.bottom, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}
