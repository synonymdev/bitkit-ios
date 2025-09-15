import SwiftUI

struct SavingsWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("wallet__savings__title"), icon: "btc")

            MoneyStack(
                sats: wallet.totalOnchainSats,
                showSymbol: true,
                showEyeIcon: false,
                enableSwipeGesture: true
            )
            .padding(.top)

            if wallet.totalOnchainSats > 0 {
                if !(app.isGeoBlocked ?? true) {
                    transferButton
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .padding(.top, 32)
                }

                ScrollView(showsIndicators: false) {
                    ActivityList(viewType: .onchain)

                    CustomButton(title: tTodo("Show All"), variant: .tertiary) {
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
            Image("piggybank")
                .resizable()
                .frame(width: 256, height: 256)
                .offset(x: 110)
        }
        .animation(.spring(response: 0.3), value: wallet.totalOnchainSats)
        .overlay {
            if wallet.totalOnchainSats == 0 {
                EmptyStateView(type: .savings)
                    .padding(.horizontal)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    var transferButton: some View {
        CustomButton(
            title: tTodo("Transfer To Spending"),
            variant: .secondary,
            icon: Image("arrow-up-down")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundColor(.white80),
        ) {
            if app.hasSeenTransferToSpendingIntro {
                navigation.navigate(.fundingOptions)
            } else {
                navigation.navigate(.transferIntro)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SavingsWalletView()
    }
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .environmentObject(CurrencyViewModel())
    .environmentObject(ActivityListViewModel())
    .preferredColorScheme(.dark)
}
