//
//  SpendingWalletView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SpendingWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack {
            BalanceHeaderView(sats: wallet.totalLightningSats)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()

            if !app.showSpendingViewEmptyState || wallet.totalLightningSats > 0 {
                if let channels = wallet.channels, !channels.isEmpty {
                    transferButton
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ScrollView {
                    ActivityLatest(viewType: .lightning)
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
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            Image("coin-stack-x-2")
                .resizable()
                .frame(width: 256, height: 256)
                .offset(x: 128)
                .offset(y: -80)
        }
        .animation(.spring(response: 0.3), value: app.showSpendingViewEmptyState)
        .overlay {
            if wallet.totalLightningSats == 0 && app.showSpendingViewEmptyState {
                EmptyStateView(
                    type: .spending,
                    onClose: {
                        withAnimation(.spring(response: 0.3)) {
                            app.showSpendingViewEmptyState = false
                        }
                    }
                )
                .padding(.horizontal)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: app.showSpendingViewEmptyState)
        .onChange(of: wallet.totalLightningSats) { _ in
            if wallet.totalLightningSats > 0 {
                DispatchQueue.main.async {
                    app.showSpendingViewEmptyState = false
                }
            }
        }
    }

    var transferButton: some View {
        CustomButton(
            title: NSLocalizedString("lightning__savings_confirm__label", comment: ""),
            variant: .secondary,
            icon: Image(systemName: "arrow.up.arrow.down")
                .foregroundColor(.white80)
        ) {
            if app.hasSeenTransferToSavingsIntro {
                navigation.navigate(.savingsAvailability)
            } else {
                navigation.navigate(.savingsIntro)
            }
        }
        .padding()
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
