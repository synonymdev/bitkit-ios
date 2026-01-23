import SwiftUI

struct MainNavView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var notificationManager: PushNotificationManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(\.scenePhase) var scenePhase

    @StateObject private var sweepViewModel = SweepViewModel()

    @State private var showClipboardAlert = false
    @State private var clipboardUri: String?

    // Delay constants for clipboard processing
    private static let nodeReadyDelayNanoseconds: UInt64 = 500_000_000 // 0.5 seconds
    private static let statePropagationDelayNanoseconds: UInt64 = 500_000_000 // 0.5 seconds

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
            item: $sheets.giftSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in GiftSheet(config: config)
        }
        .sheet(
            item: $sheets.connectionClosedSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ConnectionClosedSheet(config: config)
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
                sheets.hideSheetIfActive(.lnurlWithdraw, reason: "LNURL withdraw sheet dismissed")
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
                sheets.hideSheetIfActive(.scanner, reason: "Scanner sheet dismissed")
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
                sheets.hideSheetIfActive(.send, reason: "Send sheet dismissed")
            }
        ) {
            config in SendSheet(config: config)
        }
        .sheet(
            item: $sheets.forceTransferSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ForceTransferSheet(config: config)
        }
        .sheet(
            item: $sheets.sweepPromptSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in SweepPromptSheet(config: config)
        }
        .accentColor(.white)
        .overlay {
            TabBar()
            DrawerView()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // Update notification permission in case user changed it in OS settings
                notificationManager.updateNotificationPermission()

                guard settings.readClipboard else { return }

                handleClipboard()
            }
        }
        .onChange(of: notificationManager.authorizationStatus) { newStatus in
            // Handle notification permission changes
            if newStatus == .authorized {
                settings.enableNotifications = true
                notificationManager.requestPermission()
            } else {
                settings.enableNotifications = false
                notificationManager.unregister()
            }
        }
        .onChange(of: notificationManager.deviceToken) { token in
            // Register with backend if device token changed and notifications are enabled
            if let token, settings.enableNotifications {
                Task {
                    do {
                        try await notificationManager.registerWithBackend(deviceToken: token)
                    } catch {
                        Logger.error("Failed to sync push notifications with backend: \(error)")
                        app.toast(
                            type: .error,
                            title: t("other__notification_registration_failed_title"),
                            description: t("other__notification_registration_failed_description")
                        )
                    }
                }
            }
        }
        .onChange(of: settings.enableNotifications) { newValue in
            // Handle notification enable/disable
            if newValue {
                // Request permission in case user was not prompted yet
                notificationManager.requestPermission()

                if let token = notificationManager.deviceToken {
                    Task {
                        do {
                            try await notificationManager.registerWithBackend(deviceToken: token)
                        } catch {
                            Logger.error("Failed to sync push notifications: \(error)")
                            app.toast(
                                type: .error,
                                title: t("other__notification_registration_failed_title"),
                                description: t("other__notification_registration_failed_description")
                            )
                        }
                    }
                }
            } else {
                // Disable notifications (unregister)
                notificationManager.unregister()
            }
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
                        title: t("other__qr_error_header"),
                        description: t("other__qr_error_text")
                    )
                }
            }
        }
        .alert(
            t("other__clipboard_redirect_title"),
            isPresented: $showClipboardAlert
        ) {
            Button(t("common__ok")) {
                processClipboardUri()
            }
            Button(t("common__dialog_cancel"), role: .cancel) {
                clipboardUri = nil
            }
        } message: {
            Text(t("other__clipboard_redirect_msg"))
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
            case .contacts:
                // if app.hasSeenContactsIntro {
                //     ContactsView()
                // } else {
                //     ContactsIntroView()
                // }
                ComingSoonScreen()
            case .profile:
                // if app.hasSeenProfileIntro {
                //     ProfileView()
                // } else {
                //     ProfileIntroView()
                // }
                ComingSoonScreen()
            case .settings:
                MainSettings()
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
            }
        }
        .navigationDestination(for: Route.self) { screenValue in
            switch screenValue {
            case .activityList: AllActivityView()
            case let .activityDetail(activity): ActivityItemView(item: activity)
            case let .activityExplorer(activity): ActivityExplorerView(item: activity)
            case .buyBitcoin: BuyBitcoinView()
            case .savingsWallet: SavingsWalletView()
            case .spendingWallet: SpendingWalletView()
            case .transferIntro: TransferIntroView()
            case .fundingOptions: FundingOptions()
            case .spendingIntro: SpendingIntroView()
            case .spendingAmount: SpendingAmount()
            case let .spendingConfirm(order): SpendingConfirm(order: order)
            case let .spendingAdvanced(order): SpendingAdvancedView(order: order)
            case let .transferLearnMore(order): TransferLearnMoreView(order: order)
            case .settingUp: SettingUpView()
            case .fundingAdvanced: FundAdvancedOptions()
            case let .fundManual(nodeUri): FundManualSetupView(initialNodeUri: nodeUri)
            case .fundManualSuccess: FundManualSuccessView()
            case let .lnurlChannel(channelData): LnurlChannel(channelData: channelData)
            case .savingsIntro: SavingsIntroView()
            case .savingsAvailability: SavingsAvailabilityView()
            case .savingsConfirm: SavingsConfirmView()
            case .savingsAdvanced: SavingsAdvancedView()
            case .savingsProgress: SavingsProgressView()
            case .scanner: ScannerScreen()

            // Profile & Contacts
            case .contacts: ComingSoonScreen()
            case .contactsIntro: ComingSoonScreen()
            case .profile: ComingSoonScreen()
            case .profileIntro: ComingSoonScreen()

            // Shop
            case .shopIntro: ShopIntro()
            case .shopDiscover: ShopDiscover()
            case let .shopMain(page): ShopMain(page: page)
            case .shopMap: ShopMap()

            // Widgets
            case .widgetsIntro: WidgetsIntroView()
            case .widgetsList: WidgetsListView()
            case let .widgetDetail(widgetType): WidgetDetailView(id: widgetType)
            case let .widgetEdit(widgetType): WidgetEditView(id: widgetType)

            // Settings
            case .settings: MainSettings()
            case .generalSettings: GeneralSettingsView()
            case .securitySettings: SecurityPrivacySettingsView()
            case .backupSettings: BackupSettings()
            case .advancedSettings: AdvancedSettingsView()
            case .support: SupportView()
            case .about: AboutView()
            case .devSettings: DevSettingsView()

            // General settings
            case .languageSettings: LanguageSettingsScreen()
            case .currencySettings: LocalCurrencySettingsView()
            case .unitSettings: DefaultUnitSettingsView()
            case .transactionSpeedSettings: TransactionSpeedSettingsView()
            case .quickpay: QuickpaySettings()
            case .quickpayIntro: QuickpayIntroView()
            case .customSpeedSettings: CustomSpeedView()
            case .tagSettings: TagSettingsView()
            case .widgetsSettings: WidgetsSettingsView()
            case .notifications: NotificationsSettings()
            case .notificationsIntro: NotificationsIntro()

            // Security settings
            case .disablePin: DisablePinView()
            case .changePin: PinChangeView()

            // Backup settings
            case .resetAndRestore: ResetAndRestore()

            // Support settings
            case .reportIssue: ReportIssue()
            case .appStatus: AppStatusView()

            // Advanced settings
            case .coinSelection: CoinSelectionSettingsView()
            case .connections: LightningConnectionsView()
            case let .connectionDetail(channelId): LightningConnectionDetailView(channelId: channelId)
            case let .closeConnection(channel: channel): CloseConnectionConfirmation(channel: channel)
            case .node: NodeStateView()
            case .electrumSettings: ElectrumSettingsScreen()
            case .rgsSettings: RgsSettingsScreen()
            case .addressViewer: AddressViewer()
            case .sweep: SweepSettingsView().environmentObject(sweepViewModel)
            case .sweepConfirm: SweepConfirmView().environmentObject(sweepViewModel)
            case .sweepFeeRate: SweepFeeRateView().environmentObject(sweepViewModel)
            case .sweepFeeCustom: SweepFeeCustomView().environmentObject(sweepViewModel)
            case let .sweepSuccess(txid): SweepSuccessView(txid: txid).environmentObject(sweepViewModel)

            // Dev settings
            case .blocktankRegtest: BlocktankRegtestView()
            case .ldkDebug: LdkDebugScreen()
            case .orders: ChannelOrders()
            case .logs: LogView()
            }
        }
    }

    private func handleClipboard() {
        Task { @MainActor in
            guard let uri = UIPasteboard.general.string else {
                return
            }

            // Store the URI and show alert
            clipboardUri = uri
            showClipboardAlert = true
        }
    }

    private func processClipboardUri() {
        guard let uri = clipboardUri else { return }

        Task { @MainActor in
            do {
                await wallet.waitForNodeToRun()
                try await Task.sleep(nanoseconds: Self.nodeReadyDelayNanoseconds)
                try await app.handleScannedData(uri)

                try await Task.sleep(nanoseconds: Self.statePropagationDelayNanoseconds)
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
                    title: t("other__qr_error_header"),
                    description: t("other__qr_error_text")
                )
            }

            // Clear stored URI after processing
            clipboardUri = nil
        }
    }
}
