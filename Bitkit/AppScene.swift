import Combine
import LDKNode
import SwiftUI
import UserNotifications

struct IncomingPaykitPaymentRequestPresentationFeedback: Equatable {
    struct Toast: Equatable {
        let titleKey: String
        let descriptionKey: String
        let accessibilityIdentifier: String
        let isInformational: Bool
    }

    let diagnosticReason: IncomingPaykitPaymentRequestFailureReason
    let isTerminal: Bool
    let shouldLogDiagnostic: Bool
    let toast: Toast?

    init(
        deferral: PaykitPaymentRequestPresentationDeferral,
        fallbackReason: IncomingPaykitPaymentRequestFailureReason,
        shouldLogNonTerminalDiagnostic: Bool = false
    ) {
        switch deferral {
        case .requestedPresentationEnded:
            diagnosticReason = fallbackReason
            isTerminal = true
            shouldLogDiagnostic = true
            toast = Toast(
                titleKey: "wallet__payment_request",
                descriptionKey: "wallet__payment_request_unavailable",
                accessibilityIdentifier: "PaymentRequestUnavailableToast",
                isInformational: false
            )
        case let .requestExpired(wasRequested):
            diagnosticReason = .requestExpired
            isTerminal = true
            shouldLogDiagnostic = true
            toast = wasRequested ? Toast(
                titleKey: "wallet__payment_request",
                descriptionKey: "wallet__payment_request_expired",
                accessibilityIdentifier: "PaymentRequestExpiredToast",
                isInformational: false
            ) : nil
        case .retryScheduled:
            diagnosticReason = fallbackReason
            isTerminal = false
            shouldLogDiagnostic = shouldLogNonTerminalDiagnostic
            toast = nil
        case .ignored:
            diagnosticReason = fallbackReason
            isTerminal = false
            shouldLogDiagnostic = false
            toast = nil
        }
    }

    init(paymentDetailsPendingWasRequested: Bool) {
        diagnosticReason = .paymentDetailsPending
        isTerminal = false
        shouldLogDiagnostic = true
        toast = paymentDetailsPendingWasRequested ? Toast(
            titleKey: "wallet__payment_request",
            descriptionKey: "wallet__payment_request_waiting_for_details",
            accessibilityIdentifier: "PaymentRequestWaitingForDetailsToast",
            isInformational: true
        ) : nil
    }

    func diagnosticMessage(for request: PaykitPaymentRequest) -> String? {
        guard shouldLogDiagnostic else { return nil }
        let outcome = diagnosticReason == .paymentDetailsPending ? "Deferred" : "Rejected"
        return "\(outcome) incoming Paykit payment request presentation: category=\(diagnosticReason.category) " +
            "reason=\(diagnosticReason.rawValue) " +
            "counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(request.counterparty))"
    }
}

struct IncomingPaykitPaymentRequestPresentationState: Equatable {
    let requestedPresentationId: PaykitPaymentRequest.ID?
    let retryTrigger: Int
    let expirationTrigger: Int
    let unavailableTrigger: Int
    let pendingRequestIds: [PaykitPaymentRequest.ID]

    init(
        requestedPresentationId: PaykitPaymentRequest.ID?,
        retryTrigger: Int,
        expirationTrigger: Int,
        unavailableTrigger: Int,
        pendingRequestIds: [PaykitPaymentRequest.ID] = []
    ) {
        self.requestedPresentationId = requestedPresentationId
        self.retryTrigger = retryTrigger
        self.expirationTrigger = expirationTrigger
        self.unavailableTrigger = unavailableTrigger
        self.pendingRequestIds = pendingRequestIds
    }

    @MainActor
    init(_ manager: PaykitPaymentRequestManager) {
        self.init(
            requestedPresentationId: manager.requestedPresentationId,
            retryTrigger: manager.presentationRetryTrigger,
            expirationTrigger: manager.requestedPresentationExpirationTrigger,
            unavailableTrigger: manager.requestedPresentationUnavailableTrigger,
            pendingRequestIds: manager.pendingRequests.map(\.id)
        )
    }
}

enum IncomingPaykitPaymentRequestPresentationDispatch: Equatable {
    case presentFeedback(IncomingPaykitPaymentRequestPresentationFeedback, PaykitPaymentRequest)
    case presentNext
}

@Observable @MainActor
final class IncomingPaykitPaymentRequestPreparation {
    private(set) var request: PaykitPaymentRequest?
    private(set) var resolvedRoute: SendRoute?
    private let session: PubkyProfileManager.SignedInSession?
    var paymentContext: ContactPaymentContext?

    init(request: PaykitPaymentRequest, session: PubkyProfileManager.SignedInSession?) {
        self.request = request
        self.session = session
    }

    func visibleRequest(
        manager: PaykitPaymentRequestManager,
        session: PubkyProfileManager.SignedInSession?,
        paymentContext: ContactPaymentContext?,
        now: Date = Date()
    ) -> PaykitPaymentRequest? {
        guard let request, matchesSession(session),
              paymentContext == self.paymentContext,
              manager.isCurrentPresentation(request) || manager.isWaitingForPresentationRetry(request),
              !request.isExpired(at: now)
        else { return nil }
        return request
    }

    func matchesSession(_ session: PubkyProfileManager.SignedInSession?) -> Bool {
        session != nil && session == self.session
    }

    func clear() {
        request = nil
        resolvedRoute = nil
    }

    func ownsSheet(_ sheets: SheetViewModel) -> Bool {
        sheets.activeSheetConfiguration?.id == .send &&
            (sheets.activeSheetConfiguration?.data as? SendConfig)?.preparation === self && !sheets.isReplacingSheet
    }

    func complete(
        route: SendRoute,
        manager: PaykitPaymentRequestManager,
        session: PubkyProfileManager.SignedInSession?,
        app: AppViewModel,
        sheets: SheetViewModel
    ) -> Bool {
        guard !Task.isCancelled, ownsSheet(sheets), paymentContext != nil,
              let request = visibleRequest(manager: manager, session: session, paymentContext: app.contactPaymentContext),
              manager.isCurrentPresentation(request)
        else { return false }
        resolvedRoute = route
        return true
    }

    func whilePreparing<T>(_ operation: () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { @MainActor [weak self] in self?.clear() }
        }
    }
}

@MainActor
enum IncomingPaykitPaymentRequestPresentationDispatcher {
    static func canHandleSubscriptionNotification(
        manager: PaykitPaymentRequestManager,
        app: AppViewModel,
        sheets: SheetViewModel
    ) -> Bool {
        manager.requestedPresentationId == nil &&
            sheets.activeSheetConfiguration == nil &&
            !sheets.isReplacingSheet &&
            app.contactPaymentContext == nil
    }

    static func presentNextItem(
        manager: PaykitPaymentRequestManager,
        sheets: SheetViewModel,
        canRetryPreparation: Bool,
        handleSubscriptionNotification: () async -> Void,
        presentPaymentRequest: () async -> Void
    ) async {
        guard sheets.activeSheetConfiguration == nil || canRetryPreparation,
              !sheets.isReplacingSheet
        else { return }
        if canRetryPreparation || manager.requestedPresentationId != nil {
            await presentPaymentRequest()
            return
        }
        if PaykitSubscriptionNotificationTargetStore.load() != nil {
            await handleSubscriptionNotification()
            guard PaykitSubscriptionNotificationTargetStore.load() == nil,
                  sheets.activeSheetConfiguration == nil,
                  !sheets.isReplacingSheet
            else { return }
        }
        if let subscription = manager.subscriptionProposalForPresentation() {
            sheets.showSheet(.subscription, data: SubscriptionSheetItem(route: .review(subscription)))
            return
        }
        await presentPaymentRequest()
    }

