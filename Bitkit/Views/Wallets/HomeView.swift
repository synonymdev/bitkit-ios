//
//  HomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var activity: ActivityListViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            MoneyStack(sats: wallet.totalBalanceSats, showEyeIcon: true, enableSwipeGesture: true)
                .padding(.horizontal)
                .padding(.top, 32)

            if !app.showHomeViewEmptyState {
                VStack(spacing: 0) {
                    HStack {
                        NavigationLink(value: Route.savingsWallet) {
                            WalletBalanceView(
                                type: .onchain,
                                sats: UInt64(wallet.totalOnchainSats)
                            )
                        }

                        Divider()
                            .frame(height: 50)

                        NavigationLink(value: Route.spendingWallet) {
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

                    if wallet.showWidgets {
                        Widgets()
                            .padding(.top, 32)
                            .padding(.horizontal)
                    }

                    ActivityLatest()
                        .padding(.horizontal)
                }
                /// Leave some space for TabBar
                .padding(.bottom, 130)
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
        .navigationBarTitleDisplayMode(.inline)
        .accentColor(.white)
        .onAppear {
            if Env.isPreview {
                app.showHomeViewEmptyState = true
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.startLocation.x > UIScreen.main.bounds.width * 0.8 && value.translation.width < -50 {
                        withAnimation {
                            app.showDrawer = true
                        }
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
    }

    var leftNavigationItem: some View {
        Button(action: {
            navigation.navigate(.profile)
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
    }

    var rightNavigationItem: some View {
        HStack {
            Button(action: {
                withAnimation {
                    app.showDrawer = true
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
