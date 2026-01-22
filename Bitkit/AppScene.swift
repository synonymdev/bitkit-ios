import Combine
import LDKNode
import SwiftUI

struct AppScene: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject private var session: SessionManager

    @StateObject private var app: AppViewModel
    @StateObject private var navigation = NavigationViewModel()
    @StateObject private var network = NetworkMonitor()
    @StateObject private var sheets = SheetViewModel()
    @StateObject private var wallet = WalletViewModel()
    @StateObject private var currency = CurrencyViewModel()
    @StateObject private var blocktank = BlocktankViewModel()
    @StateObject private var activity = ActivityListViewModel()
    @StateObject private var transfer: TransferViewModel
    @StateObject private var widgets = WidgetsViewModel()
    @StateObject private var pushManager = PushNotificationManager.shared
    @StateObject private var scannerManager = ScannerManager()
    @StateObject private var settings = SettingsViewModel.shared
    @StateObject private var suggestionsManager = SuggestionsManager()
    @StateObject private var tagManager = TagManager()
    @StateObject private var transferTracking: TransferTrackingManager
    @StateObject private var channelDetails = ChannelDetailsViewModel.shared
    @StateObject private var migrations = MigrationsService.shared

    @State private var hideSplash = false
    @State private var removeSplash = false
    @State private var walletIsInitializing: Bool? = nil
    @State private var walletInitShouldFinish = false
    @State private var isPinVerified: Bool = false
    @State private var showRecoveryScreen = false

    // Check if there's a critical update available
    private var hasCriticalUpdate: Bool {
        AppUpdateService.shared.availableUpdate?.critical == true
    }

    init() {
        let sheetViewModel = SheetViewModel()
        let navigationViewModel = NavigationViewModel()
        let transferService = TransferService(
            lightningService: LightningService.shared,
            blocktankService: CoreService.shared.blocktank
        )

        _app = StateObject(wrappedValue: AppViewModel(sheetViewModel: sheetViewModel, navigationViewModel: navigationViewModel))
        _sheets = StateObject(wrappedValue: sheetViewModel)
        _navigation = StateObject(wrappedValue: navigationViewModel)
        let walletVm = WalletViewModel(transferService: transferService, sheetViewModel: sheetViewModel)
        _wallet = StateObject(wrappedValue: walletVm)
        _currency = StateObject(wrappedValue: CurrencyViewModel())
        _blocktank = StateObject(wrappedValue: BlocktankViewModel())
        _activity = StateObject(wrappedValue: ActivityListViewModel(transferService: transferService))
        _transfer = StateObject(wrappedValue: TransferViewModel(
            transferService: transferService,
            sheetViewModel: sheetViewModel,
            onBalanceRefresh: { await walletVm.updateBalanceState() }
        ))
        _widgets = StateObject(wrappedValue: WidgetsViewModel())
        _settings = StateObject(wrappedValue: SettingsViewModel.shared)

        _transferTracking = StateObject(wrappedValue: TransferTrackingManager(service: transferService))
    }

    var body: some View {
        mainContent
            .sheet(
                item: $sheets.forgotPinSheetItem,
                onDismiss: { sheets.hideSheet() }
            ) {
                config in ForgotPinSheet(config: config)
            }
            .task(priority: .userInitiated, setupTask)
            .handleLightningStateOnScenePhaseChange()
            .onChange(of: currency.hasStaleData, perform: handleCurrencyStaleData)
            .onChange(of: wallet.walletExists, perform: handleWalletExistsChange)
            .onChange(of: wallet.nodeLifecycleState, perform: handleNodeLifecycleChange)
            .onChange(of: scenePhase, perform: handleScenePhaseChange)
            .onChange(of: migrations.isShowingMigrationLoading) { isLoading in
                if !isLoading {
                    SettingsViewModel.shared.updatePinEnabledState()
                    widgets.loadSavedWidgets()
                    suggestionsManager.reloadDismissed()
                    tagManager.reloadLastUsedTags()
                    if UserDefaults.standard.bool(forKey: "pinOnLaunch") && settings.pinEnabled {
                        isPinVerified = false
                    }
                    SweepViewModel.checkAndPromptForSweepableFunds(sheets: sheets)

                    if migrations.needsPostMigrationSync {
                        app.toast(
                            type: .warning,
                            title: t("migration__network_required_title"),
                            description: t("migration__network_required_msg"),
                            visibilityTime: 8.0
                        )
                    }
                }
            }
            .onChange(of: network.isConnected) { isConnected in
                // Retry starting wallet when network comes back online
                if isConnected {
                    handleNetworkRestored()
                }
            }
            .environmentObject(app)
            .environmentObject(navigation)
            .environmentObject(network)
            .environmentObject(sheets)
            .environmentObject(wallet)
            .environmentObject(currency)
            .environmentObject(blocktank)
            .environmentObject(activity)
            .environmentObject(transfer)
            .environmentObject(widgets)
            .environmentObject(pushManager)
            .environmentObject(scannerManager)
            .environmentObject(settings)
            .environmentObject(suggestionsManager)
            .environmentObject(tagManager)
            .environmentObject(transferTracking)
            .environmentObject(channelDetails)
            .onAppear {
                if !settings.pinEnabled {
                    isPinVerified = true
                }

                // Listen for quick action notifications
                NotificationCenter.default.addObserver(
                    forName: .quickActionSelected,
                    object: nil,
                    queue: .main
                ) { notification in
                    handleQuickAction(notification)
                }
            }
            .onReceive(BackupService.shared.backupFailurePublisher) { intervalMinutes in
                handleBackupFailure(intervalMinutes: intervalMinutes)
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            if migrations.isShowingMigrationLoading {
                migrationLoadingContent
            } else if showRecoveryScreen {
                RecoveryRouter()
                    .accentColor(.white)
            } else if hasCriticalUpdate {
                AppUpdateScreen()
            } else {
                walletContent
            }

            if !removeSplash && !session.skipSplashOnce {
                SplashView()
                    .opacity(hideSplash ? 0 : 1)
            }
        }
    }

    @ViewBuilder
    private var migrationLoadingContent: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("migration__title"), showBackButton: false, showMenuButton: false)

            VStack(spacing: 0) {
                VStack {
                    Spacer()

                    Image("wallet")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 14) {
                    DisplayText(t("migration__headline"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    BodyMText(t("migration__description"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ActivityIndicator(size: 32)
                    .padding(.top, 32)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @ViewBuilder
    private var walletContent: some View {
        if wallet.walletExists == true {
            existingWalletContent
        } else if wallet.walletExists == false {
            onboardingContent
        }
    }

    @ViewBuilder
    private var existingWalletContent: some View {
        if walletIsInitializing == true {
            // New wallet is being created or restored
            initializingContent
        } else if wallet.isRestoringWallet {
            // Wallet exists and has been restored from backup. isRestoringWallet is set to false inside below component
            WalletRestoreSuccess()
        } else {
            if !isPinVerified && settings.pinEnabled {
                AuthCheck {
                    isPinVerified = true
                }
            } else {
                MainNavView()
            }
        }
    }

    @ViewBuilder
    private var initializingContent: some View {
        if case .errorStarting = wallet.nodeLifecycleState {
            WalletRestoreError()
        } else {
            InitializingWalletView(shouldFinish: $walletInitShouldFinish) {
                Logger.debug("Wallet finished initializing but node state is \(wallet.nodeLifecycleState)")

                if wallet.nodeLifecycleState == .running {
                    walletIsInitializing = false
                }
            }
        }
    }

    @ViewBuilder
    private var onboardingContent: some View {
        NavigationStack {
            TermsView()
        }
        .accentColor(.white)
        .onAppear {
            // Reset these values if the wallet is wiped
            walletIsInitializing = nil
            walletInitShouldFinish = false
        }
    }

    // MARK: - Event Handlers

    private func handleCurrencyStaleData(_: Bool) {
        if currency.hasStaleData {
            app.toast(type: .error, title: "Rates currently unavailable", description: "An error has occurred. Please try again later.")
        }
    }

    private func handleWalletExistsChange(_: Bool?) {
        Logger.info("Wallet exists state changed: \(wallet.walletExists?.description ?? "nil")")

        if wallet.walletExists != nil {
            withAnimation(.easeInOut(duration: 0.2).delay(0.2)) {
                hideSplash = true
            }

            // Remove splash view after animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                removeSplash = true
            }
        }

        guard wallet.walletExists == true else { return }

        // Don't start wallet if we're in recovery mode
        guard !showRecoveryScreen else { return }

        wallet.addOnEvent(id: "toasts-and-sheets") { [weak app] lightningEvent in
            app?.handleLdkNodeEvent(lightningEvent)
        }

        if wallet.isRestoringWallet {
            Task {
                await restoreFromMostRecentBackup()

                await MainActor.run {
                    widgets.loadSavedWidgets()
                    widgets.objectWillChange.send()
                }

                await startWallet()
            }
        } else {
            Task { await startWallet() }
        }
    }

    private func startWallet() async {
        // Check network before attempting to start - LDK hangs when VSS is unreachable
        guard network.isConnected else {
            Logger.warn("Network offline, skipping wallet start", context: "AppScene")
            if MigrationsService.shared.isShowingMigrationLoading {
                await MainActor.run {
                    MigrationsService.shared.isShowingMigrationLoading = false
                    SettingsViewModel.shared.updatePinEnabledState()
                }
            }
            return
        }

        do {
            try await wallet.start()
            try await activity.syncLdkNodePayments()

            // Start watching pending orders after wallet is ready
            await blocktank.startWatchingPendingOrders(transferViewModel: transfer)

            // Schedule full backup after wallet create/restore to prevent epoch dates in backup status
            await BackupService.shared.scheduleFullBackup()
        } catch {
            Logger.error(error, context: "Failed to start wallet")
            Haptics.notify(.error)

            if MigrationsService.shared.isShowingMigrationLoading {
                await MainActor.run {
                    MigrationsService.shared.isShowingMigrationLoading = false
                    SettingsViewModel.shared.updatePinEnabledState()
                }
            }
        }
    }

    /// Handle orphaned keychain entries from previous app installs.
    /// If the installation marker doesn't exist but keychain has data, the app was reinstalled
    /// and the keychain data is orphaned (corresponding wallet data was deleted with the app).
    private func handleOrphanedKeychain() {
        // If marker exists, app was installed before - keychain is valid
        if InstallationMarker.exists() {
            Logger.debug("Installation marker exists, skipping orphaned keychain check", context: "AppScene")
            return
        }

        // Check if native keychain has data (orphaned from previous install)
        let hasNativeKeychain = (try? Keychain.exists(key: .bip39Mnemonic(index: 0))) == true

        // Check if RN keychain has data without corresponding RN files (orphaned)
        let hasOrphanedRNKeychain = MigrationsService.shared.hasOrphanedRNKeychain()

        if hasNativeKeychain || hasOrphanedRNKeychain {
            Logger.warn("Orphaned keychain detected, wiping", context: "AppScene")
            try? Keychain.wipeEntireKeychain()

            if hasOrphanedRNKeychain {
                MigrationsService.shared.cleanupRNKeychain()
            }
        }

        // Create marker for this installation
        do {
            try InstallationMarker.create()
        } catch {
            Logger.error("Failed to create installation marker: \(error)", context: "AppScene")
        }
    }

    @Sendable
    private func setupTask() async {
        do {
            // Handle orphaned keychain before anything else
            handleOrphanedKeychain()

            await checkAndPerformRNMigration()
            try wallet.setWalletExistsState()

            // Setup TimedSheetManager with all timed sheets
            TimedSheetManager.shared.setup(
                sheetViewModel: sheets,
                appViewModel: app,
                settingsViewModel: settings,
                walletViewModel: wallet,
                currencyViewModel: currency
            )
        } catch {
            app.toast(error)
        }
    }

    private func checkAndPerformRNMigration() async {
        let migrations = MigrationsService.shared

        guard !migrations.isMigrationChecked else {
            Logger.debug("RN migration already checked, skipping", context: "AppScene")
            return
        }

        guard !migrations.hasNativeWalletData() else {
            Logger.info("Native wallet data exists, skipping RN migration", context: "AppScene")
            migrations.markMigrationChecked()
            return
        }

        // Check if RN wallet data exists AND is not orphaned (has corresponding files)
        guard migrations.hasRNWalletData(), !migrations.hasOrphanedRNKeychain() else {
            Logger.info("No valid RN wallet data found, skipping migration", context: "AppScene")
            migrations.markMigrationChecked()
            return
        }

        await MainActor.run { migrations.isShowingMigrationLoading = true }
        Logger.info("RN wallet data found, starting migration...", context: "AppScene")

        do {
            try await migrations.migrateFromReactNative()
        } catch {
            Logger.error("RN migration failed: \(error)", context: "AppScene")
            migrations.markMigrationChecked()
            await MainActor.run { migrations.isShowingMigrationLoading = false }
            app.toast(
                type: .error,
                title: "Migration Failed",
                description: "Please restore your wallet manually using your recovery phrase"
            )
        }
    }

    private func restoreFromMostRecentBackup() async {
        guard let mnemonicData = try? Keychain.load(key: .bip39Mnemonic(index: 0)),
              let mnemonic = String(data: mnemonicData, encoding: .utf8)
        else { return }

        let passphrase: String? = {
            guard let data = try? Keychain.load(key: .bip39Passphrase(index: 0)) else { return nil }
            return String(data: data, encoding: .utf8)
        }()

        // Check for RN backup and get its timestamp
        let hasRNBackup = await MigrationsService.shared.hasRNRemoteBackup(mnemonic: mnemonic, passphrase: passphrase)
        let rnTimestamp: UInt64? = await hasRNBackup ? (try? RNBackupClient.shared.getLatestBackupTimestamp()) : nil

        // Get VSS backup timestamp
        let vssTimestamp = await BackupService.shared.getLatestBackupTime()

        // Determine which backup is more recent
        let shouldRestoreRN: Bool = {
            guard hasRNBackup else { return false }
            guard let vss = vssTimestamp, vss > 0 else { return true } // No VSS, use RN
            guard let rn = rnTimestamp else { return false } // No RN timestamp, use VSS
            return rn >= vss // RN is same or newer
        }()

        if shouldRestoreRN {
            do {
                try await MigrationsService.shared.restoreFromRNRemoteBackup(mnemonic: mnemonic, passphrase: passphrase)
            } catch {
                Logger.error("RN remote backup restore failed: \(error)", context: "AppScene")
                // Fall back to VSS
                await BackupService.shared.performFullRestoreFromLatestBackup()
            }
        } else {
            await BackupService.shared.performFullRestoreFromLatestBackup()
        }
    }

    private func handleNodeLifecycleChange(_ state: NodeLifecycleState) {
        if state == .initializing {
            walletIsInitializing = true
        } else if state == .running {
            walletInitShouldFinish = true
            app.markAppStatusInit()
            BackupService.shared.startObservingBackups()
        } else {
            if case .errorStarting = state {
                walletInitShouldFinish = true
            }
            Task {
                await BackupService.shared.stopObservingBackups()
            }
        }
    }

    private func handleScenePhaseChange(_: ScenePhase) {
        // If PIN is enabled, lock the app when the app goes to the background
        if scenePhase == .background && settings.pinEnabled {
            isPinVerified = false
        }
    }

    private func handleNetworkRestored() {
        // Refresh currency rates when network is restored - critical for UI
        // to display balances (MoneyText returns "0" if rates are nil)
        Task {
            await currency.refresh()
        }

        guard wallet.walletExists == true,
              scenePhase == .active
        else {
            return
        }

        // If node is stopped/failed, restart it
        switch wallet.nodeLifecycleState {
        case .stopped, .errorStarting:
            Logger.info("Network restored, retrying wallet start...", context: "AppScene")
            Task {
                await startWallet()
            }
        default:
            break
        }
    }

    private func handleQuickAction(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let shortcutType = userInfo["shortcutType"] as? String
        else {
            return
        }

        switch shortcutType {
        case "Recovery":
            showRecoveryScreen = true
        default:
            break
        }
    }

    private func handleBackupFailure(intervalMinutes: Int) {
        app.toast(
            type: .error,
            title: t("settings__backup__failed_title"),
            description: t("settings__backup__failed_message", variables: ["interval": "\(intervalMinutes)"])
        )
    }
}
