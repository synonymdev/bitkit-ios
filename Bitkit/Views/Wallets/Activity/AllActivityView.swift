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
                return t("wallet__activity_tabs__all")
            case .sent:
                return t("wallet__activity_tabs__sent")
            case .received:
                return t("wallet__activity_tabs__received")
            case .other:
                return t("wallet__activity_tabs__other")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                NavigationBar(title: t("wallet__activity_all"))
                    .padding(.bottom, 16)

                ActivityListFilter(viewModel: activity)
                    .padding(.bottom, 16)

                SegmentedControl<ActivityTab>(selectedTab: $selectedTab, tabs: ActivityTab.allCases)
                    .padding(.bottom, 8)
            }

            ScrollView(showsIndicators: false) {
                ActivityList(viewType: .all)
                    /// Leave some space for TabBar
                    .padding(.bottom, 130)
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
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        AllActivityView()
            .environmentObject(ActivityListViewModel())
            .preferredColorScheme(.dark)
    }
}
