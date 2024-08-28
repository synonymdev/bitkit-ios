//
//  HomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var wallet = WalletViewModel.shared
            
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("Total balance")
                        .font(.title3)
                    if let balanceSats = wallet.walletBalanceSats {
                        Text("\(balanceSats) sats")
                            .font(.title)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                
                VStack {
                    HStack {
                        Text("Savings")
                            .font(.title3)
                        Spacer()
                        if let onchainBalance = wallet.onchainBalance {
                            Text("\(onchainBalance.total.toSat())")
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    Button(action: {
                        // TODO: buy channel
                    }, label: {
                        Image(systemName: "arrow.up.arrow.down")
                    })
                    HStack {
                        Text("Spending")
                            .font(.title3)
                        Spacer()
                        if let lnBalance = wallet.lightningBalance {
                            Text("\(lnBalance.totalLightningBalanceSats)")
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .padding()
               
                Text("Activity")
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack {
                    if let activityItems = wallet.activityItems {
                        ForEach(activityItems, id: \.self) { item in
                            HStack {
                                switch item {
                                case .onchain(let onchainItem):
                                    Text("⛓️ \(onchainItem.txType == .sent ? "⬆️" : "⬇️")")
                                    Text("\(onchainItem.confirmed ? "✅" : "⏳")")
                                    Spacer()
                                    Text("\(onchainItem.valueSats)")
                                case .lightning(let lightningItem):
                                    Text("⚡️ \(lightningItem.txType == .sent ? "⬆️" : "⬇️")")
                                    Text("\(lightningItem.status == .completed ? "✅" : "⏳")")
                                    Spacer()
                                    Text("\(lightningItem.valueSats)")
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .overlay(content: {
                TabBar()
            })
            .navigationBarItems(trailing: rightNavigationItem)
            .navigationTitle("Bitkit")
            .refreshable {
                do {
                    try await wallet.sync(fullOnchainScan: true)
                } catch {
                    // TODO: show an error
                }
            }
        }
    }
    
    var rightNavigationItem: some View {
        HStack {
            Text(wallet.lightningState.debugEmoji)
            NavigationLink(destination: SettingsListView()) {
                Image(systemName: "gear")
            }
        }
    }
}

#Preview {
    HomeView()
}
