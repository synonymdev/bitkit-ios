import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    @State private var showNoFundsAlert = false

    /// Spark keeps Spending fundable from savings or another wallet without a channel.
    private var canFundWithSpark: Bool {
        SparkManager.shared.isReady
    }

    /// Where the hardware-wallet option starts Transfer to Spending, from a funded wallet first; nil when none is paired.
    static func hardwareFundingRoute(wallets: [HwWallet], hasSeenIntro: Bool) -> Route? {
        guard let wallet = wallets.first(where: { $0.balanceSats > 0 }) ?? wallets.first else { return nil }
        return hasSeenIntro ? .spendingAmountHw(walletId: wallet.id) : .spendingIntroHw(walletId: wallet.id)
    }

    private func fundWithHardware() {
        if let route = Self.hardwareFundingRoute(wallets: hwWalletManager.wallets, hasSeenIntro: app.hasSeenTransferToSpendingIntro) {
            navigation.navigate(route)
        } else {
            sheets.showSheet(.hardwareConnect)
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

            BodyMText(t(canFundWithSpark ? "lightning__funding__text" : "lightning__transfer_unavailable__text"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)

            VStack(spacing: 8) {
                if canFundWithSpark {
                    RectangleButton(icon: "transfer", title: t("lightning__funding__button1"), testID: "FundTransfer") {
                        if !SparkManager.shared.canFundFromChain {
                            sheets.showSheet(.transferUnavailable)
                        } else if wallet.totalOnchainSats == 0 {
                            showNoFundsAlert = true
                        } else if app.hasSeenTransferToSpendingIntro {
                            navigation.navigate(.spendingAmount)
                        } else {
                            navigation.navigate(.spendingIntro)
                        }
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
                    // A hardware wallet's deposit goes out on Bitkit's chain, which Spark must read.
                    isDisabled: !SparkManager.shared.canFundFromChain,
                    testID: "FundHardware"
                ) {
                    fundWithHardware()
                }
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
        .alert(
            t("lightning__no_funds__title"),
            isPresented: $showNoFundsAlert
        ) {
            Button(t("lightning__no_funds__fund")) {
                navigation.reset()
                sheets.showSheet(.receive, data: ReceiveConfig(view: .qr(tab: .savings)))
            }
            Button(t("common__cancel"), role: .cancel) {}
        } message: {
            Text(t("lightning__no_funds__description"))
        }
        .tint(.purpleAccent)
    }
}
