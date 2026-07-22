import SwiftUI

struct MainNavView: View {
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    @EnvironmentObject private var app: AppViewModel
    @Environment(CameraManager.self) private var cameraManager
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var notificationManager: PushNotificationManager
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var transfer: TransferViewModel
    @Environment(TrezorManager.self) private var trezorManager
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(\.scenePhase) var scenePhase

    @State private var showClipboardAlert = false
    @State private var clipboardUri: String?

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    // Delay constants for clipboard processing
    private static let nodeReadyDelayNanoseconds: UInt64 = 500_000_000 // 0.5 seconds
    private static let statePropagationDelayNanoseconds: UInt64 = 500_000_000 // 0.5 seconds

    var body: some View {
        NavigationStack(path: $navigation.path) {
            navigationContent
        }
        .onChange(of: transfer.hwFundingComplete) { _, complete in
            if complete {
                transfer.consumeHwFundingComplete()
                navigation.navigate(.spendingHwSigned)
            }
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
            item: $sheets.pubkyAuthApprovalSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in PubkyAuthApprovalSheet(config: config)
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
            item: $sheets.btcpayConnectionSheetItem,
            onDismiss: {
                sheets.hideSheetIfActive(.btcpayConnection, reason: "BTCPay connection sheet dismissed")
            }
        ) {
            config in BTCPayConnectionSheet(config: config)
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
            item: $sheets.widgetsSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in WidgetsSheet(config: config)
        }
        .sheet(
            item: $sheets.hardwareConnectSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in HardwareConnectSheet(config: config)
        }
        .sheet(
            item: $sheets.hardwarePairingSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in HardwarePairingSheet(config: config)
        }
        .sheet(
            item: $sheets.renameHardwareWalletSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in RenameHardwareWalletSheet(config: config)
        }
        .onChange(of: trezorManager.showPairingCode) { _, needsCode in
            // A hardware device asked for its one-time pairing code (e.g. during reconnect);
            // surface the app-wide Pair Device sheet. Hidden again once submitted/cancelled.
            if needsCode {
                guard !sheets.hardwareConnectHandlesPairing else { return }
                sheets.showSheet(.hardwarePairing)
            } else {
                sheets.hideSheetIfActive(.hardwarePairing, reason: "Pairing code resolved")
            }
        }
        .onReceive(hwWalletManager.receivedTxPublisher) { tx in
            // New inbound transaction to a watched hardware wallet — show the received celebration.
            sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, sats: tx.sats))
        }
        .accentColor(.white)
        .overlay {
            TabBar()
                .ignoresSafeArea(.keyboard)
            DrawerView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Update permissions in case user changed them in OS settings
                notificationManager.updateNotificationPermission()
                cameraManager.refreshPermission()

                guard settings.readClipboard else { return }

                handleClipboard()
            }
        }
        .onChange(of: notificationManager.authorizationStatus) { _, newStatus in
            // Handle notification permission changes
            if newStatus == .authorized {
                settings.enableNotifications = true
                notificationManager.requestPermission()
            } else {
                settings.enableNotifications = false
                notificationManager.unregister()
            }
        }
        .onChange(of: notificationManager.deviceToken) { _, token in
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
        .onChange(of: settings.enableNotifications) { _, newValue in
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
                Logger.info("Received deeplink: \(sanitizedDeeplinkDescription(url))")

                // Web URLs from widgets (e.g. news article tap) bypass payment handling
                if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    await UIApplication.shared.open(url)
                    return
                }

                if let callback = PubkyRingAuthCallback.parse(url: url) {
                    guard isPaykitUIActive else {
                        app.toast(
                            type: .error,
                            title: t("profile__auth_error_title"),
                            description: t("other__qr_error_text")
                        )
                        return
                    }

                    let handlingResult = await pubkyProfile.handleAuthCallback(callback)

                    switch handlingResult {
                    case let .trustedError(message):
                        app.toast(
                            type: .error,
                            title: t("profile__auth_error_title"),
                            description: message ?? t("other__qr_error_text")
                        )
                    case .untrustedError:
                        app.toast(
                            type: .error,
                            title: t("profile__auth_error_title")
                        )
                    case .handled, .ignored:
                        break
                    }

                    return
                }

                do {
                    try await app.handleScannedData(url.absoluteString)
                    if shouldOpenPaymentSheet(for: url.absoluteString) {
                        PaymentNavigationHelper.openPaymentSheet(
                            app: app,
                            currency: currency,
                            settings: settings,
                            sheetViewModel: sheets
                        )
                    }
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

    // MARK: - Loading View

    private var pubkyLoadingView: some View {
        VStack {
            Spacer()
            ActivityIndicator()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pubkyInitializationErrorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            BodyMText(t("other__try_again"))

            BodySText(message, textColor: .white64)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            CustomButton(title: t("common__retry"), variant: .secondary) {
                await pubkyProfile.initialize()
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var navigationContent: some View {
        HomeScreen()
            .navigationDestination(for: Route.self) { screenValue in
                switch screenValue {
                case .activityList: AllActivityView()
                case let .activityDetail(activity): ActivityItemView(item: activity)
                case let .activityExplorer(activity): ActivityExplorerView(item: activity)
                case .buyBitcoin: BuyBitcoinView()
                case .savingsWallet: SavingsWalletScreen()
                case .spendingWallet: SpendingWalletScreen()
                case let .hardwareWallet(deviceId): HardwareWalletScreen(deviceId: deviceId)
                case .scanner: ScannerScreen()

                // Transfer
                case .transferIntro: TransferIntroView()
                case .fundingOptions: FundingOptions()
                case .spendingIntro: SpendingIntroView()
                case let .spendingIntroHw(deviceId): SpendingIntroView(deviceId: deviceId)
                case .spendingAmount: SpendingAmount()
                case let .spendingAmountHw(deviceId): SpendingAmountHw(deviceId: deviceId)
                case let .spendingHwSign(deviceId): SpendingHwSign(deviceId: deviceId)
                case .spendingHwSigned: SpendingHwSigned()
                case let .spendingConfirm(order): SpendingConfirm(order: order)
                case let .spendingAdvanced(order): SpendingAdvancedView(order: order)
                case let .transferLearnMore(order): TransferLearnMoreView(order: order)
                case .settingUp: SettingUpView()
                case .fundingAdvanced: FundAdvancedOptions()
                case let .fundManual(nodeUri): FundManualSetupView(initialNodeUri: nodeUri)
                case let .fundManualAmount(lnPeer): FundManualAmountView(lnPeer: lnPeer)
                case let .fundManualConfirm(lnPeer, amountSats): FundManualConfirmView(lnPeer: lnPeer, amountSats: amountSats)
                case .fundManualSuccess: FundManualSuccessView()
                case let .lnurlChannel(channelData): LnurlChannel(channelData: channelData)
                case .savingsIntro: SavingsIntroView()
                case .savingsAvailability: SavingsAvailabilityView()
                case .savingsConfirm: SavingsConfirmView()
                case .savingsAdvanced: SavingsAdvancedView()
                case .savingsProgress: SavingsProgressView()

                // Profile & Contacts
                case .contacts:
                    if !isPaykitUIActive {
                        ComingSoonScreen()
                    } else if let initializationErrorMessage = pubkyProfile.initializationErrorMessage {
                        pubkyInitializationErrorView(message: initializationErrorMessage)
                    } else if app.hasSeenContactsIntro || !contactsManager.contacts.isEmpty {
                        if !pubkyProfile.isInitialized {
                            pubkyLoadingView
                        } else if pubkyProfile.isAuthenticated {
                            ContactsListView()
                        } else if app.hasSeenProfileIntro {
                            PubkyChoiceView()
                        } else {
                            ProfileIntroView()
                        }
                    } else {
                        ContactsIntroView()
                    }
                case .contactsIntro:
                    if isPaykitUIActive { ContactsIntroView() } else { ComingSoonScreen() }
                case let .contactDetail(publicKey):
                    if isPaykitUIActive { ContactDetailView(publicKey: publicKey) } else { paykitDisabledRedirectView }
                case let .contactActivity(publicKey):
                    if isPaykitUIActive { ContactActivityView(publicKey: publicKey) } else { paykitDisabledRedirectView }
                case let .assignActivityContact(activityId):
                    if isPaykitUIActive { AssignActivityContactView(activityId: activityId) } else { paykitDisabledRedirectView }
                case .contactImportOverview:
                    if !isPaykitUIActive {
                        paykitDisabledRedirectView
                    } else if let fallbackRoute = fallbackRouteForMissingPendingImport(hasPendingImport: contactsManager.hasPendingImport) {
                        missingPendingImportView(fallbackRoute: fallbackRoute)
                    } else if let profile = contactsManager.pendingImportProfile {
                        ContactImportOverviewView(
                            profile: profile,
                            contacts: contactsManager.pendingImportContacts
                        )
                    } else {
                        missingPendingImportView(fallbackRoute: .payContacts)
                    }
                case .contactImportSelect:
                    if !isPaykitUIActive {
                        paykitDisabledRedirectView
                    } else if let fallbackRoute = fallbackRouteForMissingPendingImport(hasPendingImport: contactsManager.hasPendingImport) {
                        missingPendingImportView(fallbackRoute: fallbackRoute)
                    } else {
                        ContactImportSelectView(contacts: contactsManager.pendingImportContacts)
                    }
                case let .addContact(publicKey):
                    if isPaykitUIActive { AddContactView(publicKey: publicKey) } else { paykitDisabledRedirectView }
                case let .editContact(publicKey):
                    if isPaykitUIActive { EditContactView(publicKey: publicKey) } else { paykitDisabledRedirectView }
                case .profile:
                    if !isPaykitUIActive {
                        ComingSoonScreen()
                    } else if let initializationErrorMessage = pubkyProfile.initializationErrorMessage {
                        pubkyInitializationErrorView(message: initializationErrorMessage)
                    } else if !pubkyProfile.isInitialized {
                        pubkyLoadingView
                    } else if pubkyProfile.isAuthenticated {
                        ProfileView()
                    } else if app.hasSeenProfileIntro {
                        PubkyChoiceView()
                    } else {
                        ProfileIntroView()
                    }
                case .profileIntro:
                    if isPaykitUIActive { ProfileIntroView() } else { ComingSoonScreen() }
                case .pubkyChoice:
                    if isPaykitUIActive { PubkyChoiceView() } else { paykitDisabledRedirectView }
                case .createProfile:
                    if isPaykitUIActive { CreateProfileView() } else { paykitDisabledRedirectView }
                case .editProfile:
                    if isPaykitUIActive { EditProfileView() } else { paykitDisabledRedirectView }
                case .payContacts:
                    if isPaykitUIActive { PayContactsView() } else { paykitDisabledRedirectView }

                // Shop
                case .shopIntro: ShopIntro()
                case .shopDiscover: ShopDiscover()
                case let .shopMain(page): ShopMain(page: page)

                // Widgets
                case .widgetsIntro: WidgetsIntroView()

                // Settings
                case .settings: MainSettingsScreen()
                case .support: SupportScreen()

                // General settings
                case .languageSettings: LanguageSettingsScreen()
                case .currencySettings: LocalCurrencySettingsView()
                case .unitSettings: DefaultUnitSettingsView()
                case .transactionSpeedSettings: TransactionSpeedSettingsView()
                case .quickpay: QuickpaySettings()
                case .quickpayIntro: QuickpayIntroView()
                case .customSpeedSettings: CustomSpeedView()
                case .tagSettings: TagSettingsView()
                case .widgetsSettings: WidgetsSettingsScreen()
                case .notifications: NotificationsSettings()
                case .notificationsIntro: NotificationsIntro()
                case .paymentPreference:
                    if isPaykitUIActive { PaymentPreferenceView() } else { paykitDisabledRedirectView }
                case .hardwareWalletsSettings: HardwareWalletsSettingsScreen()

                // Security settings
                case .changePin: ChangePinScreen()

                // Backup settings
                case .dataBackups: DataBackupsScreen()
                case .reset: ResetScreen()

                // Support settings
                case .reportIssue: ReportIssue()
                case .appStatus: AppStatusView()

                // Advanced settings
                case .coinSelection: CoinSelectionSettingsView()
                case .addressTypePreference: AddressTypePreferenceView()
                case .connections: LightningConnectionsView()
                case let .connectionDetail(channelId): LightningConnectionDetailView(channelId: channelId)
                case let .closeConnection(channel: channel): CloseConnectionConfirmation(channel: channel)
                case .node: NodeStateView()
                case .electrumSettings: ElectrumSettingsScreen()
                case .rgsSettings: RgsSettingsScreen()
                case .addressViewer: AddressViewer()
                case .devSettings: DevSettingsView()

                // Dev settings
                case .blocktankRegtest: BlocktankRegtestScreen()
                case .ldkDebug: LdkDebugScreen()
                case .vssDebug: VssDebugScreen()
                case .probingTool: ProbingToolScreen()
                case .legacyRnRecovery: LegacyRnRecoveryScreen()
                case .orders: ChannelOrders()
                case .logs: LogView()
                case .trezor: TrezorRootView()
                }
            }
    }

    private func missingPendingImportView(fallbackRoute: Route) -> some View {
        Color.customBlack
            .task {
                guard navigation.currentRoute?.isContactImportRoute == true else {
                    return
                }

                navigation.path = [fallbackRoute]
            }
    }

    private var paykitDisabledRedirectView: some View {
        Color.customBlack
            .task {
                navigation.reset()
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
                if let route = resolvePastedPubkyRoute(
                    input: uri,
                    ownPublicKey: pubkyProfile.publicKey,
                    contacts: contactsManager.contacts
                ) {
                    navigation.navigate(route)
                    if case let .contactDetail(publicKey) = route {
                        await contactsManager.refreshContactReceiverPaths(publicKey: publicKey, wallet: wallet)
                    }
                    clipboardUri = nil
                    return
                }

                await wallet.waitForNodeToRun()
                try await Task.sleep(nanoseconds: Self.nodeReadyDelayNanoseconds)
                try await app.handleScannedData(uri)

                try await Task.sleep(nanoseconds: Self.statePropagationDelayNanoseconds)
                if shouldOpenPaymentSheet(for: uri) {
                    PaymentNavigationHelper.openPaymentSheet(
                        app: app,
                        currency: currency,
                        settings: settings,
                        sheetViewModel: sheets
                    )
                }
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

    private func shouldOpenPaymentSheet(for uri: String) -> Bool {
        !SamRockSetupRequest.isProtocolURL(uri)
    }

    private func sanitizedDeeplinkDescription(_ url: URL) -> String {
        if let description = SamRockSetupRequest.sanitizedDescription(url.absoluteString) {
            return description
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.scheme ?? "unknown"
        }

        guard components.host != nil else {
            return components.scheme ?? "unknown"
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        return components.string ?? (url.scheme ?? "unknown")
    }
}
