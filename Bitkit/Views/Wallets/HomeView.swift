//
//  HomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    
    @State private var showNodeState = false
    
    private let sheetHeight = UIScreen.screenHeight - 200

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
                    app.toast(error)
                }
            }
            .navigationBarItems(trailing: rightNavigationItem)
            .navigationTitle("Bitkit")
        }
        .sheet(isPresented: $app.showSendSheet, content: {
            if #available(iOS 16.0, *) {
                SendOptionsView()
                    .presentationDetents([.height(sheetHeight)])
            } else {
                SendOptionsView() // Will just consume full screen on older iOS versions
            }
        })
        .sheet(isPresented: $app.showReceiveSheet, content: {
            if #available(iOS 16.0, *) {
                ReceiveQR()
                    .presentationDetents([.height(sheetHeight)])
            } else {
                ReceiveQR() // Will just consume full screen on older iOS versions
            }
        })
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
        .environmentObject(AppViewModel())
}
