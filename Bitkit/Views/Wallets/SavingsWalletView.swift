//
//  SavingsWalletView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SavingsWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    @State private var hasSeenTransferIntro = true

    var body: some View {
        VStack {
            BalanceHeaderView(sats: wallet.totalOnchainSats)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            if !app.showSavingsViewEmptyState || wallet.totalOnchainSats > 0 {
                transferButton
                    .transition(.move(edge: .leading).combined(with: .opacity))

                ScrollView {
                    ActivityLatest(viewType: .onchain)
                }
                .refreshable {
                    do {
                        try await wallet.sync()
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
            Image("piggybank")
                .resizable()
                .frame(width: 256, height: 256)
                .offset(x: 110)
                .offset(y: -68)
        }
        .animation(.spring(response: 0.3), value: app.showSavingsViewEmptyState)
        .overlay {
            if wallet.totalOnchainSats == 0 && app.showSavingsViewEmptyState {
                EmptyStateView(
                    type: .savings,
                    onClose: {
                        withAnimation(.spring(response: 0.3)) {
                            app.showSavingsViewEmptyState = false
                        }
                    }
                )
                .padding(.horizontal)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: app.showSavingsViewEmptyState)
        .onChange(of: wallet.totalOnchainSats) { _ in
            if wallet.totalOnchainSats > 0 {
                DispatchQueue.main.async {
                    app.showSavingsViewEmptyState = false
                }
            }
        }
        .task {
            // Set just once so when app.hasSeenTransferToSpendingIntro is set, it doesn't change this view until reloaded
            hasSeenTransferIntro = app.hasSeenTransferToSpendingIntro
        }
        .onAppear {
            app.showTabBar = true
        }
        .fullScreenCover(isPresented: $app.showTransferToSpendingSheet) {
            NavigationView {
                if hasSeenTransferIntro {
                    FundingOptionsView()
                } else {
                    TransferIntroView()
                }
            }
        }
    }

    var transferButton: some View {
        CustomButton(
            title: "Transfer To Spending", //TODO: add missing translation //NSLocalizedString("lightning__spending_confirm__label", comment: ""),
            variant: .secondary,
            icon: Image(systemName: "arrow.up.arrow.down")
                .foregroundColor(.white80)
        ) {
            app.showTransferToSpendingSheet = true
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        SavingsWalletView()
    }
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .environmentObject(CurrencyViewModel())
    .environmentObject(ActivityListViewModel())
    .preferredColorScheme(.dark)
}
