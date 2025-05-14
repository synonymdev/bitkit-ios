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
    @EnvironmentObject var activity: ActivityListViewModel

    private let sheetHeight = UIScreen.screenHeight - 120

    // If scanned directly from home screen
    @State private var showSendAmountView = false
    @State private var showSendConfirmationView = false
    @State private var showProfile = false
    @State private var showDrawer = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading) {
                    BalanceHeaderView(sats: wallet.totalBalanceSats)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 32)

                if !app.showHomeViewEmptyState {
                    VStack(spacing: 0) {
                        HStack {
                            NavigationLink(destination: SavingsWalletView()) {
                                WalletBalanceView(
                                    type: .onchain,
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
                        .padding(.top)
                        .padding(.horizontal)

                        Suggestions()
                            .padding(.top, 32)

                        CaptionText(localizedString("wallet__activity"))
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 16)
                            .padding(.top, 32)
                            .padding(.horizontal)

                        ActivityLatest(viewType: .all)
                            .padding(.horizontal)
                    }
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
                    try await activity.syncLdkNodePayments()
                } catch {
                    app.toast(error)
                }
            }
            .navigationBarItems(
                leading: leftNavigationItem,
                trailing: rightNavigationItem
            )
            .navigationDestination(isPresented: $app.showScanner) {
                ScannerView(
                    showSendAmountView: $showSendAmountView,
                    showSendConfirmationView: $showSendConfirmationView
                )
            }
            .onChange(of: app.showScanner) { showScanner in
                app.showTabBar = !showScanner
            }
            .navigationDestination(for: Int.self) { destination in
                if destination == 0 {
                    SettingsListView()
                
                }
                
//                switch destination {
//                case .activity:
//                    AllActivityView()
//                case .settings:
//                    SettingsListView()
//                case .appStatus:
//                    AppStatusView()
//                default:
//                    EmptyView()
//                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .accentColor(.white)
        .onAppear {
            app.showTabBar = true

            if Env.isPreview {
                app.showHomeViewEmptyState = true
            }
        }
        .overlay {
            TabBar()
                .bottomSafeAreaPadding()
        }
        .overlay {
            if showDrawer {
                DrawerView(
                    onClose: {
                        withAnimation {
                            showDrawer = false
                        }
                    }, navigationPath: $navigationPath
                )
                .zIndex(1)
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.startLocation.x > UIScreen.main.bounds.width * 0.8 && value.translation.width < -50 {
                        withAnimation {
                            showDrawer = true
                        }
                    }
                }
        )
        .sheet(
            isPresented: $app.showSendOptionsSheet,
            content: {
                SendOptionsView()
                    .presentationDetents([.height(sheetHeight)])
            }
        )
        .sheet(
            isPresented: $app.showReceiveSheet,
            content: {
                ReceiveView()
                    .presentationDetents([.height(sheetHeight)])
            }
        )
        .sheet(
            isPresented: $showSendAmountView,
            content: {
                NavigationView {
                    SendAmountView()
                        .presentationDetents([.height(sheetHeight)])
                }
            }
        )
        .sheet(
            isPresented: $showSendConfirmationView,
            content: {
                NavigationView {
                    SendConfirmationView()
                        .presentationDetents([.height(sheetHeight)])
                }
            }
        )
        .sheet(
            isPresented: $app.showAddTagSheet,
            content: {
                if let activityId = app.selectedActivityIdForTag {
                    AddTagSheet(activityId: activityId)
                        .presentationDetents([.height(400)])
                } else {
                    EmptyView()
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
                Text("Profile View") // Placeholder for profile view
                    .presentationDetents([.height(sheetHeight)])
            }
        }
    }

    var rightNavigationItem: some View {
        HStack {
            Button(action: {
                withAnimation {
                    showDrawer = true
                }
            }) {
                Image("burger")
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
