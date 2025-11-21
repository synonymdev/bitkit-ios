import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var text: String {
        if GeoService.shared.isGeoBlocked {
            return t("lightning__funding__text_blocked")
        } else {
            return t("lightning__funding__text")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(
                t("lightning__funding__title"),
                accentColor: .purpleAccent
            )
            .padding(.bottom, 8)

            BodyMText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)

            VStack(spacing: 8) {
                RectangleButton(
                    icon: "transfer",
                    title: t("lightning__funding__button1"),
                    isDisabled: wallet.totalOnchainSats == 0 || GeoService.shared.isGeoBlocked,
                    testID: "FundTransfer"
                ) {
                    if app.hasSeenTransferToSpendingIntro {
                        navigation.navigate(.spendingAmount)
                    } else {
                        navigation.navigate(.spendingIntro)
                    }
                }

                RectangleButton(
                    icon: "qr",
                    title: t("lightning__funding__button2"),
                    isDisabled: GeoService.shared.isGeoBlocked,
                    testID: "FundReceive"
                ) {
                    navigation.reset()
                    sheets.showSheet(.receive, data: ReceiveConfig(view: .cjitAmount))
                }

                RectangleButton(
                    icon: "external",
                    title: t("lightning__funding__button3"),
                    testID: "FundCustom"
                ) {
                    navigation.navigate(.fundingAdvanced)
                }
            }

            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .task {
            await app.checkGeoStatus()
        }
    }
}
