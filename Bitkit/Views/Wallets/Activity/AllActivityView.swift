import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                NavigationBar(title: t("wallet__activity"))
                    .padding(.bottom, 16)

                ActivityListFilter(viewModel: activity)
                    .padding(.bottom, 16)

                SegmentedControl(selectedTab: $activity.selectedTab, tabs: ActivityTab.allCases)

                ScrollView(showsIndicators: false) {
                    ActivityList(viewType: .all)
                        .scrollDismissesKeyboard(.interactively)
                        .highPriorityGesture(
                            // TODO: rewrite or remove, causing UI freezes
                            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                                .onEnded { value in
                                    let horizontalAmount = value.translation.width
                                    let verticalAmount = value.translation.height

                                    if abs(horizontalAmount) > abs(verticalAmount) {
                                        if horizontalAmount < -50 {
                                            // Swipe left - move to next tab
                                            if let currentIndex = ActivityTab.allCases.firstIndex(of: activity.selectedTab),
                                               currentIndex < ActivityTab.allCases.count - 1
                                            {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    activity.selectedTab = ActivityTab.allCases[currentIndex + 1]
                                                }
                                            }
                                        } else if horizontalAmount > 50 {
                                            // Swipe right - move to previous tab
                                            if let currentIndex = ActivityTab.allCases.firstIndex(of: activity.selectedTab),
                                               currentIndex > 0
                                            {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    activity.selectedTab = ActivityTab.allCases[currentIndex - 1]
                                                }
                                            }
                                        }
                                    }
                                }
                        )
                }
                .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
                .scrollDismissesKeyboard(.interactively)
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
            .padding(.horizontal, 16)

            // Bottom gradient: black 0% to black 100%
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: ScreenLayout.bottomPaddingWithSafeArea)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .navigationBarHidden(true)
        .onAppear {
            activity.resetFilters()
        }
    }
}

#Preview {
    NavigationStack {
        AllActivityView()
            .environmentObject(ActivityListViewModel())
            .preferredColorScheme(.dark)
    }
}
