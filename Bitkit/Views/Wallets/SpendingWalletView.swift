//
//  SpendingWalletView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SpendingWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    @State private var hasSeenTransferIntro = true

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
                EmptyStateView(type: .spending, onClose: {
                    withAnimation(.spring(response: 0.3)) {
                        app.showSpendingViewEmptyState = false
                    }
                })
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
        .task {
            // Set just once so when app.hasSeenTransferToSavingsIntro is set, it doesn't change this view until reloaded
            hasSeenTransferIntro = app.hasSeenTransferToSavingsIntro
        }
        .onAppear {
            app.showTabBar = true
        }
        .fullScreenCover(isPresented: $app.showTransferToSavingsSheet) {
            NavigationView {
                if hasSeenTransferIntro {
                    SavingsAvailabilityView()
                } else {
                    SavingsIntroView()
                }
            }
        }
    }

    var transferButton: some View {
        SecondaryButton(
            title: "Transfer To Savings",
            icon: Image(systemName: "arrow.up.arrow.down")
                .foregroundColor(.white80)
        ) {
            app.showTransferToSavingsSheet = true
        }
        .padding(.vertical)
    }
}

#Preview {
    NavigationView {
        SpendingWalletView()
    }
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .environmentObject(CurrencyViewModel())
    .environmentObject(ActivityListViewModel())
    .preferredColorScheme(.dark)
}
