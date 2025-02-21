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

            if !app.showSavingsViewEmptyState {
                fundingButton
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
                EmptyStateView(type: .savings, onClose: {
                    withAnimation(.spring(response: 0.3)) {
                        app.showSavingsViewEmptyState = false
                    }
                })
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
            // Set just once so when app.hasSeenTransferIntro is set, it doesn't change this view until reloaded
            hasSeenTransferIntro = app.hasSeenTransferIntro
        }
        .onAppear {
            app.showTabBar = true
        }
        .fullScreenCover(isPresented: $app.showFundingSheet) {
            NavigationView {
                if hasSeenTransferIntro {
                    FundingOptionsView()
                } else {
                    TransferIntroView()
                }
            }
        }
    }

    var fundingButton: some View {
        Button(action: {
            app.showFundingSheet = true
        }) {
            HStack {
                Image(systemName: "arrow.up.arrow.down")
                Text("Transfer To Spending")
            }
            .padding()
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .padding(.vertical)
        }
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
