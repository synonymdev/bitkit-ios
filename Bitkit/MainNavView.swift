import SwiftUI

struct MainNavView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.scenePhase) var scenePhase

    // TODO: should be screen height - header height
    private let sheetHeight = UIScreen.screenHeight - 150

    // If scanned directly from home screen
    // TODO: These should be part of the SendSheetView
    @State private var showSendAmountView = false
    @State private var showSendConfirmationView = false

    var body: some View {
        NavigationStack(path: $navigation.path) {
            Group {
                switch navigation.activeDrawerMenuItem {
                case .wallet:
                    HomeView()
                case .activity:
                    AllActivityView()
                        .backToWalletButton()
                case .profile:
                    ProfileView()
                        .backToWalletButton()
                case .settings:
                    SettingsListView()
                        .backToWalletButton()
                case .widgets:
                    if app.hasSeenWidgetsIntro {
                        WidgetsListView()
                    } else {
                        WidgetsIntroView()
                    }
                case .appStatus:
                    AppStatusView()
                        .backToWalletButton()
                default:
                    Text("Coming Soon")
                        .backToWalletButton()
                }
            }
            .navigationDestination(for: Route.self) { screenValue in
                switch screenValue {
                case .activityList:
                    AllActivityView()
                case .activityDetail(let activity):
                    ActivityItemView(item: activity)
                case .activityExplorer(let activity):
                    ActivityExplorerView(item: activity)
                case .savingsWallet:
                    SavingsWalletView()
                case .spendingWallet:
                    SpendingWalletView()
                case .transferIntro:
                    TransferIntroView()
                case .fundingOptions:
                    FundingOptionsView()
                case .savingsIntro:
                    SavingsIntroView()
                case .savingsAvailability:
                    SavingsAvailabilityView()
                case .profile:
                    ProfileView()
                case .widgetsIntro:
                    WidgetsIntroView()
                case .widgetsList:
                    WidgetsListView()
                case .widgetDetail(let widgetType):
                    WidgetDetailView(id: widgetType)
                case .widgetEdit(let widgetType):
                    WidgetEditView(id: widgetType)
                case .settings:
                    SettingsListView()
                }
            }
            .sheet(
                isPresented: $app.showSendOptionsSheet,
                content: {
                    SendOptionsView()
                        .presentationDetents([.height(sheetHeight)])
                }
            )
            .sheet(
                isPresented: $app.showReceiveSheet,
                content: {
                    ReceiveView()
                        .presentationDetents([.height(sheetHeight)])
                }
            )
            .sheet(
                isPresented: $app.showScannerSheet,
                content: {
                    ScannerView(
                        showSendAmountView: $showSendAmountView,
                        showSendConfirmationView: $showSendConfirmationView
                    ).presentationDetents([.height(sheetHeight)])
                }
            )
            .sheet(
                isPresented: $showSendAmountView,
                content: {
                    NavigationStack {
                        SendAmountView()
                            .presentationDetents([.height(sheetHeight)])
                    }
                }
            )
            .sheet(
                isPresented: $showSendConfirmationView,
                content: {
                    NavigationStack {
                        SendConfirmationView()
                            .presentationDetents([.height(sheetHeight)])
                    }
                }
            )
            .onChange(of: app.resetSendStateToggle) { _ in
                // If this is triggered it means we had a successful send and need to drop the sheet
                showSendAmountView = false
                showSendConfirmationView = false
            }
        }
        .accentColor(.white)
        .overlay {
            TabBar()
            DrawerView()
        }
        .onChange(of: scenePhase) { newPhase in
            guard wallet.walletExists == true && settings.readClipboard && newPhase == .active else {
                return
            }

            handleClipboard()
        }

    }

    private func handleClipboard() {
        Task { @MainActor in
            guard let uri = UIPasteboard.general.string else {
                return
            }

            do {
                await wallet.waitForNodeToRun()
                try await app.handleScannedData(uri)

                // If nil then it's not an invoice we're dealing with
                if app.invoiceRequiresCustomAmount == true {
                    showSendAmountView = true
                } else if app.invoiceRequiresCustomAmount == false {
                    showSendConfirmationView = true
                }
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(error)
            }
        }
    }
}

// MARK: - View Modifiers

struct BackToWalletToolbar: ViewModifier {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        navigation.activeDrawerMenuItem = .wallet
                        navigation.reset()
                    }) {
                        Image("x-mark")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                    }
                }
            }
    }
}

extension View {
    func backToWalletButton() -> some View {
        self.modifier(BackToWalletToolbar())
    }
}

#Preview {
    MainNavView()
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .preferredColorScheme(.dark)
}
