import SwiftUI

struct HomeView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var isEditingWidgets = false

    var body: some View {
        ZStack(alignment: .top) {
            Header()

            ScrollView(showsIndicators: false) {
                MoneyStack(
                    sats: wallet.totalBalanceSats,
                    showSymbol: true,
                    showEyeIcon: true,
                    enableSwipeGesture: settings.swipeBalanceToHide,
                    enableHide: true
                )
                .padding(.top, 16 + 48)
                .padding(.horizontal, 16)

                if !app.showHomeViewEmptyState || wallet.totalBalanceSats > 0 {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            NavigationLink(value: Route.savingsWallet) {
                                WalletBalanceView(
                                    type: .onchain,
                                    sats: UInt64(wallet.totalOnchainSats),
                                    amountTestIdentifier: "ActivitySavings"
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
                                    sats: UInt64(wallet.totalLightningSats),
                                    amountTestIdentifier: "ActivitySpending"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 28)
                        .padding(.horizontal)

                        Suggestions()

                        if settings.showWidgets {
                            Widgets(isEditing: $isEditingWidgets)
                                .padding(.top, 32)
                                .padding(.horizontal)
                        }

                        ActivityLatest()
                            .padding(.top, 32)
                            .padding(.horizontal)
                    }
                    /// Leave some space for TabBar
                    .padding(.bottom, 130)
                }
            }
            .scrollDisabled(isEditingWidgets)
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
        .onChange(of: wallet.totalBalanceSats) { newValue in
            if newValue > 0 && app.showHomeViewEmptyState {
                withAnimation(.spring(response: 0.3)) {
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
        .navigationBarHidden(true)
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
}

#Preview {
    HomeView()
        .environmentObject(ActivityListViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
