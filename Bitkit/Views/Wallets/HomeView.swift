//
//  HomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var toast: ToastViewModel
    
    @State private var showNodeState = false
            
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("Total balance")
                        .font(.title3)
                    if let balanceSats = wallet.totalBalanceSats {
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
                        if let balances = wallet.balanceDetails {
                            Text("\(balances.totalOnchainBalanceSats)")
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    NavigationLink(destination: TransferView()) {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    
                    HStack {
                        Text("Spending")
                            .font(.title3)
                        Spacer()
                        if let lnBalance = wallet.balanceDetails {
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
                                Text(item.kind == .onchain ? "⛓️" : "⚡️")
                                Text("\(item.direction == .outbound ? "⬆️" : "⬇️")")
                                Spacer()
                                if let amountSats = item.amountSats {
                                    Text("\(amountSats)")
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
            .refreshable {
                do {
                    try await wallet.sync(fullOnchainScan: true)
                } catch {
                    toast.show(error)
                }
            }
            .navigationBarItems(trailing: rightNavigationItem)
            .navigationTitle("Bitkit")
        }
    }
    
    var rightNavigationItem: some View {
        HStack {
            Text(wallet.nodeLifecycleState.debugEmoji)
                .onTapGesture {
                    showNodeState = true
                }
            NavigationLink(destination: SettingsListView()) {
                Image(systemName: "gear")
            }
        }
        .sheet(isPresented: $showNodeState) {
            NodeStateView()
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(WalletViewModel())
        .environmentObject(ToastViewModel())
}
