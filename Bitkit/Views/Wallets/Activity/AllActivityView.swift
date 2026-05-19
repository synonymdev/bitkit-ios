import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        ZStack(alignment: .top) {
            InsetHeaderScrollView(
                header: {
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
                },
                content: {
                    ActivityList(viewType: .all)
                        .padding(.horizontal, 16)
                        .swipeSegmentedTabs(selection: $activity.selectedTab)
                },
                scrollModifier: ActivityScrollModifier(
                    activity: activity,
                    app: app,
                    wallet: wallet
                )
            )
            .transition(.move(edge: .leading).combined(with: .opacity))

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

private struct ActivityScrollModifier: ViewModifier {
    let activity: ActivityListViewModel
    let app: AppViewModel
    let wallet: WalletViewModel

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, 16)
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
    }
}

#Preview {
    NavigationStack {
        AllActivityView()
            .environmentObject(ActivityListViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(WalletViewModel())
            .preferredColorScheme(.dark)
    }
}