    static func feedback(
        deferring request: PaykitPaymentRequest,
        reason: IncomingPaykitPaymentRequestFailureReason,
        with manager: PaykitPaymentRequestManager
    ) -> IncomingPaykitPaymentRequestPresentationFeedback {
        let result = manager.deferPresentation(request, diagnosticReason: reason)
        return IncomingPaykitPaymentRequestPresentationFeedback(
            deferral: result.deferral,
            fallbackReason: reason,
            shouldLogNonTerminalDiagnostic: result.shouldLogDiagnostic
        )
    }

    static func finishPendingPrivateLink(
        for request: PaykitPaymentRequest,
        with manager: PaykitPaymentRequestManager
    ) -> IncomingPaykitPaymentRequestPresentationFeedback? {
        let wasRequested = manager.requestedPresentationId == request.id
        guard manager.markPresentedIfPending(request) else { return nil }
        return IncomingPaykitPaymentRequestPresentationFeedback(paymentDetailsPendingWasRequested: wasRequested)
    }

    static func handleStateChange(
        from previous: IncomingPaykitPaymentRequestPresentationState,
        to current: IncomingPaykitPaymentRequestPresentationState,
        manager: PaykitPaymentRequestManager
    ) -> [IncomingPaykitPaymentRequestPresentationDispatch] {
        var dispatches: [IncomingPaykitPaymentRequestPresentationDispatch] = []
        if current.expirationTrigger != previous.expirationTrigger {
            while let request = manager.consumeExpiredRequestedPresentation() {
                dispatches.append(
                    .presentFeedback(
                        IncomingPaykitPaymentRequestPresentationFeedback(
                            deferral: .requestExpired(wasRequested: true),
                            fallbackReason: .resolutionFailed
                        ),
                        request
                    )
                )
            }
        }
        if current.unavailableTrigger != previous.unavailableTrigger {
            while let request = manager.consumeUnavailableRequestedPresentation() {
                dispatches.append(
                    .presentFeedback(
                        IncomingPaykitPaymentRequestPresentationFeedback(
                            deferral: .requestedPresentationEnded,
                            fallbackReason: .resolutionFailed
                        ),
                        request
                    )
                )
            }
        }
        if current.retryTrigger != previous.retryTrigger ||
            previous.requestedPresentationId != current.requestedPresentationId && current.requestedPresentationId != nil ||
            current.expirationTrigger != previous.expirationTrigger ||
            current.pendingRequestIds.contains(where: { !previous.pendingRequestIds.contains($0) })
        {
            dispatches.append(.presentNext)
        }
        return dispatches
    }
}

enum PaykitPaymentRequestPollingRound: Equatable {
    case skip
    case refreshInbox
    case refreshInboxAndMaintenance
}

struct PaykitPaymentRequestPollingSchedule {
    let nextDelay: Duration = .seconds(10)
    private static let maintenanceIntervals: [Duration] = [.seconds(30), .seconds(60)]
    private var maintenanceIntervalIndex = 0
    private var nextMaintenance: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now) {
        nextMaintenance = now.advanced(by: Self.maintenanceIntervals[0])
    }

    mutating func takeRound(isConnected: Bool, now: ContinuousClock.Instant = .now) -> PaykitPaymentRequestPollingRound {
        guard isConnected else { return .skip }

        guard now >= nextMaintenance else { return .refreshInbox }
        maintenanceIntervalIndex = min(maintenanceIntervalIndex + 1, Self.maintenanceIntervals.count - 1)
        nextMaintenance = now.advanced(by: Self.maintenanceIntervals[maintenanceIntervalIndex])
        return .refreshInboxAndMaintenance
    }
}

