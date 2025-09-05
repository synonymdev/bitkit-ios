import SwiftUI

struct SpendingWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("wallet__spending__title"), icon: "ln")

            MoneyStack(
                sats: wallet.totalLightningSats,
                showSymbol: true,
                showEyeIcon: false,
                enableSwipeGesture: true
            )
            .padding(.top)

            if wallet.totalLightningSats > 0 {
                if let channels = wallet.channels, !channels.isEmpty {
                    transferButton
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .padding(.top, 32)
                }

                ScrollView(showsIndicators: false) {
                    ActivityList(viewType: .lightning)

                    CustomButton(title: t("wallet__activity_show_all"), variant: .tertiary) {
                        navigation.navigate(.activityList)
                    }
                    /// Leave some space for TabBar
                    .padding(.bottom, 130)
                }
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
        .navigationBarHidden(true)
        .padding(.horizontal)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .topTrailing) {
            Image("coin-stack-x-2")
                .resizable()
                .frame(width: 256, height: 256)
                .offset(x: 128)
        }
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
            title: "Transfer To Savings", // TODO: add missing translation
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
