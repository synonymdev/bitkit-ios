import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var scrollPosition: Int? = 0
    @State private var isEditingWidgets = false

    private var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false
    }

    private var currentPage: Int {
        scrollPosition ?? 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            Header(showWidgetEditButton: currentPage == 1, isEditingWidgets: $isEditingWidgets)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    LazyVStack {
                        HomeWalletView()
                            .frame(height: geometry.size.height)
                            .id(0)

                        if settings.showWidgets {
                            HomeWidgetsView(isEditingWidgets: $isEditingWidgets)
                                .frame(height: geometry.size.height)
                                .id(1)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollPosition)
                .onChange(of: scrollPosition) { _, newValue in
                    // Dismiss this hint after the user has seen it and scrolls to widgets
                    if hasActivity, newValue == 1 {
                        app.hasDismissedWidgetsOnboardingHint = true
                    }
                }
                .refreshable {
                    guard currentPage == 0 else { return }
                    guard wallet.nodeLifecycleState == .running else { return }
                    do {
                        try await wallet.sync()
                        try await activity.syncLdkNodePayments()
                    } catch {
                        app.toast(error)
                    }
                }
            }
            .ignoresSafeArea()

            // Top and bottom gradients
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: ScreenLayout.topPaddingWithSafeArea)

                Spacer()

                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: ScreenLayout.bottomPaddingWithSafeArea)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .navigationBarHidden(true)
        .onAppear {
            TimedSheetManager.shared.onHomeScreenEntered()
        }
        .onDisappear {
            TimedSheetManager.shared.onHomeScreenExited()
        }
    }
}
