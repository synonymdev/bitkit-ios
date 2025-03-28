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
    @EnvironmentObject var currency: CurrencyViewModel

    @State private var showNodeState = false
    private let sheetHeight = UIScreen.screenHeight - 120

    // If scanned directly from home screen
    @State private var showSendAmountView = false
    @State private var showSendConfirmationView = false

    @State private var showProfile = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading) {
                    BalanceHeaderView(sats: wallet.totalBalanceSats)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .padding(.top)

                if !app.showHomeViewEmptyState {
                    HStack {
                        NavigationLink(destination: SavingsWalletView()) {
                            WalletBalanceView(
                                type: .bitcoin,
                                sats: UInt64(wallet.totalOnchainSats)
                            )
                        }

                        Divider()
                            .frame(height: 50)

                        NavigationLink(destination: SpendingWalletView()) {
                            WalletBalanceView(
                                type: .lightning,
                                sats: UInt64(wallet.totalLightningSats)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Text("ACTIVITY")
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    ActivityLatest(viewType: .all)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: app.showHomeViewEmptyState)
            .overlay {
                if wallet.totalBalanceSats == 0 && app.showHomeViewEmptyState {
                    EmptyStateView(
                        type: .home,
                        onClose: {
                            withAnimation(.spring(response: 0.3)) {
                                app.showHomeViewEmptyState = false
                            }
                        }
                    )
                    .padding(.horizontal)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: app.showHomeViewEmptyState)
            .onChange(of: wallet.totalBalanceSats) { _ in
                if wallet.totalBalanceSats > 0 {
                    DispatchQueue.main.async {
                        app.showHomeViewEmptyState = false
                    }
                }
            }
            .refreshable {
                guard wallet.nodeLifecycleState == .running else {
                    return
                }
                do {
                    try await wallet.sync()
                } catch {
                    app.toast(error)
                }
            }
            .navigationBarItems(
                leading: leftNavigationItem,
                trailing: rightNavigationItem
            )
            .background {
                NavigationLink(
                    destination: ScannerView(
                        showSendAmountView: $showSendAmountView,
                        showSendConfirmationView: $showSendConfirmationView
                    ),
                    isActive: $app.showScanner
                ) {
                    EmptyView()
                }
                .onChange(of: app.showScanner) { showScanner in
                    app.showTabBar = !showScanner
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            app.showTabBar = true

            if Env.isPreview {
                app.showHomeViewEmptyState = true
            }
        }
        .overlay {
            TabBar()
                .padding(.bottom, 20)
        }
        .sheet(
            isPresented: $app.showSendOptionsSheet,
            content: {
                if #available(iOS 16.0, *) {
                    SendOptionsView()
                        .presentationDetents([.height(sheetHeight)])
                } else {
                    SendOptionsView()  // Will just consume full screen on older iOS versions
                }
            }
        )
        .sheet(
            isPresented: $app.showReceiveSheet,
            content: {
                if #available(iOS 16.0, *) {
                    ReceiveQR()
                        .presentationDetents([.height(sheetHeight)])
                } else {
                    ReceiveQR()  // Will just consume full screen on older iOS versions
                }
            }
        )
        .sheet(
            isPresented: $showSendAmountView,
            content: {
                NavigationView {
                    if #available(iOS 16.0, *) {
                        SendAmountView()
                            .presentationDetents([.height(sheetHeight)])
                    } else {
                        SendAmountView()  // Will just consume full screen on older iOS versions
                    }
                }
            }
        )
        .sheet(
            isPresented: $showSendConfirmationView,
            content: {
                NavigationView {
                    if #available(iOS 16.0, *) {
                        SendConfirmationView()
                            .presentationDetents([.height(sheetHeight)])
                    } else {
                        SendConfirmationView()  // Will just consume full screen on older iOS versions
                    }
                }
            }
        )
        .onChange(of: app.resetSendStateToggle) { _ in
            // If this is triggered it means we had a successful send and need to drop the sheet
            showSendAmountView = false
            showSendConfirmationView = false
        }
    }

    var leftNavigationItem: some View {
        Button(action: {
            showProfile = true
        }) {
            HStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)

                Text("Your Name")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
        }
        .sheet(isPresented: $showProfile) {
            NavigationView {
                if #available(iOS 16.0, *) {
                    Text("Profile View")  // Placeholder for profile view
                        .presentationDetents([.height(sheetHeight)])
                } else {
                    Text("Profile View")  // Placeholder for profile view
                }
            }
        }
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
        .environmentObject(CurrencyViewModel())
        .environmentObject(ActivityListViewModel())
        .preferredColorScheme(.dark)
}
