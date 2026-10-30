import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel

    /// Spark keeps Spending fundable from savings or another wallet without a channel.
    private var canFundWithSpark: Bool {
        SparkManager.shared.isReady
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__funding__nav_title"))
                .padding(.bottom, 16)

            DisplayText(
                t("lightning__funding__title"),
                accentColor: .purpleAccent
            )
            .padding(.bottom, 8)

            BodyMText(t(canFundWithSpark ? "lightning__funding__text" : "lightning__transfer_unavailable__text"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)

            VStack(spacing: 8) {
                if canFundWithSpark {
                    RectangleButton(icon: "transfer", title: t("lightning__funding__button1"), testID: "FundTransfer") {
                        navigation.navigate(.sparkFundingAmount)
                    }
                    RectangleButton(icon: "qr", title: t("lightning__funding__button2"), testID: "FundReceive") {
                        navigation.reset()
                        sheets.showSheet(.receive)
                    }
                }

                RectangleButton(
                    icon: "pencil",
                    title: t("lightning__funding__button3"),
                    testID: "FundManual"
                ) {
                    navigation.navigate(.fundManual(nodeUri: nil))
                }

                if !canFundWithSpark {
                    RectangleButton(icon: "transfer", title: t("lightning__funding__button1"), isDisabled: true, testID: "FundTransfer") {}
                }
                RectangleButton(
                    icon: "device-tablet-speaker",
                    title: t("lightning__funding__button_hw"),
                    isDisabled: true,
                    testID: "FundHardware"
                ) {}
                if !canFundWithSpark {
                    RectangleButton(icon: "qr", title: t("lightning__funding__button2"), isDisabled: true, testID: "FundReceive") {}
                }
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
