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

    var body: some View {
        VStack {
            BalanceHeaderView(sats: wallet.totalOnchainSats)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()

            NavigationLink(destination: {
                TransferView()
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
        }
        .onAppear {
            app.showTabBar = true
        }
    }
}

#Preview {
    SavingsWalletView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}
