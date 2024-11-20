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
    private let sheetHeight = UIScreen.screenHeight - 120

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("Total balance")
                        .font(.caption)
                    Text("\(wallet.totalBalanceSats)")
                        .font(.title)
                        .bold()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                HStack {
                    NavigationLink(destination: SavingsWalletView()) {
                        VStack(alignment: .leading) {
                            Text("SAVINGS")
                                .font(.caption)
                            Text("\(wallet.totalOnchainSats)")
                                .font(.title3)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                        .frame(height: 50)

                    NavigationLink(destination: SpendingWalletView()) {
                        VStack(alignment: .leading) {
                            Text("SPENDING")
                                .font(.caption)
                            Text("\(wallet.totalLightningSats)")
                                .font(.title3)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                Text("Activity")
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityLatest(type: .all)

                NavigationLink(
                    destination: ScannerView(),
                    isActive: $app.showScanner
                ) {
                    EmptyView()
                }
                .onChange(of: app.showScanner) { showScanner in
                    app.showTabBar = !showScanner
                }
            }
            .refreshable {
                do {
                    try await wallet.sync()
                } catch {
                    app.toast(error)
                }
            }
            .navigationBarItems(trailing: rightNavigationItem)
            .navigationTitle("Bitkit")
        }
        .onAppear {
            app.showTabBar = true
        }
        .overlay {
            TabBar()
        }
        .sheet(isPresented: $app.showSendOptionsSheet, content: {
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
            Image(systemName: wallet.nodeLifecycleState.systemImage)
                .onTapGesture {
                    showNodeState = true
                }
            NavigationLink(destination: SettingsListView()) {
                Image(systemName: "gear")
            }
        }
        .sheet(isPresented: $showNodeState) {
            NavigationView {
                NodeStateView()
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}
