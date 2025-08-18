import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            MoneyStack(
                sats: wallet.totalBalanceSats,
                showSymbol: true,
                showEyeIcon: true,
                enableSwipeGesture: settings.swipeBalanceToHide
            )
            .padding(.horizontal)
            .padding(.top, 32)

            if !app.showHomeViewEmptyState {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        NavigationLink(value: Route.savingsWallet) {
                            WalletBalanceView(
                                type: .onchain,
                                sats: UInt64(wallet.totalOnchainSats)
                            )
                        }

                        Divider()
                            .frame(width: 1, height: 50)
                            .background(Color.white16)
                            .padding(.trailing, 16)
                            .padding(.leading, 16)

                        NavigationLink(value: Route.spendingWallet) {
                            WalletBalanceView(
                                type: .lightning,
                                sats: UInt64(wallet.totalLightningSats)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 28)
                    .padding(.horizontal)

                    Suggestions()

                    if settings.showWidgets {
                        Widgets()
                            .padding(.top, 32)
                            .padding(.horizontal)
                    }

                    ActivityLatest()
                        .padding(.horizontal)
                }
                /// Leave some space for TabBar
                .padding(.bottom, 130)
            }
        }
        /// Dismiss (calculator widget) keyboard when scrolling
        .scrollDismissesKeyboard(.immediately)
        .animation(.spring(response: 0.3), value: app.showHomeViewEmptyState)
        .overlay {
            if wallet.totalBalanceSats == 0 && app.showHomeViewEmptyState {
                EmptyStateView(
                    type: .home,
                    onClose: {
                        withAnimation(.spring(response: 0.3)) {
                            app.showHomeViewEmptyState = false
                        }
                    }
                )
                .padding(.horizontal)
            }
        }
        .animation(.spring(response: 0.3), value: app.showHomeViewEmptyState)
        .onChange(of: wallet.totalBalanceSats) { _ in
            if wallet.totalBalanceSats > 0 {
                DispatchQueue.main.async {
                    app.showHomeViewEmptyState = false
                }
            }
        }
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
        .navigationBarItems(
            leading: leftNavigationItem,
            trailing: rightNavigationItem
        )
        .navigationBarTitleDisplayMode(.inline)
        .accentColor(.white)
        .onAppear {
            if Env.isPreview {
                app.showHomeViewEmptyState = true
            }

            // Notify timed sheet manager that user is on home screen
            TimedSheetManager.shared.onHomeScreenEntered()
        }
        .onDisappear {
            // Notify timed sheet manager that user left home screen
            TimedSheetManager.shared.onHomeScreenExited()
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.startLocation.x > UIScreen.main.bounds.width * 0.8 && value.translation.width < -50 {
                        withAnimation {
                            app.showDrawer = true
                        }
                    }
                }
        )
    }

    var leftNavigationItem: some View {
        Button {
            if app.hasSeenProfileIntro {
                navigation.navigate(.profile)
            } else {
                navigation.navigate(.profileIntro)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)

                TitleText(t("slashtags__your_name_capital"))
            }
            .frame(height: 46)
        }
    }

    var rightNavigationItem: some View {
        HStack {
            Button {
                withAnimation {
                    app.showDrawer = true
                }
            } label: {
                Image("burger")
            }
        }
        .frame(height: 46)
    }
}

#Preview {
    HomeView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(ActivityListViewModel())
        .environmentObject(SettingsViewModel())
        .preferredColorScheme(.dark)
}
