import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    private var headerTopPadding: CGFloat {
        // NavBar + Filter + SegmentedControl + spacing
        return ScreenLayout.topPaddingWithoutSafeArea + 116
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ScrollView - base layer, full height, content scrolls behind header
            ScrollView(showsIndicators: false) {
                ActivityList(viewType: .all)
                    // .padding(.top, headerTopPadding)
                    .scrollDismissesKeyboard(.interactively)
                    .highPriorityGesture(
                        // TODO: rewrite using TabView
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
            .contentMargins(.top, headerTopPadding)
            .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
            .padding(.horizontal, 16)
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

            // Header - overlay on top, scroll content goes behind it
            VStack(spacing: 0) {
                NavigationBar(title: t("wallet__activity"))
                    .padding(.bottom, 16)

                ActivityListFilter(viewModel: activity)
                    .padding(.bottom, 16)

                SegmentedControl(selectedTab: $activity.selectedTab, tabs: ActivityTab.allCases)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .background(
                ZStack {
                    BlurView()
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.black, location: 0.0),
                            .init(color: Color.black, location: 0.4),
                            .init(color: Color.black.opacity(0), location: 1.0),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea(edges: .top)
            )
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 20)

            // Bottom gradient overlay
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