struct AppScene: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject private var session: SessionManager

    @StateObject private var app: AppViewModel
    @StateObject private var navigation = NavigationViewModel()
    @StateObject private var network = NetworkMonitor()
    @StateObject private var sheets = SheetViewModel()
    @StateObject private var wallet: WalletViewModel
    @StateObject private var currency = CurrencyViewModel()
    @StateObject private var blocktank = BlocktankViewModel()
    @StateObject private var activity: ActivityListViewModel
    @StateObject private var feeEstimatesManager: FeeEstimatesManager
    @StateObject private var transfer: TransferViewModel
    @StateObject private var widgets = WidgetsViewModel()
    @State private var cameraManager = CameraManager.shared
    @StateObject private var pushManager = PushNotificationManager.shared
    @StateObject private var scannerManager = ScannerManager()
    @StateObject private var settings = SettingsViewModel.shared
    @StateObject private var suggestionsManager = SuggestionsManager()
    @StateObject private var tagManager = TagManager()
    @StateObject private var transferTracking: TransferTrackingManager
    @StateObject private var channelDetails = ChannelDetailsViewModel.shared
    @StateObject private var migrations = MigrationsService.shared
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var pubkyProfile = PubkyProfileManager()
    @StateObject private var contactsManager = ContactsManager()
    @State private var keyboardManager = KeyboardManager()
    @State private var trezorManager: TrezorManager
    @State private var trezorViewModel: TrezorViewModel
    @State private var jadeManager: JadeManager
    @State private var hwWalletManager: HwWalletManager
    @State private var calculatorInputManager = CalculatorInputManager()
    @State private var paykitPaymentRequestManager = PaykitPaymentRequestManager()
    @State private var incomingPaymentRequestPreparation: IncomingPaykitPaymentRequestPreparation?
    @State private var receivedPaymentBackfillCache = PaykitReceivedPaymentBackfillCache(
        activityChanges: CoreService.shared.activity.activitiesChangedPublisher
    )

    @State private var hideSplash = false
    @State private var removeSplash = false
    @State private var walletIsInitializing: Bool? = nil
    @State private var isWalletBackupRestoreRunning = false
    @State private var didWalletBackupRestoreFail = false
    @State private var isPinVerified: Bool = false
    @State private var showRecoveryScreen = false

    /// Check if there's a critical update available
    private var hasCriticalUpdate: Bool {
        AppUpdateService.shared.availableUpdate?.critical == true && !Env.isDebug
    }

    init() {
        let sheetViewModel = SheetViewModel()
        let navigationViewModel = NavigationViewModel()
        let transferService = TransferService(
            lightningService: LightningService.shared,
            blocktankService: CoreService.shared.blocktank
        )

        // Run app data migrations before any feature code loads migrated state
        AppDataMigrations.run()
        PaykitFeatureFlags.enforceBuildAvailability()
        ContactPaymentsService.enableAllPaymentOptions()

        _app = StateObject(wrappedValue: AppViewModel(
            sheetViewModel: sheetViewModel,
            navigationViewModel: navigationViewModel
        ))
        _sheets = StateObject(wrappedValue: sheetViewModel)
        _navigation = StateObject(wrappedValue: navigationViewModel)
        let feeEstimatesManager = FeeEstimatesManager()
        let walletVm = WalletViewModel(
            transferService: transferService,
            sheetViewModel: sheetViewModel,
            feeEstimatesManager: feeEstimatesManager
        )
        _wallet = StateObject(wrappedValue: walletVm)
        _currency = StateObject(wrappedValue: CurrencyViewModel())
        _blocktank = StateObject(wrappedValue: BlocktankViewModel())
        _feeEstimatesManager = StateObject(wrappedValue: feeEstimatesManager)
        _activity = StateObject(wrappedValue: ActivityListViewModel(transferService: transferService))

        // Created ahead of `transfer` so the hardware-wallet transfer flow can reach the funding
        // (compose/sign/broadcast) and device-session (reconnect) capabilities.
        let trezorManager = TrezorManager()
        let jadeManager = JadeManager()
        let hwWalletManager = HwWalletManager(trezorSession: trezorManager, jadeSession: jadeManager)

        _transfer = StateObject(wrappedValue: TransferViewModel(
            transferService: transferService,
            sheetViewModel: sheetViewModel,
            hwFunding: hwWalletManager,
            hwConnecting: hwWalletManager,
            hwFeeRateProvider: {
                guard let rates = await feeEstimatesManager.getEstimates() else { return nil }
                return UInt64(TransactionSpeed.fast.getFeeRate(from: rates))
            },
            hwAddressProvider: {
                try await LightningService.shared.addressInfoForType(.nativeSegwit, atIndex: 0).address
            },
            onBalanceRefresh: { await walletVm.updateBalanceState() }
        ))
        _widgets = StateObject(wrappedValue: WidgetsViewModel())
        _settings = StateObject(wrappedValue: SettingsViewModel.shared)

        _transferTracking = StateObject(wrappedValue: TransferTrackingManager(service: transferService))

        let trezorViewModel = TrezorViewModel(connection: trezorManager)
        _trezorManager = State(initialValue: trezorManager)
        _trezorViewModel = State(initialValue: trezorViewModel)
        // Held here because `HwWalletManager` keeps its vendor sessions weakly.
        _jadeManager = State(initialValue: jadeManager)
        _hwWalletManager = State(initialValue: hwWalletManager)
    }

    private func configurePrivatePaykitContactResolvers() {
        CoreService.shared.activity.setPrivatePaykitContactResolvers(
            invoice: { paymentHash in
                await PrivatePaykitService.shared.contactPublicKey(forPrivateInvoicePaymentHash: paymentHash)
            },
            onchainAddresses: { @MainActor address, outputAddresses in
                let identity = pubkyProfile.publicKey
                let contacts = paykitPaymentRequestManager.receivedPaymentContacts
                let reservations = PrivatePaykitAddressReservationStore.shared
                let reservationRevision = await reservations.attributionRevision
                guard let combined = try? await contacts.includingReservations(for: outputAddresses, lookup: {
                    try await reservations.contactPublicKeyForAttribution(forReservedAddress: $0)
                }) else { return nil }
                guard pubkyProfile.authState == .authenticated,
                      PubkyPublicKeyFormat.matches(identity, pubkyProfile.publicKey),
                      contacts == paykitPaymentRequestManager.receivedPaymentContacts,
                      await reservations.attributionRevision == reservationRevision
                else { return nil }
                return combined.contact(receivingAddress: address, outputAddresses: outputAddresses)
            }
        )
    }

    var body: some View {
        appEventContent
    }

    private var configuredContent: some View {
        mainContent
            .sheet(
                item: $sheets.forgotPinSheetItem,
                onDismiss: { sheets.hideSheetIfActive(.forgotPin, reason: "Forgot PIN sheet dismissed") }
            ) {
                config in ForgotPinSheet(config: config)
            }
            .sheet(
                item: $sheets.appUpdateSheetItem,
                onDismiss: {
                    sheets.hideSheetIfActive(.appUpdate, reason: "App update sheet dismissed")
                    app.ignoreAppUpdate()
                }
            ) {
                config in AppUpdateSheet(config: config)
            }
            .task(priority: .userInitiated, setupTask)
            .task(id: [scenePhase == .active, wallet.walletExists == true, isWalletBackupRestoreRunning, network.isConnected]) {
                guard scenePhase == .active, wallet.walletExists == true,
                      !isWalletBackupRestoreRunning, !BackupService.shared.hasPendingWalletRestore()
                else { return }
                await pubkyProfile.retrySessionRestoration()
            }
            .task(id: [scenePhase == .active, network.isConnected]) { await pollIncomingPaykitPaymentRequests() }
            .task { await handlePendingPaykitSubscriptionNotification() }
            .onChange(of: currency.hasStaleData) { _, newValue in handleCurrencyStaleData(newValue) }
            .onChange(of: wallet.walletExists) { _, newValue in handleWalletExistsChange(newValue) }
            .onChange(of: wallet.nodeLifecycleState) { _, newValue in handleNodeLifecycleChange(newValue) }
            .onChange(of: scenePhase, initial: true) { _, newValue in handleScenePhaseChange(newValue) }
            .onChange(of: network.isConnected) { _, isConnected in handleNetworkChange(isConnected) }
            .onOpenURL { url in app.retainDeepLink(url) }
            // Bridge the vendor managers' device state into the watch-only manager without coupling them:
            // each bumps devicesRevision on any device or connection change.
            .onChange(of: trezorManager.devicesRevision) { _, _ in pushHardwareDevices() }
            .onChange(of: jadeManager.devicesRevision) { _, _ in pushHardwareDevices() }
            .onChange(of: isPinVerified) { _, verified in
                if verified {
                    Task { await hwWalletManager.reconnectOnForeground() }
                    Task { await presentNextIncomingPaykitItem() }
                }
            }
            .onReceive(settings.settingsPublisher) { _ in hwWalletManager.reconcileForSettingsChange() }
            .onChange(of: migrations.isShowingMigrationLoading) { _, isLoading in
                if !isLoading {
                    SettingsViewModel.shared.updatePinEnabledState()
                    widgets.loadSavedWidgets()
                    suggestionsManager.reloadDismissed()
                    tagManager.reloadLastUsedTags()
                    if UserDefaults.standard.bool(forKey: "pinOnLaunch") && settings.pinEnabled {
                        isPinVerified = false
                    }

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
            .environmentObject(app)
            .environmentObject(navigation)
            .environmentObject(network)
            .environmentObject(sheets)
            .environmentObject(wallet)
            .environmentObject(currency)
            .environmentObject(blocktank)
            .environmentObject(feeEstimatesManager)
            .environmentObject(activity)
            .environmentObject(transfer)
            .environmentObject(widgets)
            .environment(cameraManager)
            .environmentObject(pushManager)
            .environmentObject(scannerManager)
            .environmentObject(settings)
            .environmentObject(suggestionsManager)
            .environmentObject(tagManager)
            .environmentObject(transferTracking)
            .environmentObject(channelDetails)
            .environmentObject(pubkyProfile)
            .environmentObject(contactsManager)
            .environment(keyboardManager)
            .environment(trezorManager)
            .environment(trezorViewModel)
            .environment(jadeManager)
            .environment(hwWalletManager)
            .environment(calculatorInputManager)
            .environment(paykitPaymentRequestManager)
    }

    private var paykitEventContent: some View {
        configuredContent
            .onChange(of: pubkyProfile.authState, initial: true) { _, authState in
                receivedPaymentBackfillCache.invalidate()
                if authState == .authenticated, let pk = pubkyProfile.publicKey {
                    paykitPaymentRequestManager.activate(identity: pk)
                    Task {
                        await handlePendingPaykitSubscriptionNotification()
                        try? await contactsManager.loadContacts(for: pk)
                        await refreshPrivateOnlyPaykitApp()
                        await refreshIncomingPaykitPaymentRequests(presentItems: false)
                        if PaykitSubscriptionNotificationTargetStore.load() == nil {
                            await presentNextIncomingPaykitItem()
                        }
                        if !PaykitFeatureFlags.isUIEnabled, wallet.walletExists == true {
                            await retryPendingPaykitEndpointRemoval()
                        }
                    }
                } else if authState == .idle {
                    contactsManager.reset()
                    paykitPaymentRequestManager.clear()
                }
            }
            .onReceive(contactsManager.savedContactsChangedPublisher) { contacts in
                let publicKeys = contacts.map(\.publicKey)
                guard PaykitFeatureFlags.isUIEnabled,
                      wallet.walletExists == true,
                      pubkyProfile.authState == .authenticated
                else { return }
                paykitPaymentRequestManager.updateSavedPublicKeys(publicKeys)
                Task {
                    await PrivatePaykitService.shared.prepareSavedContacts(publicKeys, wallet: wallet)
                    await refreshIncomingPaykitPaymentRequests(forceFresh: true)
                }
            }
            .onReceive(PaykitPaymentProofService.proofStateChangedPublisher) {
                Task { await refreshIncomingPaykitPaymentRequests(mode: .stored, forceFresh: true) }
            }
            .onReceive(PaykitPaymentProofService.onchainPaymentResolutionPublisher) { resolution in
                Task { await associateResolvedPaykitOnchainPayment(resolution) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .paykitSubscriptionPaymentDue)) { _ in
                Task { await handlePendingPaykitSubscriptionNotification() }
            }
    }

    private var appEventContent: some View {
        paykitEventContent
            .onChange(of: sheets.activeSheetConfiguration?.id) { _, activeSheetId in
                guard activeSheetId == nil, !sheets.isReplacingSheet else { return }
                scheduleNextIncomingPaykitItemPresentation()
            }
            .onChange(of: isIncomingPaymentRequestPreparationInvalid) { _, invalid in
                guard invalid, let preparation = incomingPaymentRequestPreparation else { return }
                endIncomingPaymentRequestPreparation(preparation)
            }
            .onChange(of: app.showDrawer) { _, isShowing in
                if !isShowing {
                    Task { await presentNextIncomingPaykitItem() }
                }
            }
            .onChange(of: incomingPaykitPaymentRequestPresentationState) { previous, current in
                handleIncomingPaykitPaymentRequestPresentationStateChange(from: previous, to: current)
            }
            .onChange(of: navigation.currentRoute) { oldRoute, newRoute in
                guard shouldDiscardPendingImport(currentRoute: oldRoute, destination: newRoute) else {
                    return
                }

                contactsManager.clearPendingImport()
            }
            .onChange(of: pubkyProfile.sessionRestorationFailed) { _, failed in
                if failed {
                    pubkyProfile.sessionRestorationFailed = false
                    app.toast(type: .error, title: t("profile__session_expired_title"), description: t("profile__session_expired_description"))
                }
            }
            .onChange(of: pubkyProfile.adoptedSourceLost) { _, lost in
                if lost {
                    pubkyProfile.adoptedSourceLost = false
                    app.toast(type: .error, title: t("profile__source_lost_title"), description: t("profile__source_lost_description"))
                    if navigation.path.contains(where: \.isPubkyIdentityRoute) {
                        navigation.path = [.pubkyChoice]
                    }
                }
            }
            .onAppear {
                if !settings.pinEnabled {
                    isPinVerified = true
                }

                if let url = DeepLinkRouter.shared.consume() {
                    app.retainDeepLink(url)
                }

                // Listen for quick action notifications
                NotificationCenter.default.addObserver(
                    forName: .quickActionSelected,
                    object: nil,
                    queue: .main
                ) { notification in
                    handleQuickAction(notification)
                }
                NotificationCenter.default.addObserver(
                    forName: .deepLinkReceived,
                    object: nil,
                    queue: .main
                ) { notification in
                    handleDeepLinkNotification(notification)
                }
            }
            .onReceive(BackupService.shared.backupFailurePublisher) { intervalMinutes in
                handleBackupFailure(intervalMinutes: intervalMinutes)
            }
            .onReceive(AppUpdateService.shared.$availableUpdate) { update in
                guard update != nil else { return }
                TimedSheetManager.shared.reevaluate()
            }
    }

    private func handleDeepLinkNotification(_ notification: Notification) {
        if let retainedURL = DeepLinkRouter.shared.consume() {
            app.retainDeepLink(retainedURL)
            return
        }
        if let receivedURL = notification.object as? URL {
            app.retainDeepLink(receivedURL)
        }
    }

    private var mainContent: some View {
        ZStack {
            if Env.isTrezorEmulatorTesting {
                trezorEmulatorTestContent
            } else if migrations.isShowingMigrationLoading {
                migrationLoadingContent
            } else if showRecoveryScreen {
                RecoveryRouter()
                    .accentColor(.white)
            } else if hasCriticalUpdate {
                AppUpdateScreen()
            } else {
                walletContent
            }

            if !Env.isTrezorEmulatorTesting, !removeSplash, !session.skipSplashOnce {
                SplashView()
                    .opacity(hideSplash ? 0 : 1)
            }
        }
    }

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

    private var trezorEmulatorTestContent: some View {
        NavigationStack {
            TrezorRootView()
        }
        .accentColor(.white)
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
                AuthCheck(
                    onCancel: nil,
                    onPinVerified: {
                        isPinVerified = true
                    }
                )
            } else {
                MainNavView()
            }
        }
    }

    @ViewBuilder
    private var initializingContent: some View {
        if didWalletBackupRestoreFail {
            WalletRestoreError {
                didWalletBackupRestoreFail = false
                await restoreWalletBackupAndStart()
            }
        } else if case .errorStarting = wallet.nodeLifecycleState {
            WalletRestoreError(onRetry: retryWalletStart)
        } else {
            InitializingWalletView(nodeLifecycleState: $wallet.nodeLifecycleState) {
                Logger.debug("Wallet finished initializing but node state is \(wallet.nodeLifecycleState)")

                if wallet.nodeLifecycleState == .running {
                    walletIsInitializing = false
                }
            }
        }
    }

    private var onboardingContent: some View {
        NavigationStack {
            TermsView()
        }
        .accentColor(.white)
        .onAppear {
            // Reset initialization if the wallet is wiped
            walletIsInitializing = nil

            // Only the app-update sheet qualifies without a wallet, so onboarding
            // won't surface the other (wallet-gated) timed sheets.
            TimedSheetManager.shared.onPrimaryScreenEntered()
        }
        .onDisappear {
            TimedSheetManager.shared.onPrimaryScreenExited()
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

        let shouldRestoreWalletBackup = wallet.isRestoringWallet || BackupService.shared.hasPendingWalletRestore()
        if shouldRestoreWalletBackup {
            walletIsInitializing = true
        }

        Task {
            if shouldRestoreWalletBackup {
                await restoreWalletBackupAndStart()
                return
            }

            let initializePubkyTask = Task {
                await pubkyProfile.initialize()
            }

            await startWallet()
            await initializePubkyTask.value
        }
    }

    private func startWallet(completingBackupRestore: Bool = false) async {
        let hasPendingRestore = BackupService.shared.hasPendingWalletRestore()
        guard !WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: isWalletBackupRestoreRunning,
            hasPendingRestore: hasPendingRestore,
            isRestoreCompletionStart: completingBackupRestore
        ) else {
            Logger.warn("Wallet start deferred until backup restoration completes", context: "AppScene")
            return
        }

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
            if !PaykitFeatureFlags.isUIEnabled {
                await retryPendingPaykitEndpointRemoval()
            }

            // Start watching pending orders after wallet is ready
            await blocktank.startWatchingPendingOrders(transferViewModel: transfer)

            // Open the swap updates stream so any pending LN -> onchain swaps resume
            // and auto-claim once their lockup confirms. Retries until the stream starts.
            wallet.ensureSwapUpdatesRunning()

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
            SharedPubkyKeychain.removeAllOwn()
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
        configurePrivatePaykitContactResolvers()
        AppReset.hardwareWallets = hwWalletManager
        do {
            // Handle orphaned keychain before anything else
            handleOrphanedKeychain()

            await checkAndPerformRNMigration()
            try wallet.setWalletExistsState()

            // Load any paired hardware devices from storage and feed the watch-only manager so its
            // watchers start at launch (no-op until a device is paired). loadKnownDevices() also
            // bumps devicesRevision, but push explicitly so the initial state is delivered.
            trezorManager.loadKnownDevices()
            jadeManager.loadKnownDevices()
            pushHardwareDevices()

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

    private func restoreWalletBackupAndStart() async {
        guard !isWalletBackupRestoreRunning else { return }
        isWalletBackupRestoreRunning = true
        walletIsInitializing = true
        didWalletBackupRestoreFail = false
        defer { isWalletBackupRestoreRunning = false }

        let didRestore: Bool = if BackupService.shared.hasPendingWalletRestore() {
            await restoreVssBackup()
        } else {
            await restoreFromMostRecentBackup()
        }
        guard didRestore else {
            didWalletBackupRestoreFail = true
            return
        }

        widgets.loadSavedWidgets()
        widgets.objectWillChange.send()
        await pubkyProfile.initialize()
        await startWallet(completingBackupRestore: true)
    }

    private func retryWalletStart() async {
        do {
            wallet.nodeLifecycleState = .initializing
            try await wallet.start()
            try wallet.setWalletExistsState()
        } catch {
            Logger.error("Failed to start wallet on retry", context: "AppScene")
            Haptics.notify(.error)
        }
    }

    private func retryPendingWalletRestoreIfNeeded() -> Bool {
        if isWalletBackupRestoreRunning {
            return true
        }
        guard BackupService.shared.hasPendingWalletRestore() else { return false }

        Task { await restoreWalletBackupAndStart() }
        return true
    }

    private func restoreFromMostRecentBackup() async -> Bool {
        BackupService.shared.setRestoring(true)
        defer { BackupService.shared.setRestoring(false) }

        guard let mnemonicData = try? Keychain.load(key: .bip39Mnemonic(index: 0)),
              let mnemonic = String(data: mnemonicData, encoding: .utf8)
        else { return false }

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
                return true
            } catch {
                Logger.error("RN remote backup restore failed: \(error)", context: "AppScene")
                // Fall back to VSS
                return await restoreVssBackup()
            }
        }

        return await restoreVssBackup()
    }

    private func restoreVssBackup() async -> Bool {
        do {
            try await BackupService.shared.performFullRestoreFromLatestBackup()
            return true
        } catch {
            app.toast(error)
            return false
        }
    }

    private func handleNodeLifecycleChange(_ state: NodeLifecycleState) {
        if state == .initializing {
            walletIsInitializing = true
        } else if state == .running {
            app.markAppStatusInit()
            BackupService.shared.startObservingBackups()
            QuickPayPaymentCoordinator.shared.reconcileAgainstLdk()
            Task {
                if !PaykitFeatureFlags.isUIEnabled {
                    await retryPendingPaykitEndpointRemoval()
                }
                guard PaykitFeatureFlags.isUIEnabled else { return }
                await refreshPrivateOnlyPaykitApp()
                await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
                await PrivatePaykitService.shared.prepareSavedContacts(
                    contactsManager.contacts.map(\.publicKey),
                    wallet: wallet
                )
                await refreshIncomingPaykitPaymentRequests()
            }
        } else {
            Task {
                await BackupService.shared.stopObservingBackups()
            }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        Logger.info("Scene phase changed: \(newPhase)", context: "AppScene")

        if newPhase == .background {
            if settings.pinEnabled {
                // If PIN is enabled, lock the app when the app goes to the background
                isPinVerified = false
            }
            hwWalletManager.onAppBackgrounded()
        }

        // `.inactive` is left alone: the iOS Bluetooth pairing alert puts the app there mid-connect.
        if newPhase == .active {
            // Called even behind the PIN screen, so a background release still pending is called off.
            hwWalletManager.onAppBecameActive()
            // Reconnect a known hardware device so its connection indicator turns green again;
            if isPinVerified || !settings.pinEnabled {
                Task { await hwWalletManager.reconnectOnForeground() }
            }
            if wallet.walletExists == true {
                if retryPendingWalletRestoreIfNeeded() {
                    return
                }
                Task {
                    if pubkyProfile.isInitialized {
                        await pubkyProfile.checkAdoptedSource()
                    }
                    async let sessionRecovery: Void = network.isConnected ? pubkyProfile.restoreSessionIfNeeded() : ()
                    await clearDeliveredNotifications()
                    await LightningService.shared.reconnectPeers()
                    try? await wallet.sync()
                    await sessionRecovery
                    await retryPendingPaykitEndpointRemoval()
                    await wallet.refreshPublicPaykitEndpointsOnForeground()
                    if PaykitFeatureFlags.isUIEnabled {
                        await refreshPrivateOnlyPaykitApp()
                        let contactPublicKeys = contactsManager.contacts.map(\.publicKey)
                        await PrivatePaykitService.shared.prepareSavedContacts(
                            contactPublicKeys,
                            wallet: wallet
                        )
                        await refreshIncomingPaykitPaymentRequests()
                    }
                }
            }
        }
    }

    private func refreshPrivateOnlyPaykitApp() async {
        let publicSharingEnabled = UserDefaults.standard.bool(forKey: PublicPaykitService.publishingEnabledKey)
        let privateSharingEnabled = UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey)
        guard privateSharingEnabled, !publicSharingEnabled else { return }
        guard await PubkyService.currentPublicKey() != nil else { return }

        do {
            try await PublicPaykitService.syncPaykitApp()
        } catch {
            Logger.warn("Failed to refresh private Paykit app registration: \(error)", context: "AppScene")
        }
    }

    @discardableResult
    private func refreshIncomingPaykitPaymentRequests(
        presentItems: Bool = true,
        mode: PaykitPaymentRequestRefreshMode = .full,
        forceFresh: Bool = false,
        messagePriority: PaykitSdkOperationLock.Priority = .ordered
    ) async -> Bool {
        guard PaykitFeatureFlags.isUIEnabled,
              wallet.walletExists == true,
              pubkyProfile.authState == .authenticated
        else {
            paykitPaymentRequestManager.clearEligibleTargets()
            return false
        }

        guard !Task.isCancelled else { return false }
        paykitPaymentRequestManager.updateSavedPublicKeys(contactsManager.contacts.map(\.publicKey))
        if mode == .full {
            await PaykitPaymentProofService.shared.reconcile()
        }
        guard let identity = pubkyProfile.publicKey else { return false }
        let refreshed = await paykitPaymentRequestManager.refresh(mode: mode, forceFresh: forceFresh, messagePriority: messagePriority)
        guard pubkyProfile.authState == .authenticated,
              PubkyPublicKeyFormat.matches(identity, pubkyProfile.publicKey)
        else { return false }
        let contacts = paykitPaymentRequestManager.receivedPaymentContacts
        do {
            try await CoreService.shared.activity.backfillReceivedPaykitContacts(
                contacts, identity: identity, cache: receivedPaymentBackfillCache
            ) { @MainActor in
                pubkyProfile.authState == .authenticated &&
                    PubkyPublicKeyFormat.matches(identity, pubkyProfile.publicKey) &&
                    contacts == paykitPaymentRequestManager.receivedPaymentContacts
            }
        } catch {
            Logger.warn("Failed to attribute received Paykit payments: \(error)", context: "AppScene")
        }
        if presentItems {
            await presentNextIncomingPaykitItem()
        }
        if mode == .full {
            await paykitPaymentRequestManager.refreshEligibleTargets(savedPublicKeys: contactsManager.contacts.map(\.publicKey))
        }
        return refreshed
    }

    private func associateResolvedPaykitOnchainPayment(_ resolution: PaykitOnchainPaymentResolution) async {
        if let identity = pubkyProfile.publicKey,
           PubkyPublicKeyFormat.matches(resolution.identity, identity)
        {
            do {
                _ = try await tryNTimes(
                    toTry: {
                        try? await activity.syncLdkNodePayments()
                        return try await activity.findActivity(byPaymentId: resolution.transactionId)
                    },
                    times: 12,
                    interval: 2
                )
                try await activity.setContact(
                    resolution.requestId.counterparty,
                    forPaymentId: resolution.transactionId,
                    syncLdkPayments: false
                )
            } catch {
                Logger.warn(
                    "Failed to associate resolved Paykit payment \(resolution.transactionId) with its contact: \(error)",
                    context: "AppScene"
                )
            }
        }
        await PaykitPaymentProofService.shared.consumeOnchainPaymentResolution(resolution)
    }

    private func pollIncomingPaykitPaymentRequests() async {
        guard scenePhase == .active, network.isConnected else { return }

        await PubkyService.republishIdentityIfNeeded(publicKey: pubkyProfile.publicKey)
        await refreshIncomingPaykitPaymentRequests(messagePriority: .background)
        var schedule = PaykitPaymentRequestPollingSchedule()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: schedule.nextDelay)
            } catch {
                return
            }
            guard !isWalletBackupRestoreRunning,
                  !BackupService.shared.hasPendingWalletRestore()
            else { continue }
            let mode: PaykitPaymentRequestRefreshMode
            switch schedule.takeRound(isConnected: network.isConnected) {
            case .skip:
                continue
            case .refreshInbox:
                mode = .inbox
            case .refreshInboxAndMaintenance:
                mode = .full
            }
            let session = pubkyProfile.currentSession
            if mode == .full {
                await PubkyService.republishIdentityIfNeeded(publicKey: pubkyProfile.publicKey)
                await retryPendingPaykitEndpointRemoval()
            }
            await refreshIncomingPaykitPaymentRequests(mode: mode, messagePriority: .background)
            guard mode == .full,
                  !Task.isCancelled,
                  scenePhase == .active,
                  network.isConnected,
                  PaykitFeatureFlags.isUIEnabled,
                  let session, session == pubkyProfile.currentSession,
                  !app.showDrawer,
                  sheets.activeSheetConfiguration == nil,
                  !sheets.isReplacingSheet,
                  app.contactPaymentContext == nil
            else { continue }
            await PrivatePaykitService.shared.refreshKnownSavedContactEndpoints(
                wallet: wallet,
                reason: "payment request polling"
            )
        }
    }

    private func presentNextIncomingPaykitPaymentRequest() async {
        guard scenePhase == .active,
              isPinVerified || !settings.pinEnabled,
              PaykitFeatureFlags.isUIEnabled,
              pubkyProfile.currentSession != nil,
              !app.showDrawer,
              sheets.activeSheetConfiguration == nil || canRetryIncomingPaymentRequestPreparation,
              !sheets.isReplacingSheet,
              app.contactPaymentContext == nil
        else { return }

        var shouldPresentNextRequest = true
        let attemptedPresentation = await paykitPaymentRequestManager.presentRequests { requests in
            guard sheets.activeSheetConfiguration == nil || canRetryIncomingPaymentRequestPreparation,
                  !sheets.isReplacingSheet, app.contactPaymentContext == nil
            else { return }
            for request in requests {
                guard paykitPaymentRequestManager.isCurrentPresentation(request) else { return }
                let preparation: IncomingPaykitPaymentRequestPreparation
                if let current = incomingPaymentRequestPreparation, current.ownsSheet(sheets) {
                    guard current.request?.id == request.id else { continue }
                    preparation = current
                } else {
                    preparation = IncomingPaykitPaymentRequestPreparation(request: request, session: pubkyProfile.currentSession)
                    incomingPaymentRequestPreparation = preparation
                    sheets.showSheet(.send, data: SendConfig(view: .confirm, preparation: preparation, onDismiss: {
                        if preparation.resolvedRoute == nil, scenePhase == .active,
                           preparation.matchesSession(pubkyProfile.currentSession), let request = preparation.request
                        {
                            paykitPaymentRequestManager.dismissPreparingRequest(request)
                        }
                        preparation.clear()
                    }))
                }
                defer {
                    if preparation.resolvedRoute == nil {
                        if !Task.isCancelled, preparation.ownsSheet(sheets),
                           preparation.matchesSession(pubkyProfile.currentSession),
                           paykitPaymentRequestManager.isWaitingForPresentationRetry(request)
                        {
                            if let context = preparation.paymentContext, app.ownsContactPaymentContext(context) {
                                app.resetSendState()
                                wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                            }
                            preparation.paymentContext = nil
                        } else {
                            endIncomingPaymentRequestPreparation(preparation)
                        }
                    }
                }
                do {
                    let result = try await preparation.whilePreparing {
                        try await PrivatePaykitService.shared.beginPaymentRequest(request)
                    }
                    guard isCurrentIncomingPaymentRequestPreparation(preparation), app.contactPaymentContext == nil
                    else { return }
                    if case .privateLinkPending = result {
                        if let feedback = IncomingPaykitPaymentRequestPresentationDispatcher.finishPendingPrivateLink(
                            for: request,
                            with: paykitPaymentRequestManager
                        ) {
                            presentIncomingPaykitPaymentRequestFeedback(feedback, for: request)
                        }
                        return
                    }
                    guard case let .opened(paymentTarget, privatePaymentContext) = result else {
                        deferIncomingPaykitPaymentRequestPresentation(
                            request,
                            reason: result.incomingPaymentRequestFailureReason ?? .resolutionFailed
                        )
                        return
                    }

                    let contactPaymentContext = ContactPaymentContext(
                        publicKey: request.counterparty,
                        privatePaymentContext: privatePaymentContext,
                        incomingPaymentRequest: request
                    )
                    guard app.claimContactPaymentContext(contactPaymentContext) else { return }
                    preparation.paymentContext = contactPaymentContext

                    do {
                        try await preparation.whilePreparing {
                            try await app.handleScannedData(
                                paymentTarget,
                                claimedContactPaymentContext: contactPaymentContext,
                                alternativeOnchainBalanceSats: hwWalletManager.maximumFundingBalanceSats
                            )
                        }
                        guard isCurrentIncomingPaymentRequestPreparation(preparation),
                              app.ownsContactPaymentContext(contactPaymentContext)
                        else {
                            if app.ownsContactPaymentContext(contactPaymentContext) {
                                app.resetSendState()
                                wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                            }
                            return
                        }
                        guard PaymentNavigationHelper.appropriateSendRoute(app: app, currency: currency, settings: settings) != nil else {
                            if app.didRejectScannedPaymentForInsufficientBalance {
                                PaykitPaymentRequestPresentationCoordinator.handleUnavailablePaymentRoute(
                                    request,
                                    app: app,
                                    manager: paykitPaymentRequestManager,
                                    resetWalletSendState: {
                                        wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                                    }
                                )
                            } else {
                                app.resetSendState()
                                wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                                deferIncomingPaykitPaymentRequestPresentation(request, reason: .paymentTargetNotRoutable)
                            }
                            shouldPresentNextRequest = false
                            return
                        }

                        guard isCurrentIncomingPaymentRequestPreparation(preparation) else {
                            app.resetSendState()
                            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                            return
                        }
                    } catch ScanHandlingError.pubkyAuthRequest {
                        guard isCurrentIncomingPaymentRequestPreparation(preparation) else { return }
                        _ = paykitPaymentRequestManager.markPresentedIfPending(request)
                        return
                    } catch is CancellationError {
                        if app.ownsContactPaymentContext(contactPaymentContext) {
                            app.resetSendState()
                            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                        }
                        return
                    } catch {
                        guard app.ownsContactPaymentContext(contactPaymentContext) else { return }
                        guard isCurrentIncomingPaymentRequestPreparation(preparation) else {
                            app.resetSendState()
                            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                            return
                        }
                        app.resetSendState()
                        wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                        if PaykitPaymentRequestPresentationCoordinator.handleAmountMismatch(
                            error,
                            request: request,
                            manager: paykitPaymentRequestManager,
                            showError: { app.toast($0) }
                        ) {
                            shouldPresentNextRequest = false
                            return
                        }
                        deferIncomingPaykitPaymentRequestPresentation(request, reason: .invalidPaymentTarget)
                        return
                    }

                    guard PaykitPaymentRequestPresentationCoordinator.canPresentPreparedRequest(
                        isSceneActive: scenePhase == .active,
                        isUnlocked: isPinVerified || !settings.pinEnabled,
                        context: contactPaymentContext,
                        app: app,
                        resetWalletSendState: {
                            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                        }
                    ) else { return }
                    guard let route = PaymentNavigationHelper.contactPaymentRoute(
                        app: app,
                        currency: currency,
                        settings: settings
                    ), paykitPaymentRequestManager.isCurrentPresentation(request)
                    else {
                        app.resetSendState()
                        wallet.resetSendState(speed: settings.defaultTransactionSpeed)
                        deferIncomingPaykitPaymentRequestPresentation(request, reason: .paymentTargetNotRoutable)
                        return
                    }
                    _ = preparation.complete(
                        route: route,
                        manager: paykitPaymentRequestManager,
                        session: pubkyProfile.currentSession,
                        app: app,
                        sheets: sheets
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrentIncomingPaymentRequestPreparation(preparation) else { return }
                    deferIncomingPaykitPaymentRequestPresentation(request, reason: .resolutionFailed)
                    return
                }
            }
        }

        guard attemptedPresentation,
              shouldPresentNextRequest,
              paykitPaymentRequestManager.requestedPresentationId != nil ||
              !paykitPaymentRequestManager.requestsForPresentation().isEmpty,
              sheets.activeSheetConfiguration == nil,
              !sheets.isReplacingSheet,
              app.contactPaymentContext == nil
        else { return }
        scheduleNextIncomingPaykitItemPresentation()
    }

    private func isCurrentIncomingPaymentRequestPreparation(_ preparation: IncomingPaykitPaymentRequestPreparation) -> Bool {
        scenePhase == .active && (isPinVerified || !settings.pinEnabled) && PaykitFeatureFlags.isUIEnabled &&
            !app.showDrawer && preparation.ownsSheet(sheets) && preparation.visibleRequest(
                manager: paykitPaymentRequestManager,
                session: pubkyProfile.currentSession,
                paymentContext: app.contactPaymentContext
            ) != nil
    }

    private var canRetryIncomingPaymentRequestPreparation: Bool {
        guard let preparation = incomingPaymentRequestPreparation, preparation.resolvedRoute == nil else { return false }
        return isCurrentIncomingPaymentRequestPreparation(preparation)
    }

    private var isIncomingPaymentRequestPreparationInvalid: Bool {
        guard let preparation = incomingPaymentRequestPreparation else { return false }
        if preparation.resolvedRoute != nil { return !preparation.ownsSheet(sheets) }
        return !isCurrentIncomingPaymentRequestPreparation(preparation)
    }

    private func endIncomingPaymentRequestPreparation(_ preparation: IncomingPaykitPaymentRequestPreparation) {
        let context = preparation.paymentContext
        preparation.clear()
        if let context, app.ownsContactPaymentContext(context) {
            app.resetSendState()
            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
        }
        if preparation.ownsSheet(sheets) {
            sheets.hideSheet(reason: "Incoming payment request preparation ended")
        }
        if incomingPaymentRequestPreparation === preparation {
            incomingPaymentRequestPreparation = nil
        }
    }

    private func scheduleNextIncomingPaykitItemPresentation() {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, sheets.activeSheetConfiguration == nil, !sheets.isReplacingSheet else { return }
            await presentNextIncomingPaykitItem()
        }
    }

    private func deferIncomingPaykitPaymentRequestPresentation(
        _ request: PaykitPaymentRequest,
        reason: IncomingPaykitPaymentRequestFailureReason
    ) {
        presentIncomingPaykitPaymentRequestFeedback(
            IncomingPaykitPaymentRequestPresentationDispatcher.feedback(
                deferring: request,
                reason: reason,
                with: paykitPaymentRequestManager
            ),
            for: request
        )
    }

    private var incomingPaykitPaymentRequestPresentationState: IncomingPaykitPaymentRequestPresentationState {
        IncomingPaykitPaymentRequestPresentationState(paykitPaymentRequestManager)
    }

    private func handleIncomingPaykitPaymentRequestPresentationStateChange(
        from previous: IncomingPaykitPaymentRequestPresentationState,
        to current: IncomingPaykitPaymentRequestPresentationState
    ) {
        for dispatch in IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: previous,
            to: current,
            manager: paykitPaymentRequestManager
        ) {
            switch dispatch {
            case let .presentFeedback(feedback, request):
                presentIncomingPaykitPaymentRequestFeedback(feedback, for: request)
            case .presentNext:
                Task { await presentNextIncomingPaykitItem() }
            }
        }
    }

    private func presentIncomingPaykitPaymentRequestFeedback(
        _ feedback: IncomingPaykitPaymentRequestPresentationFeedback,
        for request: PaykitPaymentRequest
    ) {
        if let diagnosticMessage = feedback.diagnosticMessage(for: request) {
            Logger.warn(diagnosticMessage, context: "AppScene")
        }

        guard let toast = feedback.toast else { return }
        app.toast(
            type: toast.isInformational ? .info : .error,
            title: t(toast.titleKey),
            description: t(toast.descriptionKey),
            accessibilityIdentifier: toast.accessibilityIdentifier
        )
    }

    private func handlePendingPaykitSubscriptionNotification() async {
        guard PaykitFeatureFlags.isUIEnabled,
              wallet.walletExists == true,
              pubkyProfile.authState == .authenticated
        else { return }
        guard let target = PaykitSubscriptionNotificationTargetStore.load() else { return }
        guard let session = pubkyProfile.currentSession else { return }
        guard target.matches(identity: session.publicKey) else {
            PaykitSubscriptionNotificationTargetStore.clear()
            return
        }
        guard IncomingPaykitPaymentRequestPresentationDispatcher.canHandleSubscriptionNotification(
            manager: paykitPaymentRequestManager, app: app, sheets: sheets
        ) else { return }
        guard await refreshIncomingPaykitPaymentRequests(presentItems: false, mode: .stored),
              !Task.isCancelled,
              pubkyProfile.currentSession == session,
              PaykitSubscriptionNotificationTargetStore.load() == target,
              IncomingPaykitPaymentRequestPresentationDispatcher.canHandleSubscriptionNotification(
                  manager: paykitPaymentRequestManager, app: app, sheets: sheets
              )
        else { return }
        guard let request = paykitPaymentRequestManager.pendingRequests.first(where: target.matches) else {
            if paykitPaymentRequestManager.historyRequests.contains(where: target.matches) {
                PaykitSubscriptionNotificationTargetStore.clear()
            } else if paykitPaymentRequestManager.hasDismissedSubscriptionPayment(matching: target) {
                PaykitSubscriptionNotificationTargetStore.clear()
            } else if !paykitPaymentRequestManager.subscriptions.contains(where: {
                $0.paymentRequestId == target.paymentRequestId &&
                    PubkyPublicKeyFormat.matches($0.counterparty, target.counterparty) &&
                    $0.isActive(at: SubscriptionClock.subscriptionNow())
            }) {
                PaykitSubscriptionNotificationTargetStore.clear()
            }
            return
        }

        guard paykitPaymentRequestManager.requestPresentation(request) else { return }
        PaykitSubscriptionNotificationTargetStore.clear()
        await presentNextIncomingPaykitPaymentRequest()
    }

    private func presentNextIncomingPaykitItem() async {
        guard scenePhase == .active,
              isPinVerified || !settings.pinEnabled
        else { return }
        await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
            manager: paykitPaymentRequestManager,
            sheets: sheets,
            canRetryPreparation: canRetryIncomingPaymentRequestPreparation,
            handleSubscriptionNotification: handlePendingPaykitSubscriptionNotification,
            presentPaymentRequest: presentNextIncomingPaykitPaymentRequest
        )
    }

    private func retryPendingPaykitEndpointRemoval() async {
        await ContactPaymentsService.reconcilePendingEndpoints {
            let privateCleanupPending = UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey)
            await PrivatePaykitService.shared.retryPendingEndpointReconciliation(
                wallet: wallet,
                savedPublicKeys: contactsManager.contacts.map(\.publicKey)
            )
            if privateCleanupPending, !UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey) {
                PublicPaykitService.setCleanupPending(true)
            }

            if PublicPaykitService.isCleanupPending {
                do {
                    switch PublicPaykitService.pendingReconciliationMode() {
                    case .publishEndpoints:
                        try await PublicPaykitService.syncCurrentPublishedEndpoints(wallet: wallet)
                    case .removePublishedState:
                        try await PublicPaykitService.removePublishedEndpoints()
                        try await PublicPaykitService.syncPaykitApp()
                    }
                    PublicPaykitService.setCleanupPending(false)
                } catch {
                    Logger.warn("Failed to reconcile public Paykit state: \(error)", context: "AppScene")
                }
            }
        }
    }

    /// Removes all delivered notifications from Notification Center so the app can handle them when opened.
    private func clearDeliveredNotifications() async {
        let center = UNUserNotificationCenter.current()
        let deliveredNotifications = await center.deliveredNotifications()
        guard !deliveredNotifications.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: deliveredNotifications.map(\.request.identifier))
    }

    /// Feed both vendors' device snapshots into the watch-only manager. This is the only link between
    /// the vendor managers and it, kept in the composition root so none of them references another.
    private func pushHardwareDevices() {
        let connected: (deviceId: String, walletId: String?)? = if let trezorDevice = trezorManager.connectedDevice {
            (trezorDevice.id, trezorManager.connectedWalletId)
        } else if let jadeDevice = jadeManager.connected {
            (jadeDevice.id, jadeDevice.walletId)
        } else {
            nil
        }
        hwWalletManager.updateDevices(
            knownDevices: (trezorManager.knownDevices + jadeManager.knownDevices).sorted { $0.lastConnectedAt > $1.lastConnectedAt },
            connectedDeviceId: connected?.deviceId,
            connectedWalletId: connected?.walletId
        )
    }

    private func handleNetworkChange(_ isConnected: Bool) {
        Logger.info("Network changed: \(isConnected ? "connected" : "disconnected")", context: "AppScene")

        app.toast(
            type: isConnected ? .success : .warning,
            title: isConnected ? t("other__connection_back_title") : t("other__connection_issue"),
            description: isConnected ? t("other__connection_back_msg") : t("other__connection_issue_explain")
        )

        if isConnected {
            guard wallet.walletExists == true else { return }

            if retryPendingWalletRestoreIfNeeded() {
                return
            }

            // Refresh currency rates when network is restored - critical for UI
            // to display balances (MoneyText returns "0" if rates are nil)
            Task {
                async let sessionRecovery: Void = pubkyProfile.restoreSessionIfNeeded()
                await currency.refresh()
                await sessionRecovery
                if scenePhase == .active {
                    await PubkyService.republishIdentityIfNeeded(publicKey: pubkyProfile.publicKey)
                }
                await retryPendingPaykitEndpointRemoval()
                if PaykitFeatureFlags.isUIEnabled {
                    let contactPublicKeys = contactsManager.contacts.map(\.publicKey)
                    await PrivatePaykitService.shared.prepareSavedContacts(
                        contactPublicKeys,
                        wallet: wallet
                    )
                }
                await refreshIncomingPaykitPaymentRequests()
            }

            // Restart node if necessary (e.g. create/restore was skipped due to offline)
            switch wallet.nodeLifecycleState {
            case .stopped, .initializing, .errorStarting:
                Logger.info("Network restored, retrying wallet start...", context: "AppScene")
                Task {
                    await startWallet()
                }
            default:
                break
            }
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
            description: tPlural("settings__backup__failed_message", arguments: ["interval": intervalMinutes])
        )
    }
}
