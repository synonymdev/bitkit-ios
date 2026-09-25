import SwiftUI
import UIKit

struct HomeScreen: View {
    @Environment(CalculatorInputManager.self) private var calculatorInput
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var scrollPosition: Int? = 0
    @State private var isEditingWidgets = false
    @State private var pullRefreshState = HomePullRefreshState()

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
                        HomePullRefreshWallet(state: pullRefreshState)
                            .frame(height: geometry.size.height, alignment: .top)
                            .id(0)

                        if settings.showWidgets {
                            HomeWidgetsView(isEditingWidgets: $isEditingWidgets)
                                .frame(height: geometry.size.height)
                                .id(1)
                        }
                    }
                    .scrollTargetLayout()
                    .overlay(alignment: .top) {
                        HomePullRefreshObserver {
                            Task { await refresh() }
                        }
                        .frame(width: 0, height: 0)
                    }
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollPosition)
                .accessibilityIdentifier("HomeScrollView")
                .accessibilityElement(children: .contain)
                .onChange(of: scrollPosition) { _, newValue in
                    if newValue != 1 {
                        calculatorInput.dismiss()
                    }

                    // Dismiss this hint after the user has seen it and scrolls to widgets
                    if hasActivity, newValue == 1 {
                        app.hasDismissedWidgetsOnboardingHint = true
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
                .opacity(calculatorInput.isPresented ? 0 : 1)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.14), value: calculatorInput.isPresented)
        }
        .overlay(alignment: .top) {
            HomePullRefreshOverlay(state: pullRefreshState)
                .frame(width: 20, height: 20)
                .padding(.top, ScreenLayout.headerHeight + 16)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationBarHidden(true)
        .onAppear {
            TimedSheetManager.shared.onPrimaryScreenEntered()
            consumeRequestedHomePage()
        }
        .onDisappear {
            TimedSheetManager.shared.onPrimaryScreenExited()
        }
        .onChange(of: app.requestedHomePage) { _, _ in
            consumeRequestedHomePage()
        }
    }

    private func refresh() async {
        guard currentPage == 0 else { return }
        guard pullRefreshState.beginRefreshing() else { return }
        defer { pullRefreshState.endRefreshing() }

        async let currencyRefresh: Void = currency.refresh()

        if wallet.nodeLifecycleState == .running {
            do {
                try await wallet.sync()
                try await activity.syncLdkNodePayments()
            } catch {
                app.toast(error)
            }
        }

        await currencyRefresh
    }

    private func consumeRequestedHomePage() {
        guard let requested = app.requestedHomePage else { return }
        withAnimation { scrollPosition = requested }
        app.requestedHomePage = nil
    }
}

// MARK: - Pull-to-refresh

@MainActor
@Observable
private final class HomePullRefreshState {
    private(set) var isRefreshing = false

    @ObservationIgnored
    private weak var spinner: UIActivityIndicatorView?

    func attach(_ spinner: UIActivityIndicatorView) {
        self.spinner = spinner
        spinner.alpha = isRefreshing ? 1 : 0
        if isRefreshing {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    func beginRefreshing() -> Bool {
        guard !isRefreshing else { return false }
        withAnimation(.easeOut(duration: 0.2)) {
            isRefreshing = true
        }
        spinner?.startAnimating()
        UIView.animate(withDuration: 0.2) { [weak spinner] in
            spinner?.alpha = 1
        }
        return true
    }

    func endRefreshing() {
        withAnimation(.easeOut(duration: 0.2)) {
            isRefreshing = false
        }
        UIView.animate(withDuration: 0.2) { [weak spinner] in
            spinner?.alpha = 0
        } completion: { [weak self, weak spinner] _ in
            guard self?.isRefreshing == false else { return }
            spinner?.stopAnimating()
        }
    }
}

private struct HomePullRefreshWallet: View {
    private static let refreshSpacing: CGFloat = 60

    var state: HomePullRefreshState

    var body: some View {
        HomeWalletView()
            .padding(.top, state.isRefreshing ? Self.refreshSpacing : 0)
    }
}

private struct HomePullRefreshOverlay: UIViewRepresentable {
    var state: HomePullRefreshState

    func makeUIView(context _: Context) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = UIColor(Color.textPrimary)
        spinner.isAccessibilityElement = false
        state.attach(spinner)
        return spinner
    }

    func updateUIView(_ uiView: UIActivityIndicatorView, context _: Context) {
        state.attach(uiView)
    }
}

private struct HomePullRefreshObserver: UIViewRepresentable {
    var onRefresh: () -> Void

    func makeUIView(context _: Context) -> HomePullRefreshObserverView {
        let view = HomePullRefreshObserverView()
        view.onRefresh = onRefresh
        return view
    }

    func updateUIView(_ uiView: HomePullRefreshObserverView, context _: Context) {
        uiView.onRefresh = onRefresh
        uiView.attachToScrollViewIfNeeded()
    }
}

private final class HomePullRefreshObserverView: UIView {
    /** Pull distance required to start refreshing the home wallet. */
    private static let threshold: CGFloat = 80

    var onRefresh: (() -> Void)?
    private weak var observedScrollView: UIScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detachFromScrollView()
        } else {
            attachToScrollViewIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachToScrollViewIfNeeded()
    }

    func attachToScrollViewIfNeeded() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                guard scrollView !== observedScrollView else { return }
                detachFromScrollView()
                observedScrollView = scrollView
                scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePanGesture))
                return
            }
            ancestor = view.superview
        }
    }

    private func detachFromScrollView() {
        observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePanGesture))
        observedScrollView = nil
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, let scrollView = observedScrollView else { return }
        let pullDistance = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        guard pullDistance >= Self.threshold else { return }
        onRefresh?()
    }
}
