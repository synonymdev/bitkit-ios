import SwiftUI

struct WalletTabView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 32) {
                MoneyStack(
                    sats: wallet.totalBalanceSats,
                    showSymbol: true,
                    showEyeIcon: true,
                    enableSwipeGesture: settings.swipeBalanceToHide,
                    enableHide: true
                )

                HStack(spacing: 16) {
                    NavigationLink(value: Route.savingsWallet) {
                        WalletBalanceView(type: .onchain, sats: UInt64(wallet.totalOnchainSats))
                    }

                    CustomDivider(color: .gray4, type: .vertical)

                    NavigationLink(value: Route.spendingWallet) {
                        WalletBalanceView(type: .lightning, sats: UInt64(wallet.totalLightningSats))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if hasActivity {
                    VStack(spacing: 0) {
                        ActivityLatest()

                        if settings.showWidgets, !app.hasDismissedWidgetsOnboardingHint {
                            WidgetsOnboardingView()
                        }
                    }
                }
            }
            .padding(.top, windowSafeAreaInsets.top + 48) // Safe area + header
            .padding(.horizontal)
            .padding(.bottom, 120) // Leave space for tab bar and dots
        }
        .scrollDisabled(!hasActivity)
        .refreshable {
            guard wallet.nodeLifecycleState == .running else {
                return
            }
            do {
                try await wallet.sync()
                try await activity.syncLdkNodePayments()
            } catch {
                app.toast(error)
            }
        }
        .animation(.spring(response: 0.3), value: hasActivity)
        .overlay {
            if !hasActivity {
                EmptyStateView(type: .home)
                    .padding(.horizontal)
            }
        }
    }
}
