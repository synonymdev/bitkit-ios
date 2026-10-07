import BitkitCore
import SwiftUI

struct HomeWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(UsdtWalletManager.self) private var usdt
    @Environment(HwWalletManager.self) private var hwWalletManager

    var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false
    }

    /// Headline total including watch-only hardware-wallet balances (keeps `totalBalanceSats`
    /// semantics unchanged for send/transfer logic; only the headline folds hardware in).
    private var headlineSats: Int {
        let hw = Int(clamping: hwWalletManager.totalSats)
        return wallet.totalBalanceSats.saturatingAdd(hw)
    }

    var body: some View {
        VStack(spacing: 0) {
            MoneyStack(
                sats: headlineSats,
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
            .padding(.bottom, 32)

            if !hwWalletManager.wallets.isEmpty {
                HardwareWalletsGrid(wallets: hwWalletManager.wallets) { hwWallet in
                    navigation.navigate(.hardwareWallet(walletId: hwWallet.id))
                }
                .padding(.bottom, 32)
            }

            if usdt.isConfigured {
                HStack(spacing: 16) {
                    Button { navigation.navigate(.usdtWallet) } label: {
                        WalletBalanceContent {
                            CaptionMText("USDT")
                        } icon: {
                            CircularIcon(icon: "coins", iconColor: .greenAccent, backgroundColor: .green16, size: 24)
                        } amount: {
                            SubtitleText(settings.hideBalance ? " • • • • •" : usdt.balance.map { usdtFormatAmount(amount: $0) } ?? "—")
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("UsdtWallet")
                    CustomDivider(color: .gray4, type: .vertical)
                    Color.clear.frame(maxWidth: .infinity)
                }
                .frame(height: 50)
                .padding(.bottom, 32)
            }

            if hasActivity {
                ActivityLatest()

                Spacer()

                if settings.showWidgets, !app.hasDismissedWidgetsOnboardingHint {
                    WidgetsOnboardingView()
                }
            } else {
                Spacer()
                if usdt.balance ?? 0 == 0 { WalletOnboardingView(type: .home) }
            }
        }
        .padding(.top, ScreenLayout.topPaddingWithSafeArea)
        .padding(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
        .padding(.horizontal)
        .animation(.spring(response: 0.3), value: hasActivity)
    }
}
