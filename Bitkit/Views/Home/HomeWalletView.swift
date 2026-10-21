import BitkitCore
import SwiftUI

struct HomeWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(UsdtWalletManager.self) private var usdt
    @Environment(HwWalletManager.self) private var hwWalletManager

    private var showsUsdt: Bool {
        usdt.isConfigured && (settings.isUsdtEnabled || usdt.hasProtectedFunds)
    }

    var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false || !usdt.transfers.isEmpty
    }

    /// Headline total including watch-only hardware-wallet balances (keeps `totalBalanceSats`
    /// semantics unchanged for send/transfer logic; only the headline folds hardware in).
    private var headlineSats: Int? {
        Self.aggregateBalance(bitcoinSats: wallet.totalBalanceSats, hardwareSats: hwWalletManager.totalSats,
                              includesUsdt: showsUsdt, usdtBalance: usdt.balance, rate: currency.paykitRate)
    }

    static func aggregateBalance(bitcoinSats: Int, hardwareSats: UInt64, includesUsdt: Bool, usdtBalance: UInt64?,
                                 rate: PaykitExchangeRate?, now: Date = Date()) -> Int?
    {
        let bitcoin = bitcoinSats.saturatingAdd(Int(clamping: hardwareSats))
        guard includesUsdt else { return bitcoin }
        guard let usdtBalance else { return nil }
        guard usdtBalance > 0 else { return bitcoin }
        guard let usdtSats = usdtDisplaySats(amount: usdtFormatAmount(amount: usdtBalance), rate: rate, now: now) else { return nil }
        return bitcoin.saturatingAdd(usdtSats)
    }

    var body: some View {
        let total = headlineSats
        VStack(spacing: 0) {
            MoneyStack(
                sats: total ?? 0,
                isUnavailable: total == nil,
                showSymbol: true,
                showEyeIcon: true,
                enableSwipeGesture: settings.swipeBalanceToHide,
                enableHide: true
            )
            .padding(.bottom, 32)

            HStack(spacing: 16) {
                NavigationLink(value: Route.savingsWallet) {
                    WalletBalanceView(
                        type: .onchain,
                        sats: UInt64(wallet.totalOnchainSats),
                        amountTestIdentifier: "ActivitySavings"
                    )
                }

                CustomDivider(color: .gray4, type: .vertical)

                NavigationLink(value: Route.spendingWallet) {
                    WalletBalanceView(
                        type: .lightning,
                        sats: UInt64(wallet.totalLightningSats),
                        amountTestIdentifier: "ActivitySpending"
                    )
                }
            }
            .frame(height: 50)
            .padding(.bottom, showsUsdt && hwWalletManager.wallets.isEmpty ? 24 : 32)

            if !hwWalletManager.wallets.isEmpty || showsUsdt {
                HardwareWalletsGrid(wallets: hwWalletManager.wallets, showAdditionalWallet: showsUsdt) { hwWallet in
                    navigation.navigate(.hardwareWallet(walletId: hwWallet.id))
                } additionalWallet: {
                    Button { navigation.navigate(.usdtWallet) } label: {
                        WalletBalanceContent {
                            CaptionMText("USDT", kerning: 1)
                        } icon: {
                            Image("tether-circle").resizable().frame(width: 24, height: 24)
                        } amount: {
                            BodyMSBText(settings.hideBalance ? " • • • • •" : usdt.balance.map { usdtOverviewAmount($0) } ?? "—",
                                        kerning: 0, lineHeight: 22)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("UsdtWallet")
                }
                .padding(.bottom, 32)
            }

            if hasActivity {
                ActivityLatest(showsUsdtWallet: showsUsdt)

                Spacer()

                if settings.showWidgets, !app.hasDismissedWidgetsOnboardingHint {
                    WidgetsOnboardingView()
                }
            } else {
                Spacer()
                if usdt.balance ?? 0 == 0 {
                    WalletOnboardingView(type: .home)
                }
            }
        }
        .padding(.top, ScreenLayout.topPaddingWithSafeArea)
        .padding(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
        .padding(.horizontal)
        .animation(.spring(response: 0.3), value: hasActivity)
    }
}
