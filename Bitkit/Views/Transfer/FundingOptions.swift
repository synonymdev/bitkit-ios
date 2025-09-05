import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var text: String {
        if app.isGeoBlocked == true {
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
                    icon: Image("transfer").foregroundColor(.purpleAccent).frame(width: 32, height: 32),
                    title: t("lightning__funding__button1"),
                    isDisabled: wallet.totalOnchainSats == 0 || app.isGeoBlocked == true
                ) {
                    navigation.navigate(.spendingIntro)
                }

                RectangleButton(
                    icon: Image("qr").foregroundColor(.purpleAccent).frame(width: 32, height: 32),
                    title: t("lightning__funding__button2"),
                    isDisabled: app.isGeoBlocked == true
                ) {
                    navigation.reset()
                    sheets.showSheet(.receive, data: ReceiveConfig(view: .cjitAmount))
                }

                RectangleButton(
                    icon: Image("external").foregroundColor(.purpleAccent).frame(width: 32, height: 32),
                    title: t("lightning__funding__button3")
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
