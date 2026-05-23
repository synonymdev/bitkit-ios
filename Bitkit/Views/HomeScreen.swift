import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var scrollPosition: Int? = 0
    @State private var isEditingWidgets = false
    /// Overlay visibility is isolated via `@Observable` + `.environment` so toggling it does not
    /// invalidate `HomeScreen`'s body (which would reset the scroll view's refresh layout).
    @State private var pullRefreshIndicator = HomePullRefreshIndicator()

    private var currentPage: Int {
        scrollPosition ?? 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            Header(showWidgetEditButton: currentPage == 1, isEditingWidgets: $isEditingWidgets)

            HomeScreenScrollContent(
                scrollPosition: $scrollPosition,
                isEditingWidgets: $isEditingWidgets,
                refreshIndicator: pullRefreshIndicator
            )

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

            HomePullRefreshOverlay()
                .environment(pullRefreshIndicator)
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

// MARK: - Pull-to-refresh overlay (isolated observation)

@MainActor
@Observable
private final class HomePullRefreshIndicator {
    var isVisible = false
}

private struct HomePullRefreshOverlay: View {
    @Environment(HomePullRefreshIndicator.self) private var indicator

    var body: some View {
        if indicator.isVisible {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .textPrimary))
                .padding(.top, ScreenLayout.headerHeight + 16)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: indicator.isVisible)
        }
    }
}

// MARK: - Paged scroll (stable subtree; must not read `HomePullRefreshIndicator.isVisible` in `body`)

private struct HomeScreenScrollContent: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var scrollPosition: Int?
    @Binding var isEditingWidgets: Bool
    var refreshIndicator: HomePullRefreshIndicator

    private var hasActivity: Bool {
        return activity.latestActivities?.isEmpty == false
    }

    var body: some View {
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
                if hasActivity, newValue == 1 {
                    app.hasDismissedWidgetsOnboardingHint = true
                }
            }
            .refreshable {
                refreshIndicator.isVisible = true
                defer { refreshIndicator.isVisible = false }

                // guard scrollPosition == 0 else { return }
                // guard wallet.nodeLifecycleState == .running else { return }
                // do {
                //     try await wallet.sync()
                //     try await activity.syncLdkNodePayments()
                // } catch {
                //     app.toast(error)
                // }

                try? await Task.sleep(for: .seconds(5))
            }
        }
        .ignoresSafeArea()
    }
}
