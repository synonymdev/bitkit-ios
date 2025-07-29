//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var selectedTab = ActivityTab.all
    @State private var isHorizontalSwipe = false
    @State private var dragOffset: CGFloat = 0

    enum ActivityTab: CaseIterable, CustomStringConvertible {
        case all, sent, received, other

        var description: String {
            switch self {
            case .all:
                return localizedString("wallet__activity_tabs__all")
            case .sent:
                return localizedString("wallet__activity_tabs__sent")
            case .received:
                return localizedString("wallet__activity_tabs__received")
            case .other:
                return localizedString("wallet__activity_tabs__other")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ActivityListFilter(viewModel: activity)
                    .padding(.horizontal)

                SegmentedControl<ActivityTab>(selectedTab: $selectedTab, tabs: ActivityTab.allCases)
                    .padding(.top)
                    .padding(.bottom, 8)
                    .padding(.horizontal)
            }
            // TODO: add blur, glow and drop shadow
            .padding(.top, 100)
            .background(Color.white10)
            .cornerRadius(20, corners: [.bottomLeft, .bottomRight])

            ScrollView(showsIndicators: false) {
                ActivityList(viewType: .all)
                    /// Leave some space for TabBar
                    .padding(.bottom, 130)
                    .padding(.horizontal)
                    .scrollDismissesKeyboard(.interactively)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 20, coordinateSpace: .local)
                            .onChanged { value in
                                let horizontalAmount = value.translation.width
                                let verticalAmount = value.translation.height

                                if abs(horizontalAmount) > abs(verticalAmount) {
                                    isHorizontalSwipe = true
                                    dragOffset = horizontalAmount
                                }
                            }
                            .onEnded { value in
                                let horizontalAmount = value.translation.width
                                let verticalAmount = value.translation.height

                                if abs(horizontalAmount) > abs(verticalAmount) {
                                    if horizontalAmount < -50 {
                                        // Swipe left - move to next tab
                                        if let currentIndex = ActivityTab.allCases.firstIndex(of: selectedTab),
                                            currentIndex < ActivityTab.allCases.count - 1
                                        {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                selectedTab = ActivityTab.allCases[currentIndex + 1]
                                            }
                                        }
                                    } else if horizontalAmount > 50 {
                                        // Swipe right - move to previous tab
                                        if let currentIndex = ActivityTab.allCases.firstIndex(of: selectedTab),
                                            currentIndex > 0
                                        {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                selectedTab = ActivityTab.allCases[currentIndex - 1]
                                            }
                                        }
                                    }
                                }

                                isHorizontalSwipe = false
                                dragOffset = 0
                            }
                    )
            }
            .refreshable {
                do {
                    try await wallet.sync()
                    try await activity.syncLdkNodePayments()
                } catch {
                    app.toast(error)
                }
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("All Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.clear, for: .navigationBar)
    }
}

#Preview {
    NavigationStack {
        AllActivityView()
            .environmentObject(ActivityListViewModel())
            .preferredColorScheme(.dark)
    }
}
