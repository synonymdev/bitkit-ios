import SwiftUI

struct HomeWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false
    }

    /// Headline total including watch-only hardware-wallet balances (keeps `totalBalanceSats`
    /// semantics unchanged for send/transfer logic; only the headline folds hardware in).
    private var headlineSats: Int {
        let hw = Int(clamping: hwWalletManager.totalSats)
        let (result, overflow) = wallet.totalBalanceSats.addingReportingOverflow(hw)
        return overflow ? .max : result
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
                HardwareWalletsGrid(wallets: hwWalletManager.wallets) { _ in
                    app.toast(type: .info, title: t("coming_soon__nav_title"))
                }
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
                WalletOnboardingView(type: .home)
            }
        }
        .padding(.top, ScreenLayout.topPaddingWithSafeArea)
        .padding(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
        .padding(.horizontal)
        .animation(.spring(response: 0.3), value: hasActivity)
    }
}
