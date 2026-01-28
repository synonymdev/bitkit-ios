import SwiftUI

struct SavingsWalletView: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    /// Calculate remaining duration for force close transfers
    private var forceCloseRemainingDuration: String? {
        guard let claimableAtHeight = wallet.forceCloseClaimableAtHeight,
              wallet.currentBlockHeight > 0
        else {
            return nil
        }
        let blocksRemaining = BlockTimeHelpers.blocksRemaining(until: claimableAtHeight, currentHeight: wallet.currentBlockHeight)
        guard blocksRemaining > 0 else { return nil }
        return BlockTimeHelpers.getDurationForBlocks(blocksRemaining)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                NavigationBar(title: t("wallet__savings__title"), icon: "btc")

                MoneyStack(
                    sats: wallet.totalOnchainSats,
                    showSymbol: true,
                    showEyeIcon: false,
                    enableSwipeGesture: true,
                    enableHide: true,
                    testIdPrefix: "TotalBalance"
                )
                .padding(.top)

                if wallet.balanceInTransferToSavings > 0 {
                    IncomingTransfer(
                        amount: UInt64(wallet.balanceInTransferToSavings),
                        remainingDuration: forceCloseRemainingDuration
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                }

                if wallet.totalOnchainSats > 0 {
                    if !GeoService.shared.isGeoBlocked {
                        transferButton
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .padding(.top, 32)
                    }

                    ScrollView(showsIndicators: false) {
                        ActivityList(viewType: .onchain)

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
                Image("piggybank")
                    .resizable()
                    .frame(width: 256, height: 256)
                    .offset(x: 110)
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
        .accessibilityIdentifier("TransferToSpending")
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
