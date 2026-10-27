import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var showNoFundsAlert = false

    var text: String {
        if GeoService.shared.isGeoBlocked {
            return t("lightning__transfer_unavailable__text")
        } else {
            return t("lightning__funding__text")
        }
    }

    private var manualButton: some View {
        RectangleButton(
            icon: "pencil",
            title: t("lightning__funding__button3"),
            testID: "FundManual"
        ) {
            navigation.navigate(.fundManual(nodeUri: nil))
        }
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

            BodyMText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)

            VStack(spacing: 8) {
                if GeoService.shared.isGeoBlocked {
                    manualButton
                }

                RectangleButton(
                    icon: "transfer",
                    title: t("lightning__funding__button1"),
                    isDisabled: GeoService.shared.isGeoBlocked,
                    testID: "FundTransfer"
                ) {
                    if wallet.totalOnchainSats == 0 {
                        showNoFundsAlert = true
                    } else if app.hasSeenTransferToSpendingIntro {
                        navigation.navigate(.spendingAmount)
                    } else {
                        navigation.navigate(.spendingIntro)
                    }
                }

                if GeoService.shared.isGeoBlocked {
                    RectangleButton(
                        icon: "device-tablet-speaker",
                        title: t("lightning__funding__button_hw"),
                        isDisabled: true,
                        testID: "FundHardware"
                    ) {}
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

                if !GeoService.shared.isGeoBlocked {
                    manualButton
                }
            }

            Spacer()

            if GeoService.shared.isGeoBlocked {
                CustomButton(title: t("common__learn_more"), variant: .secondary) {
                    if let url = URL(string: Env.blocktankSunsetUrl) {
                        UIApplication.shared.open(url)
                    }
                }
                .accessibilityIdentifier("FundLearnMore")
                .padding(.bottom, 16)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .alert(
            t("lightning__no_funds__title"),
            isPresented: $showNoFundsAlert
        ) {
            Button(t("lightning__no_funds__fund")) {
                navigation.reset()
                sheets.showSheet(.receive, data: ReceiveConfig(view: .qr(cjitInvoice: nil, tab: .savings)))
            }
            Button(t("common__cancel"), role: .cancel) {}
        } message: {
            Text(t("lightning__no_funds__description"))
        }
        .tint(.purpleAccent)
        .task {
            await app.checkGeoStatus()
        }
    }
}
