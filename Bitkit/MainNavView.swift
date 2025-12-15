import SwiftUI
import PaykitMobile

struct MainNavView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var notificationManager: PushNotificationManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(\.scenePhase) var scenePhase

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
                            title: tTodo("Notification Registration Failed"),
                            description: tTodo("Bitkit was unable to register for push notifications.")
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
                                title: tTodo("Notification Registration Failed"),
                                description: tTodo("Bitkit was unable to register for push notifications.")
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

                // Check if this is a Paykit payment request
                if url.scheme == "paykit" || (url.scheme == "bitkit" && url.host == "payment-request") {
                    await handlePaymentRequestDeepLink(url: url, app: app, sheets: sheets)
                    return
                }

                // Handle other deep links (Bitcoin, Lightning, etc.)
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
                if app.hasSeenContactsIntro {
                    // ContactsView()
                    Text("Coming Soon")
                } else {
                    ContactsIntroView()
                }
            case .profile:
                if app.hasSeenProfileIntro {
                    // ProfileView()
                    Text("Coming Soon")
                } else {
                    ProfileIntroView()
                }
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
            case .contacts: Text("Coming Soon")
            case .contactsIntro: ContactsIntroView()
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
            case .profile: Text("Coming Soon")
            case .profileIntro: ProfileIntroView()
            case .scanner: ScannerScreen()

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
            
            // Paykit routes
            case .paykitDashboard: PaykitDashboardView()
            case .paykitContacts: PaykitContactsView()
            case .paykitContactDiscovery: ContactDiscoveryView()
            case .paykitReceipts: PaykitReceiptsView()
            case let .paykitReceiptDetail(receipt): ReceiptDetailView(receipt: receipt)
            case .paykitSubscriptions: PaykitSubscriptionsView()
            case .paykitAutoPay: PaykitAutoPayView()
            case .paykitPaymentRequests: PaykitPaymentRequestsView()
            case .paykitNoisePayment: NoisePaymentView()
            case .paykitPrivateEndpoints: PrivateEndpointsView()
            case .paykitRotationSettings: RotationSettingsView()
            case .node: NodeStateView()
            case .electrumSettings: ElectrumSettingsScreen()
            case .rgsSettings: RgsSettingsScreen()
            case .addressViewer: AddressViewer()

            // Dev settings
            case .blocktankRegtest: BlocktankRegtestView()
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
    
    /// Handle payment request deep links
    /// Format: paykit://payment-request?requestId=xxx&from=yyy
    /// or: bitkit://payment-request?requestId=xxx&from=yyy
    private func handlePaymentRequestDeepLink(url: URL, app: AppViewModel, sheets: SheetViewModel) async {
        guard PaykitIntegrationHelper.isReady else {
            app.toast(
                type: .error,
                title: "Paykit Not Ready",
                description: "Please wait for Paykit to initialize"
            )
            return
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            Logger.error("Invalid payment request URL format", context: "MainNavView")
            app.toast(
                type: .error,
                title: "Invalid Request",
                description: "Payment request URL format is invalid"
            )
            return
        }
        
        let requestId = queryItems.first(where: { $0.name == "requestId" })?.value
        let fromPubkey = queryItems.first(where: { $0.name == "from" })?.value
        
        guard let requestId = requestId, let fromPubkey = fromPubkey else {
            Logger.error("Missing requestId or fromPubkey in payment request URL", context: "MainNavView")
            app.toast(
                type: .error,
                title: "Invalid Request",
                description: "Payment request URL is missing required parameters"
            )
            return
        }
        
        // Get PaykitManager client
        guard let paykitClient = PaykitManager.shared.client else {
            app.toast(
                type: .error,
                title: "Paykit Not Initialized",
                description: "Please restart the app"
            )
            return
        }
        
        // Create PaymentRequestService
        let autoPayViewModel = AutoPayViewModel()
        let paymentRequestService = PaymentRequestService(
            paykitClient: paykitClient,
            autopayEvaluator: autoPayViewModel
        )
        
        // Handle the payment request
        paymentRequestService.handleIncomingRequest(
            requestId: requestId,
            fromPubkey: fromPubkey
        ) { result in
            Task { @MainActor in
                switch result {
                case .success(let processingResult):
                    switch processingResult {
                    case .autoPaid(let paymentResult):
                        app.toast(
                            type: .success,
                            title: "Payment Completed",
                            description: "Payment was automatically approved and executed"
                        )
                        // Navigate to receipt if available
                        if let receiptId = paymentResult.receiptId {
                            let receipt = PaymentReceipt(
                                id: receiptId,
                                direction: .received,
                                counterpartyKey: fromPubkey,
                                counterpartyName: nil,
                                amountSats: paymentResult.amountSats,
                                status: .completed,
                                paymentMethod: paymentResult.methodId,
                                createdAt: Date(),
                                completedAt: Date(timeIntervalSince1970: TimeInterval(paymentResult.executedAt / 1000)),
                                memo: nil,
                                txId: paymentResult.executionDataJson,
                                proof: nil,
                                proofVerified: false,
                                proofVerifiedAt: nil
                            )
                            navigation.path.append(Route.paykitReceiptDetail(receipt))
                        }
                        
                    case .needsApproval(let request):
                        // Show manual approval UI
                        app.toast(
                            type: .info,
                            title: "Payment Request",
                            description: "Review the payment request"
                        )
                        // Navigate to payment requests view
                        navigation.path.append(Route.paykitPaymentRequests)
                        
                    case .denied(let reason):
                        app.toast(
                            type: .warning,
                            title: "Payment Denied",
                            description: reason
                        )
                        
                    case .error(let error):
                        Logger.error("Payment request processing error", error: error, context: "MainNavView")
                        app.toast(
                            type: .error,
                            title: "Payment Error",
                            description: error.localizedDescription
                        )
                    }
                    
                case .failure(let error):
                    Logger.error("Failed to process payment request", error: error, context: "MainNavView")
                    app.toast(
                        type: .error,
                        title: "Request Failed",
                        description: error.localizedDescription
                    )
                }
            }
        }
    }
}
