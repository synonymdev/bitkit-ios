import SwiftUI

struct SpendingWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                NavigationBar(title: t("wallet__spending__title"), icon: "ln")

                MoneyStack(
                    sats: wallet.totalLightningSats,
                    showSymbol: true,
                    showEyeIcon: false,
                    enableSwipeGesture: true,
                    enableHide: true,
                    testIdPrefix: "TotalBalance"
                )
                .padding(.top)

                if wallet.balanceInTransferToSpending > 0 {
                    IncomingTransfer(amount: UInt64(wallet.balanceInTransferToSpending))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                }

                if wallet.totalLightningSats > 0 {
                    if let channels = wallet.channels, !channels.isEmpty {
                        transferButton
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .padding(.top, 32)
                    }

                    ScrollView(showsIndicators: false) {
                        ActivityList(viewType: .lightning)

                        CustomButton(title: t("common__show_all"), variant: .tertiary) {
                            navigation.navigate(.activityList)
                        }
                        /// Leave some space for TabBar
                        .padding(.bottom, 130)
                    }
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
            }
            .padding(.horizontal)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(alignment: .topTrailing) {
                Image("coin-stack-x-2")
                    .resizable()
                    .frame(width: 256, height: 256)
                    .offset(x: 128)
            }

            // Bottom gradient: black 0% to black 100%
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .navigationBarHidden(true)
        .animation(.spring(response: 0.3), value: wallet.totalLightningSats)
        .overlay {
            if wallet.totalLightningSats == 0 {
                EmptyStateView(type: .spending)
                    .padding(.horizontal)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
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
        SpendingWalletView()
    }
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .environmentObject(CurrencyViewModel())
    .environmentObject(ActivityListViewModel())
    .preferredColorScheme(.dark)
}
