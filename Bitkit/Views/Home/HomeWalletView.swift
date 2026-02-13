import SwiftUI

struct HomeWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false
    }

    private var topPadding: CGFloat { windowSafeAreaInsets.top + 48 + 16 } // safe area + header + spacing
    private var bottomPadding: CGFloat { windowSafeAreaInsets.bottom + 64 + 32 } // safe area + tab bar + spacing

    var body: some View {
        VStack(spacing: 0) {
            MoneyStack(
                sats: wallet.totalBalanceSats,
                showSymbol: true,
                showEyeIcon: true,
                enableSwipeGesture: settings.swipeBalanceToHide,
                enableHide: true
            )
            .padding(.bottom, 32)

            HStack(spacing: 16) {
                NavigationLink(value: Route.savingsWallet) {
                    WalletBalanceView(type: .onchain, sats: UInt64(wallet.totalOnchainSats))
                }

                CustomDivider(color: .gray4, type: .vertical)

                NavigationLink(value: Route.spendingWallet) {
                    WalletBalanceView(type: .lightning, sats: UInt64(wallet.totalLightningSats))
                }
            }
            .frame(height: 50)
            .padding(.bottom, 32)

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
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .padding(.horizontal)
        .animation(.spring(response: 0.3), value: hasActivity)
    }
}
