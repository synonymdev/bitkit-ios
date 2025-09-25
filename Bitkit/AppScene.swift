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
    @StateObject private var transfer = TransferViewModel()
    @StateObject private var widgets = WidgetsViewModel()
    @StateObject private var scannerManager = ScannerManager()
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var suggestionsManager = SuggestionsManager()
    @StateObject private var tagManager = TagManager()

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

        _app = StateObject(wrappedValue: AppViewModel(sheetViewModel: sheetViewModel, navigationViewModel: navigationViewModel))
        _sheets = StateObject(wrappedValue: sheetViewModel)
        _navigation = StateObject(wrappedValue: navigationViewModel)
        _wallet = StateObject(wrappedValue: WalletViewModel())
        _currency = StateObject(wrappedValue: CurrencyViewModel())
        _blocktank = StateObject(wrappedValue: BlocktankViewModel())
        _activity = StateObject(wrappedValue: ActivityListViewModel())
        _transfer = StateObject(wrappedValue: TransferViewModel())
        _widgets = StateObject(wrappedValue: WidgetsViewModel())
        _settings = StateObject(wrappedValue: SettingsViewModel())
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
            .onChange(of: wallet.totalBalanceSats, perform: handleBalanceChange)
            .onChange(of: scenePhase, perform: handleScenePhaseChange)
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
            .environmentObject(scannerManager)
            .environmentObject(settings)
            .environmentObject(suggestionsManager)
            .environmentObject(tagManager)
            .onAppear {
                if !settings.requirePinOnLaunch {
                    isPinVerified = true
                }

                NotificationService.shared.onRegistrationFailed = { _ in
                    app.toast(
                        type: .error,
                        title: "Notification Registration Failed",
                        description: "Bitkit was unable to register for push notifications."
                    )
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
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            if showRecoveryScreen {
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
            if !isPinVerified && settings.pinEnabled && (settings.requirePinOnLaunch || settings.requirePinWhenIdle) {
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

        wallet.addOnEvent(id: "activity-sync") { [weak activity] (_: Event) in
            // TODO: this might not be the best for performace to sync all payments on every event. Could switch to habdling the specific event.
            Task { try? await activity?.syncLdkNodePayments() }
        }

        Task { await startWallet() }
    }

    private func startWallet() async {
        do {
            try await wallet.start()
            try await activity.syncLdkNodePayments()

            // Start watching pending orders after wallet is ready
            await blocktank.startWatchingPendingOrders(transferViewModel: transfer)
        } catch {
            Logger.error("Failed to start wallet")
            Haptics.notify(.error)
        }
    }

    @Sendable
    private func setupTask() async {
        do {
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

    private func handleNodeLifecycleChange(_ state: NodeLifecycleState) {
        if state == .initializing {
            walletIsInitializing = true
        } else if state == .running {
            walletInitShouldFinish = true
        } else if case .errorStarting = state {
            walletInitShouldFinish = true
        }
    }

    private func handleBalanceChange(_: Int) {
        // Anytime we receive a balance update, we should sync the payments to activity list
        Task { try? await activity.syncLdkNodePayments() }
    }

    private func handleScenePhaseChange(_: ScenePhase) {
        // If 'pinOnIdle' is enabled, lock the app when the app goes to the background
        if scenePhase == .background && settings.pinEnabled && settings.requirePinWhenIdle {
            isPinVerified = false
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
}
