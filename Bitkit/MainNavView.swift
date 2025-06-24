import SwiftUI

struct MainNavView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.scenePhase) var scenePhase

    @State private var isPinVerified: Bool = false

    var body: some View {
        NavigationStack(path: $navigation.path) {
            if settings.requirePinOnLaunch && settings.pinEnabled && !isPinVerified {
                PinOnLaunchView {
                    isPinVerified = true
                }
            } else {
                navigationContent
            }
        }
        .sheet(item: $sheets.addTagSheetItem, onDismiss: { sheets.hideSheet() }) {
            config in AddTagSheet(config: config)
        }
        .sheet(item: $sheets.backupSheetItem, onDismiss: { sheets.hideSheet() }) {
            config in BackupSheet(config: config)
        }
        .sheet(item: $sheets.sendSheetItem, onDismiss: { sheets.hideSheet() }) {
            config in SendSheet(config: config)
        }
        .sheet(item: $sheets.receiveSheetItem, onDismiss: { sheets.hideSheet() }) {
            config in ReceiveSheet(config: config)
        }
        .sheet(item: $sheets.receivedTxSheetItem, onDismiss: { sheets.hideSheet() }) {
            config in NewTransactionSheet(config: config)
        }
        .sheet(item: $sheets.scannerSheetItem, onDismiss: { sheets.hideSheet() }) {
            config in ScannerSheet(config: config)
        }
        .sheet(item: $sheets.securitySheetItem, onDismiss: { sheets.hideSheet() }) {
            config in SetupSecuritySheet(config: config)
        }
        .accentColor(.white)
        .overlay {
            if !settings.requirePinOnLaunch || !settings.pinEnabled || isPinVerified {
                TabBar()
                DrawerView()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            // Reset PIN verification when app goes to background and comes back
            if newPhase == .background && settings.requirePinWhenIdle && settings.pinEnabled {
                isPinVerified = false
            }

            guard wallet.walletExists == true && settings.readClipboard && newPhase == .active else {
                return
            }
            handleClipboard()
        }
        .onAppear {
            // Initialize PIN verification state based on settings
            if !settings.requirePinOnLaunch || !settings.pinEnabled {
                isPinVerified = true
            }
        }
    }

    // MARK: - Computed Properties for Better Organization

    @ViewBuilder
    private var navigationContent: some View {
        Group {
            switch navigation.activeDrawerMenuItem {
            case .wallet:
                HomeView()
            case .activity:
                AllActivityView()
                    .backToWalletButton()
            case .contacts:
                if app.hasSeenContactsIntro {
                    // ContactsView()
                    Text("Coming Soon")
                        .backToWalletButton()
                } else {
                    ContactsIntroView()
                }
            case .profile:
                if app.hasSeenProfileIntro {
                    // ProfileView()
                    Text("Coming Soon")
                        .backToWalletButton()
                } else {
                    ProfileIntroView()
                }
            case .settings:
                SettingsListView()
                    .backToWalletButton()
            case .shop:
                if app.hasSeenShopIntro {
                    ShopDiscover()
                } else {
                    ShopIntro()
                }
            case .widgets:
                if app.hasSeenWidgetsIntro {
                    WidgetsListView()
                } else {
                    WidgetsIntroView()
                }
            case .appStatus:
                AppStatusView()
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
            case .buyBitcoin:
                BuyBitcoinView()
            case .contacts:
                // ContactsView()
                Text("Coming Soon")
                    .backToWalletButton()
            case .contactsIntro:
                ContactsIntroView()
            case .savingsWallet:
                SavingsWalletView()
            case .spendingWallet:
                SpendingWalletView()
            case .transferIntro:
                TransferIntroView()
            case .fundingOptions:
                FundingOptionsView()
            case .fundingAmount:
                FundTransferView()
            case .savingsIntro:
                SavingsIntroView()
            case .savingsAvailability:
                SavingsAvailabilityView()
            case .profile:
                // ProfileView()
                Text("Coming Soon")
                    .backToWalletButton()
            case .profileIntro:
                ProfileIntroView()
            case .quickpay:
                // QuickpayView()
                Text("Coming Soon")
                    .backToWalletButton()
            case .quickpayIntro:
                QuickpayIntroView()
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
            case .shopIntro:
                ShopIntro()
            case .shopDiscover:
                ShopDiscover()
            case .shopMain(let page):
                ShopMain(page: page)
            case .support:
                SupportView()
            }
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
                    sheets.showSheet(.send, data: SendConfig(view: .amount))
                } else if app.invoiceRequiresCustomAmount == false {
                    sheets.showSheet(.send, data: SendConfig(view: .confirm))
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
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel())
        .preferredColorScheme(.dark)
}
