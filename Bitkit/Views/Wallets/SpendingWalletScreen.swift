import SwiftUI

struct SpendingWalletScreen: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    private var shouldShowOnboarding: Bool {
        let hasLightningActivities = activity.lightningActivities?.isEmpty == false
        return wallet.totalLightningSats == 0 && !hasLightningActivities
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationBar(title: t("wallet__spending__title"), icon: "ln")
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    MoneyStack(
                        sats: wallet.totalLightningSats,
                        showSymbol: true,
                        showEyeIcon: false,
                        enableSwipeGesture: true,
                        enableHide: true,
                        testIdPrefix: "TotalBalance"
                    )

                    if wallet.balanceInTransferToSpending > 0 {
                        IncomingTransfer(amount: UInt64(wallet.balanceInTransferToSpending))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 16)
                    }

                    if shouldShowOnboarding && wallet.totalOnchainSats > 0 && !GeoService.shared.isGeoBlocked {
                        transferFromSavingsButton
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .padding(.top, 28)
                    }

                    if !shouldShowOnboarding {
                        if let channels = wallet.channels, !channels.isEmpty {
                            transferButton
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                .padding(.top, 28)
                        }

                        ActivityList(viewType: .lightning)

                        CustomButton(title: t("common__show_all"), variant: .tertiary) {
                            navigation.navigate(.activityList)
                        }
                    }
                }
                .contentMargins(.top, ScreenLayout.topPaddingWithoutSafeArea)
                .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
                .accessibilityIdentifier("HomeScrollView")
                .refreshable {
                    do {
                        try await wallet.sync()
                        try await activity.syncLdkNodePayments()
                    } catch {
                        app.toast(error)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 400)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            .padding(.horizontal)
            .background(alignment: .topTrailing) {
                Image("coin-stack-x-2")
                    .resizable()
                    .frame(width: 256, height: 256)
                    .offset(x: 128)
            }

            VStack {
                Spacer()

                if shouldShowOnboarding {
                    WalletOnboardingView(type: .spending)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .padding(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
                        .padding(.horizontal, 16)
                }
            }
            .ignoresSafeArea(edges: .bottom)

            // Bottom gradient: black 0% to black 100%
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: ScreenLayout.bottomPaddingWithSafeArea)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .navigationBarHidden(true)
        .animation(.spring(response: 0.3), value: wallet.totalLightningSats)
    }

    var transferFromSavingsButton: some View {
        CustomButton(
            title: t("lightning__transfer_to_spending_button"),
            variant: .secondary,
            icon: Image("arrow-up-down")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundColor(.white80)
        ) {
            if app.hasSeenTransferToSpendingIntro {
                navigation.navigate(.spendingAmount)
            } else {
                navigation.navigate(.spendingIntro)
            }
        }
        .accessibilityIdentifier("TransferFromSavings")
    }

    var transferButton: some View {
        CustomButton(
            title: t("lightning__transfer_to_savings_button"),
            variant: .secondary,
            icon: Image("arrow-up-down")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundColor(.white80)
        ) {
            if app.hasSeenTransferToSavingsIntro {
                navigation.navigate(.savingsAvailability)
            } else {
                navigation.navigate(.savingsIntro)
            }
        }
        .accessibilityIdentifier("TransferToSavings")
    }
}

#Preview {
    NavigationStack {
        SpendingWalletScreen()
    }
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .environmentObject(CurrencyViewModel())
    .environmentObject(ActivityListViewModel())
    .preferredColorScheme(.dark)
}
