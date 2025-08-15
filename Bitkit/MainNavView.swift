import SwiftUI

struct MainNavView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        NavigationStack(path: $navigation.path) {
            navigationContent
        }
        .sheet(
            item: $sheets.addTagSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in AddTagSheet(config: config)
        }
        .sheet(
            item: $sheets.boostSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in BoostSheet(config: config)
        }
        .sheet(
            item: $sheets.appUpdateSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.ignoreAppUpdate()
            }
        ) {
            config in AppUpdateSheet(config: config)
        }
        .sheet(
            item: $sheets.backupSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.ignoreBackup()
            }
        ) {
            config in BackupSheet(config: config)
        }
        .sheet(
            item: $sheets.highBalanceSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.ignoreHighBalance()
            }
        ) {
            config in HighBalanceSheet(config: config)
        }
        .sheet(
            item: $sheets.lnurlAuthSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in LnurlAuthSheet(config: config)
        }
        .sheet(
            item: $sheets.lnurlWithdrawSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in LnurlWithdrawSheet(config: config)
        }
        .sheet(
            item: $sheets.notificationsSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.hasSeenNotificationsIntro = true
            }
        ) {
            config in NotificationsSheet(config: config)
        }
        .sheet(
            item: $sheets.receiveSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ReceiveSheet(config: config)
        }
        .sheet(
            item: $sheets.receivedTxSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ReceivedTx(config: config)
        }
        .sheet(
            item: $sheets.scannerSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ScannerSheet(config: config)
        }
        .sheet(
            item: $sheets.securitySheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in SecuritySheet(config: config)
        }
        .sheet(
            item: $sheets.quickpaySheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.hasSeenQuickpayIntro = true
            }
        ) {
            config in QuickpaySheet(config: config)
        }
        .sheet(
            item: $sheets.sendSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.resetSendState()
            }
        ) {
            config in SendSheet(config: config)
        }
        .accentColor(.white)
        .overlay {
            TabBar()
            DrawerView()
        }
        .onChange(of: scenePhase) { newPhase in
            guard settings.readClipboard && newPhase == .active else {
                return
            }
            handleClipboard()
        }
        .onOpenURL { url in
            Task {
                Logger.info("Received deeplink: \(url.absoluteString)")

                do {
                    try await app.handleScannedData(url.absoluteString)
                    PaymentNavigationHelper.openPaymentSheet(
                        app: app,
                        currency: currency,
                        settings: settings,
                        sheetViewModel: sheets
                    )
                } catch {
                    Logger.error(error, context: "Failed to handle deeplink")
                    app.toast(
                        type: .error,
                        title: localizedString("other__qr_error_header"),
                        description: localizedString("other__qr_error_text")
                    )
                }
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
                MainSettings()
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
                FundingOptions()
            case .spendingIntro:
                SpendingIntroView()
            case .spendingAmount:
                SpendingAmount()
            case .spendingConfirm:
                SpendingConfirm()
            case .spendingAdvanced(let order):
                SpendingAdvancedView(order: order)
            case .transferLearnMore(let order):
                TransferLearnMoreView(order: order)
            case .settingUp:
                SettingUpView()
            case .fundingAdvanced:
                FundAdvancedOptions()
            case .fundManual(let nodeUri):
                FundManualSetupView(initialNodeUri: nodeUri)
            case .fundManualSuccess:
                FundManualSuccessView()
            case .lnurlChannel(let channelData):
                LnurlChannel(channelData: channelData)
            case .savingsIntro:
                SavingsIntroView()
            case .savingsAvailability:
                SavingsAvailabilityView()
            case .savingsConfirm:
                SavingsConfirmView()
            case .savingsAdvanced:
                SavingsAdvancedView()
            case .savingsProgress:
                SavingsProgressView()
            case .profile:
                // ProfileView()
                Text("Coming Soon")
                    .backToWalletButton()
            case .profileIntro:
                ProfileIntroView()

            // Shop
            case .shopIntro:
                ShopIntro()
            case .shopDiscover:
                ShopDiscover()
            case .shopMain(let page):
                ShopMain(page: page)

            // Widgets
            case .widgetsIntro:
                WidgetsIntroView()
            case .widgetsList:
                WidgetsListView()
            case .widgetDetail(let widgetType):
                WidgetDetailView(id: widgetType)
            case .widgetEdit(let widgetType):
                WidgetEditView(id: widgetType)

            // Settings
            case .settings:
                MainSettings()
            case .generalSettings:
                GeneralSettingsView()
            case .securitySettings:
                SecurityPrivacySettingsView()
            case .backupSettings:
                BackupSettings()
            case .advancedSettings:
                AdvancedSettingsView()
            case .support:
                SupportView()
            case .about:
                AboutView()
            case .devSettings:
                DevSettingsView()

            // General settings
            case .languageSettings:
                LanguageSettingsScreen()
            case .currencySettings:
                LocalCurrencySettingsView()
            case .unitSettings:
                DefaultUnitSettingsView()
            case .transactionSpeedSettings:
                TransactionSpeedSettingsView()
            case .quickpay:
                QuickpaySettings()
            case .quickpayIntro:
                QuickpayIntroView()
            case .customSpeedSettings:
                CustomSpeedView()
            case .tagSettings:
                TagSettingsView()
            case .widgetsSettings:
                WidgetsSettingsView()
            case .notifications:
                NotificationsSettings()
            case .notificationsIntro:
                NotificationsIntro()

            // Security settings
            case .disablePin:
                DisablePinView()
            case .changePin:
                PinChangeView()

            // Backup settings
            case .resetAndRestore:
                ResetAndRestore()

            // Support settings
            case .reportIssue:
                ReportIssue()
            case .appStatus:
                AppStatusView()

            // Advanced settings
            case .coinSelection:
                CoinSelectionSettingsView()
            case .connections:
                LightningConnectionsView()
            case .node:
                NodeStateView()
            case .electrumSettings:
                Text("Coming Soon")
                    .backToWalletButton()
            case .addressViewer:
                AddressViewer()

            // Dev settings
            case .blocktankRegtest:
                BlocktankRegtestView()
            case .logs:
                LogView()
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

                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(
                    type: .error,
                    title: localizedString("other__qr_error_header"),
                    description: localizedString("other__qr_error_text")
                )
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
