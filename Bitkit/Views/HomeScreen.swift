import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var currentTab = 0
    @State private var isEditingWidgets = false

    var body: some View {
        ZStack(alignment: .top) {
            Header(showWidgetEditButton: currentTab == 1, isEditingWidgets: $isEditingWidgets)

            TabView(selection: $currentTab) {
                WalletTabView()
                    .tag(0)

                if settings.showWidgets {
                    WidgetsTabView(isEditingWidgets: $isEditingWidgets)
                        .tag(1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if settings.showWidgets {
                TabViewDots(numberOfTabs: 2, currentTab: currentTab)
                    .offset(y: windowSafeAreaInsets.bottom > 0 ? -74 : -90)
                    .ignoresSafeArea(.keyboard)
            }

            // Top and bottom gradients
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: windowSafeAreaInsets.top + 48 + 16) // safe area + header + spacing

                Spacer()

                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 130)
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
