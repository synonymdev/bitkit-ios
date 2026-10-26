import SwiftUI

enum SendRetryRoute: Hashable {
    case confirm
    case quickpay
    case lnurlPayConfirm

    var sendRoute: SendRoute {
        switch self {
        case .confirm: .confirm
        case .quickpay: .quickpay
        case .lnurlPayConfirm: .lnurlPayConfirm
        }
    }
}

struct SendFailureContext: Hashable {
    let message: String?
    let retryRoute: SendRetryRoute
    let resetRoutingCachesOnRetry: Bool
    let failureType: String
    let paymentRequest: String?
    let routingCacheResetAttempted: Bool
    let incomingPaymentRequestId: PaykitPaymentRequest.ID?
    let isInitialSubscriptionPayment: Bool

    init(
        error: Error,
        retryRoute: SendRetryRoute,
        routingCacheResetAttempted: Bool = false,
        paymentRequest: String? = nil,
        contactPaymentContext: ContactPaymentContext? = nil
    ) {
        let shouldResetRoutingCaches = shouldResetRoutingCachesOnRetry(for: error)

        isInitialSubscriptionPayment = contactPaymentContext?.isInitialSubscriptionPayment == true
        message = isInitialSubscriptionPayment
            ? t("subscriptions__first_payment_failed_description")
            : sendFailureMessage(for: error)
        self.retryRoute = retryRoute
        resetRoutingCachesOnRetry = shouldResetRoutingCaches && !routingCacheResetAttempted
        failureType = sendFailureType(for: error)
        self.paymentRequest = paymentRequest
        self.routingCacheResetAttempted = routingCacheResetAttempted
        incomingPaymentRequestId = contactPaymentContext?.incomingPaymentRequest?.id
    }
}

enum SendRoute: Hashable {
    case options
    case contact
    case comingSoon
    case manual
    case amount
    case usdt(recipient: String, amount: String)
    case usdtAddress(recipient: String, amount: String)
    case utxoSelection
    case confirm
    case hardwareSign
    case feeRate
    case feeCustom
    case tag
    case quickpay
    case pin
    case pending(
        paymentHash: String?,
        retryRoute: SendRetryRoute,
        paymentRequest: String?,
        paykitPaymentRequestId: PaykitPaymentRequest.ID? = nil
    )
    case onchainPending(OnchainSendPendingContext)
    case onchainOperationPending(OnchainSendPendingContext, requestId: PaykitPaymentRequest.ID?)
    case hardwarePending(requestId: PaykitPaymentRequest.ID, walletId: String, transactionId: String, paymentIdentity: String?)
    case success(paymentId: String, walletId: String = WalletScope.default)
    case failure(SendFailureContext)
    case lnurlPayAmount
    case lnurlPayConfirm
    case lnurlWithdrawAmount
    case lnurlWithdrawConfirm
    case lnurlWithdrawFailure(amount: UInt64)
}

@Observable
final class SendPresentationState {
    var rootRoute: SendRoute
    var rootRouteGeneration = 0
    var navigationPath: [SendRoute] = []
    var rootOverride: SendRoute?
    var quickPaySession = 0
    let quickPayPresentationID = UUID()
    var hasValidatedAfterSync = false
    var incomingPaymentRequest: PaykitPaymentRequest?
    var isSubmittingPayment = false
    var paymentReview: UUID?
    var isReviewingUsdtPayment = false
    var pendingEmbeddedRetryRoute: SendRoute?
    var routingCacheResetAttempted = false
    var syncTimedOut = false
    var isResumingAcceptedOrdinarySend = false
    var pinCheckContinuations: [CheckedContinuation<Bool, Never>] = []
    var setupTask: Task<Void, Never>?
    var usdtDetails: String?
    var isSetupPending = true
    var isFallbackFundingPending = false
    var ownedSendStateGeneration: UUID?
    var didStartSetup = false
    var didFinish = false
    var onDismiss: (() -> Void)?
    @ObservationIgnored var hwSend: HwSendCoordinator?
    @ObservationIgnored private(set) var lnurlAmountInput: AmountInputViewModel?
    @ObservationIgnored private var lnurlAmountGeneration: UUID?

    @MainActor
    func amountInput(for generation: UUID) -> AmountInputViewModel {
        if lnurlAmountGeneration == generation, let lnurlAmountInput {
            return lnurlAmountInput
        }
        let input = AmountInputViewModel()
        lnurlAmountInput = input
        lnurlAmountGeneration = generation
        return input
    }

    init(initialRoute: SendRoute) {
        rootRoute = initialRoute
    }
}

struct SendConfig {
    let initialRoute: SendRoute
    let hardwareWalletId: String?
    let preparation: IncomingPaykitPaymentRequestPreparation?
    let onDismiss: (() -> Void)?

    init(
        view: SendRoute = .options,
        hardwareWalletId: String? = nil,
        preparation: IncomingPaykitPaymentRequestPreparation? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        initialRoute = view
        self.hardwareWalletId = hardwareWalletId
        self.preparation = preparation
        self.onDismiss = onDismiss
    }
}

struct SendSheetItem: SheetItem {
    let state: SendPresentationState
    let id: UUID
    let presentationID: UUID?
    let size: SheetSize = .large
    let initialRoute: SendRoute
    let hardwareWalletId: String?
    let preparation: IncomingPaykitPaymentRequestPreparation?

    init(
        presentationID: UUID? = nil,
        state: SendPresentationState? = nil,
        initialRoute: SendRoute = .options,
        hardwareWalletId: String? = nil,
        preparation: IncomingPaykitPaymentRequestPreparation? = nil
    ) {
        self.presentationID = presentationID
        self.state = state ?? SendPresentationState(initialRoute: initialRoute)
        id = presentationID ?? UUID()
        self.initialRoute = initialRoute
        self.hardwareWalletId = hardwareWalletId
        self.preparation = preparation
    }
}

struct SendSheet: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @Environment(PaykitPaymentRequestManager.self) private var paykitPaymentRequestManager
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(TrezorManager.self) private var trezorManager

    let config: SendSheetItem
    let isEmbedded: Bool

    @State private var flow: SendPresentationState
    @State private var hwSend: HwSendCoordinator

    private var isCurrentPresentation: Bool {
        guard let presentationID = config.presentationID else {
            return sheets.activeSheetConfiguration?.id == (isEmbedded ? .subscription : .send)
        }
        return sheets.activeSheetConfiguration?.presentationID == presentationID
    }

    init(config: SendSheetItem, isEmbedded: Bool = false) {
        self.config = config
        self.isEmbedded = isEmbedded
        _flow = State(initialValue: config.state)
        let hwSend = config.state.hwSend ?? HwSendCoordinator(walletId: config.hardwareWalletId)
        config.state.hwSend = hwSend
        _hwSend = State(initialValue: hwSend)
    }

    private var currentRoot: SendRoute {
        flow.rootOverride ?? flow.rootRoute
    }

    private var isReviewingPayment: Bool {
        guard isCurrentPresentation, !flow.didFinish, scenePhase != .background,
              config.preparation?.isSuspendedForAppLock != true else { return false }
        switch flow.navigationPath.last ?? currentRoot {
        case .confirm, .pin, .hardwareSign: return true
        case .usdt, .usdtAddress: return flow.isReviewingUsdtPayment
        default: return false
        }
    }

    private func updatePaymentReview(_ reviewing: Bool) {
        if reviewing, flow.paymentReview == nil {
            if !isEmbedded {
                flow.onDismiss = { cleanup() }
            }
            flow.paymentReview = PaykitPaymentActivity.shared.beginReview()
        } else if !reviewing, let paymentReview = flow.paymentReview {
            PaykitPaymentActivity.shared.endReview(paymentReview)
            flow.paymentReview = nil
        }
    }

    private var isPreparingRequest: Bool {
        config.preparation != nil && flow.incomingPaymentRequest == nil
    }

    private var isMissingLnurlPayData: Bool {
        guard app.lnurlPayData == nil, !app.isHandlingScannedData, !flow.isSubmittingPayment else { return false }
        return Self.isLnurlPayRoute(flow.navigationPath.last ?? currentRoot)
    }

    private static func isLnurlPayRoute(_ route: SendRoute) -> Bool {
        route == .lnurlPayAmount || route == .lnurlPayConfirm
    }

    private var shouldDismissUnavailableRequest: Bool {
        guard let request = flow.incomingPaymentRequest else { return false }
        return Self.shouldDismissUnavailableRequest(
            root: currentRoot,
            path: flow.navigationPath,
            isSubmittingPayment: flow.isSubmittingPayment,
            isAvailable: paykitPaymentRequestManager.pendingRequests.contains(where: { $0.id == request.id }) ||
                paykitPaymentRequestManager.isApprovedForPayment(request)
        )
    }

    static func shouldDismissUnavailableRequest(root: SendRoute, path: [SendRoute], isSubmittingPayment: Bool, isAvailable: Bool) -> Bool {
        guard !isAvailable, !isSubmittingPayment else { return false }
        switch path.last ?? root {
        case .confirm, .lnurlPayConfirm, .amount, .utxoSelection, .feeRate, .feeCustom, .tag, .pin:
            return true
        default:
            return false
        }
    }

    /// How long the sync overlay may wait for channels to become usable before falling back
    private static let syncTimeoutSeconds: TimeInterval = 20

    /// Show sync overlay when node is not ready for payments
    /// For lightning: need node running AND at least one usable channel (peer connected).
    /// If there are no channels at all, we should NOT wait behind the sync UI – that's a capacity issue, not a sync issue.
    /// For onchain: only need node running.
    private var shouldShowSyncOverlay: Bool {
        if isPreparingRequest || hwSend.isActive || flow.isResumingAcceptedOrdinarySend || app.paykitUsesUsdt ||
            (app.contactPaymentContext?.requiresAssetSelection == true && currentRoot == .amount && flow.navigationPath.isEmpty)
        {
            return false
        }

        // Node must be running
        guard wallet.nodeLifecycleState == .running else { return true }

        // For lightning payments, also need usable channels (peer connected)
        let isLightningPayment = app.scannedLightningInvoice != nil
            || app.lnurlPayData != nil
            || app.selectedWalletToPayFrom == .lightning

        if isLightningPayment {
            // If there are no channels at all, don't show the sync overlay –
            // there is nothing to \"sync into\". Let validation/UX handle this as
            // an \"insufficient capacity / no channels\" case instead of a sync wait.
            let hasAnyChannels = (wallet.channels?.isEmpty == false) || wallet.channelCount > 0
            guard hasAnyChannels else { return false }

            // We have channels but none are usable yet → show sync overlay
            return !wallet.hasUsableChannels
        }

        return false
    }

    /// Identity for the sync timeout task. The timer only counts down while the overlay is visible
    /// and the device is online (while offline, `offlineSheetOverlay` covers the sheet and a timeout
    /// would act on stale state). Node readiness is part of the identity so the window restarts when
    /// the node reaches `.running` mid-wait and the timeout can still fall back with fresh balances.
    private struct SyncTimeoutPhase: Equatable {
        let isActive: Bool
        let isNodeRunning: Bool
    }

    private var syncTimeoutPhase: SyncTimeoutPhase {
        SyncTimeoutPhase(
            isActive: shouldShowSyncOverlay && network.isConnected,
            isNodeRunning: wallet.nodeLifecycleState == .running
        )
    }

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                Sheet(id: .send, data: config) {
                    content
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: shouldShowSyncOverlay)
        .interactiveDismissDisabled(!hwSend.canLeave)
        .sheet(isPresented: reconnectPairingBinding) {
            HardwarePairingSheet(config: HardwarePairingSheetItem())
        }
        .sheet(isPresented: Binding(get: { flow.usdtDetails != nil }, set: {
            if !$0 {
                flow.usdtDetails = nil
            }
        })) {
            if let id = flow.usdtDetails {
                UsdtActivityDetail(transferId: id)
            }
        }
        .offlineSheetOverlay(
            title: t("wallet__send_bitcoin"),
            forceShow: flow.syncTimedOut,
            isEnabled: !isPreparingRequest && !flow.isResumingAcceptedOrdinarySend
        )
        .onChange(of: shouldDismissUnavailableRequest) { _, shouldDismiss in
            guard shouldDismiss else { return }
            sheets.hideSheetIfActive(isEmbedded ? .subscription : .send, reason: "Incoming payment request is no longer available")
        }
        .onChange(of: isReviewingPayment, initial: true) { _, reviewing in
            updatePaymentReview(reviewing)
        }
        .onChange(of: isMissingLnurlPayData, initial: true) { _, isMissing in
            guard isMissing, isCurrentPresentation else { return }
            exitMissingLnurlPayment()
        }
        .onChange(of: shouldShowSyncOverlay, initial: true) { _, isShowing in
            Logger.debug("shouldShowSyncOverlay: \(isShowing) (node: \(wallet.nodeLifecycleState))", context: "SendSheet")
        }
        .onChange(of: app.sendStateGeneration) {
            // External links can decode while this sheet is still open; only adopt our own scans.
            if isCurrentPresentation, let ownerID = app.sendStateOwnerID, ownerID == config.presentationID {
                flow.ownedSendStateGeneration = app.sendStateGeneration
            }
        }
        .task(id: config.preparation?.resolvedRoute) {
            if let preparation = config.preparation {
                guard let route = preparation.resolvedRoute,
                      preparation.ownsResolvedContext(session: pubkyProfile.currentSession, app: app, sheets: sheets)
                else { return }
                preparation.isSuspendedForAppLock = false
                flow.rootRoute = route
            }
            setUpSend()
        }
        .onChange(of: wallet.nodeLifecycleState) { _, state in
            guard !isPreparingRequest else { return }
            // When the node becomes running and we have a scanned invoice, run deferred validation.
            // This covers:
            // - Pure onchain invoices (node was not running at scan time)
            // - Unified invoices where we may need to fall back from lightning to onchain
            // Lightning-first flows where the node was already running are handled in AppViewModel.
            let hasScannedInvoice = app.scannedLightningInvoice != nil
                || app.scannedOnchainInvoice != nil
                || app.lnurlPayData != nil
            guard hasScannedInvoice else { return }

            if state == .running, !flow.hasValidatedAfterSync {
                validatePaymentAfterSync()
            }
        }
        .onChange(of: wallet.hasUsableChannels) { _, hasUsable in
            guard !isPreparingRequest else { return }
            // Only validate if channels just became usable and we have a scanned invoice
            // (Validation already happened in AppViewModel if channels were already usable)
            guard app.hasSendPaymentTarget else { return }

            let isLightningPayment = app.scannedLightningInvoice != nil
                || app.lnurlPayData != nil
                || app.selectedWalletToPayFrom == .lightning

            if isLightningPayment, hasUsable, wallet.nodeLifecycleState == .running, !flow.hasValidatedAfterSync {
                validatePaymentAfterSync()
            }
        }
        .task(id: syncTimeoutPhase) {
            // Bound the sync overlay wait so a peer that never connects can't leave the user
            // waiting indefinitely (the onChange above only fires if channels become usable).
            guard syncTimeoutPhase.isActive else {
                // Reset the connection-issues overlay only once the sync wait actually resolves;
                // going offline merely pauses the timer and keeps the timed-out state.
                if !shouldShowSyncOverlay {
                    flow.syncTimedOut = false
                }
                return
            }

            try? await Task.sleep(for: .seconds(Self.syncTimeoutSeconds))
            guard !Task.isCancelled, syncTimeoutPhase.isActive, !flow.hasValidatedAfterSync else { return }

            handleSyncTimeout()
        }
        .onDisappear(perform: cleanup)
    }

    @ViewBuilder
    private var content: some View {
        if isPreparingRequest, config.preparation?.request == nil {
            Color.clear
        } else if shouldShowSyncOverlay {
            SendSyncScreen()
                .transition(.opacity)
        } else {
            NavigationStack(path: $flow.navigationPath) {
                viewForRoute(currentRoot)
                    .navigationDestination(for: SendRoute.self) { route in
                        viewForRoute(route)
                    }
            }
            .id(flow.rootRouteGeneration)
            .transition(.opacity)
        }
    }

    private func cleanup() {
        // Content recreation keeps the presentation, its setup and its payment operation alive.
        guard isEmbedded || !isCurrentPresentation || config.preparation?.isSuspendedForAppLock == true,
              !flow.didFinish else { return }
        updatePaymentReview(false)
        let retainsReview = config.preparation?.retainReviewOnAppLock(
            root: currentRoot,
            path: flow.navigationPath,
            isSubmittingPayment: flow.isSubmittingPayment || PaykitPaymentActivity.shared.isActive,
            isHardwarePayment: hwSend.isActive,
            session: pubkyProfile.currentSession,
            app: app,
            sheets: sheets
        ) == true
        if !isEmbedded, isCurrentPresentation, !retainsReview {
            return
        }
        flow.setupTask?.cancel()
        flow.setupTask = nil
        if retainsReview {
            flow.didStartSetup = false
            flow.isSetupPending = true
            flow.rootOverride = nil
            flow.navigationPath = []
            resolvePinCheck(false)
            return
        }
        flow.didFinish = true
        flow.onDismiss = nil
        config.preparation?.isSuspendedForAppLock = false
        hwSend.cancel()
        if isPreparingRequest {
            return
        }
        // The reset's owner is available synchronously, even before SwiftUI delivers onChange.
        let ownsSendState = flow.ownedSendStateGeneration == app.sendStateGeneration ||
            (app.sendStateOwnerID != nil && app.sendStateOwnerID == config.presentationID)
        if let request = flow.incomingPaymentRequest ?? (ownsSendState ? app.contactPaymentContext?.incomingPaymentRequest : nil) {
            Task { await paykitPaymentRequestManager.finishPayment(request) }
        }
        flow.incomingPaymentRequest = nil
        // A scan may have replaced this send's state before its dismiss animation finishes.
        guard ownsSendState else { return }
        app.resetSendState(ownerID: config.presentationID)
        wallet.resetSendState(speed: settings.defaultTransactionSpeed)
        app.resetQuickPay()
        QuickPayPaymentCoordinator.shared.detach()
    }

    private func setUpSend() {
        guard isCurrentPresentation, !flow.didStartSetup else { return }
        flow.didStartSetup = true
        if !isEmbedded {
            flow.onDismiss = { cleanup() }
        }
        wallet.resetSendState(speed: settings.defaultTransactionSpeed)
        if let walletId = config.hardwareWalletId {
            let balance = hwWalletManager.fundingBalance(walletId: walletId)
            let reserve = HwFundingSigner.feeReserve(
                balanceSats: balance,
                satsPerVByte: wallet.selectedFeeRateSatsPerVByte.map(UInt64.init)
            )
            hwSend.seedAvailable(walletId: walletId, availableSats: balance > reserve ? balance - reserve : 0)
        }
        if let request = app.contactPaymentContext?.incomingPaymentRequest {
            if !tagManager.consumePreservedTags(for: request.id) {
                tagManager.clearSelectedTags()
            }
            guard paykitPaymentRequestManager.markPresentedIfPending(request) else {
                app.resetSendState(ownerID: config.presentationID)
                sheets.hideSheetIfActive(isEmbedded ? .subscription : .send, reason: "Incoming payment request is no longer available")
                return
            }
            if PaykitSubscriptionNotificationTargetStore.load()?.matches(request) == true {
                PaykitSubscriptionNotificationTargetStore.clear()
            }
            let payment = try? request.payment(
                using: app.paykitPaymentMethod,
                quoteId: app.paykitPaymentTerms?.quoteId
            )
            wallet.sendAmountSats = payment?.amount.asset == .btc ? payment?.amount.atomic : nil
            flow.incomingPaymentRequest = request
        } else {
            tagManager.clearSelectedTags()
        }
        flow.hasValidatedAfterSync = false
        flow.syncTimedOut = false
        if currentRoot == .options {
            app.resetSendState(ownerID: config.presentationID)
        }
        flow.ownedSendStateGeneration = app.sendStateGeneration
        flow.setupTask?.cancel()
        flow.isSetupPending = true
        flow.setupTask = Task {
            defer {
                if !Task.isCancelled {
                    flow.isSetupPending = false
                }
            }
            if flow.incomingPaymentRequest == nil, config.hardwareWalletId == nil,
               currentRoot == .options || app.selectedWalletToPayFrom == .onchain
            {
                do {
                    if let attempt = try await OnchainSendAttemptService.shared.unresolvedAttempt(
                        walletId: OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex)
                    ) {
                        let context = OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid)
                        if attempt.requestId != nil || attempt.orderId != nil || attempt.status != .accepted {
                            flow.hasValidatedAfterSync = true
                            replaceRootRoute(with: .onchainOperationPending(context, requestId: attempt.requestId))
                            return
                        }
                        flow.isResumingAcceptedOrdinarySend = true
                        flow.hasValidatedAfterSync = true
                        app.selectedWalletToPayFrom = .onchain
                        replaceRootRoute(with: Self.acceptedOrdinaryStartupRoute(attempt: attempt))
                        return
                    }
                } catch {
                    Logger.warn("Could not inspect retained on-chain follow-up", context: "SendSheet")
                }
            }
            do {
                try await wallet.loadFeeRateWithRetry(speed: settings.defaultTransactionSpeed)
            } catch is CancellationError {
                return
            } catch {
                Logger.error("Failed to set default fee rate: \(error)")
            }
            if let request = flow.incomingPaymentRequest, app.contactPaymentContext?.requiresAssetSelection != true || app.paykitPaymentTerms != nil {
                guard isCurrentIncomingRequest(request.id), let amount = try? request.payment(
                    using: app.paykitPaymentMethod,
                    quoteId: app.paykitPaymentTerms?.quoteId
                ).amount.atomic,
                    await selectHardwareFundingSourceIfNeeded(amountSats: amount, requestId: request.id),
                    isCurrentIncomingRequest(request.id) else { return }
                if !shouldShowSyncOverlay {
                    validatePaymentAfterSync()
                }
            }
        }
    }

    /// Called when the sync overlay has been visible for `syncTimeoutSeconds` without channels becoming usable.
    /// Unified invoices fall back to onchain; everything else shows the connection-issues screen
    /// (via the forced `offlineSheetOverlay`) and keeps waiting for the peer.
    private func handleSyncTimeout() {
        let canFallBackToOnchain = wallet.nodeLifecycleState == .running
            && app.scannedLightningInvoice != nil
            && app.scannedOnchainInvoice != nil

        if canFallBackToOnchain {
            validatePaymentAfterSync(ignoreChannelWait: true)
        } else {
            flow.syncTimedOut = true
        }
    }

    /// Validates the onchain request amount and balance, showing setup failure feedback when invalid.
    private func validateOnchainBalanceAndDismissIfInsufficient(invoiceAmount: UInt64, onchainBalance: UInt64) -> Bool {
        if app.contactPaymentContext?.incomingPaymentRequest != nil, invoiceAmount < Env.dustLimit {
            showPaymentSetupFailure(
                title: t("wallet__lnurl_pay__error_min__title"),
                description: t(
                    "wallet__lnurl_pay__error_min__description",
                    variables: ["amount": CurrencyFormatter.formatSats(UInt64(Env.dustLimit))]
                ),
                accessibilityIdentifier: "PaymentRequestAmountTooLowToast"
            )
            return false
        }
        if invoiceAmount > 0 {
            guard onchainBalance >= invoiceAmount else {
                let amountNeeded = invoiceAmount - onchainBalance
                showPaymentSetupFailure(
                    title: t("other__pay_insufficient_savings"),
                    description: t(
                        "other__pay_insufficient_savings_amount_description",
                        variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)]
                    ),
                    accessibilityIdentifier: "InsufficientSavingsToast"
                )
                return false
            }
        } else {
            // Zero-amount invoice: user must have some balance to proceed
            guard onchainBalance > 0 else {
                showPaymentSetupFailure(
                    title: t("other__pay_insufficient_savings"),
                    description: t("other__pay_insufficient_savings_description"),
                    accessibilityIdentifier: "InsufficientSavingsToast"
                )
                return false
            }
        }
        return true
    }

    static func acceptedOrdinaryStartupRoute(attempt: OnchainSendAttempt) -> SendRoute {
        .onchainPending(OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid))
    }

    /// Shows insufficient spending toast with amount-specific or generic description
    private func showInsufficientSpendingToast(invoiceAmount: UInt64, spendingBalance: UInt64) {
        let amountNeeded = invoiceAmount > spendingBalance ? invoiceAmount - spendingBalance : 0
        let description = amountNeeded > 0
            ? t("other__pay_insufficient_spending_amount_description", variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)])
            : t("other__pay_insufficient_spending_description")
        showPaymentSetupFailure(
            title: t("other__pay_insufficient_spending"),
            description: description,
            accessibilityIdentifier: "InsufficientSpendingToast"
        )
    }

    private func showPaymentSetupFailure(title: String, description: String, accessibilityIdentifier: String) {
        if let context = app.contactPaymentContext, context.isInitialSubscriptionPayment {
            let error = AppError(message: title, debugMessage: description)
            let failureRoute = SendRoute.failure(SendFailureContext(
                error: error,
                retryRoute: app.lnurlPayData == nil ? .confirm : .lnurlPayConfirm,
                paymentRequest: app.scannedLightningInvoice?.bolt11,
                contactPaymentContext: context
            ))
            if isEmbedded {
                replaceRootRoute(with: failureRoute)
            } else {
                flow.navigationPath.append(failureRoute)
            }
            return
        }

        app.toast(
            type: .error,
            title: title,
            description: description,
            accessibilityIdentifier: accessibilityIdentifier
        )
        sheets.hideSheet()
    }

    private enum PaymentValidationResult {
        case ready
        case waiting
        case failed
    }

    /// Validates payment affordability after sync completes
    /// For lightning: falls back to onchain for unified invoices, shows error for pure lightning invoices
    /// For onchain: validates balance and shows error if insufficient
    /// Pass `ignoreChannelWait: true` to validate even while channels are unusable (sync timeout).
    private func validatePaymentAfterSync(ignoreChannelWait: Bool = false) {
        guard !flow.isResumingAcceptedOrdinarySend else { return }
        let result = performPaymentValidationAfterSync(ignoreChannelWait: ignoreChannelWait)
        guard let route = flow.pendingEmbeddedRetryRoute else { return }

        switch result {
        case .ready:
            flow.pendingEmbeddedRetryRoute = nil
            replaceRootRoute(with: route)
        case .failed:
            flow.pendingEmbeddedRetryRoute = nil
        case .waiting:
            break
        }
    }

    private func performPaymentValidationAfterSync(ignoreChannelWait: Bool) -> PaymentValidationResult {
        if let request = flow.incomingPaymentRequest,
           let proof = paykitPaymentRequestManager.retainedHardwareRetries[request.id],
           proof.retainedHardwareRetry != nil, proof.onchainWalletId == hwSend.walletId,
           proof.onchainAddress == app.scannedOnchainInvoice?.address,
           proof.onchainAmountSats == wallet.sendAmountSats
        {
            // Original signed bytes only; new-payment balance admission does not apply.
            return .ready
        }
        if app
            .paykitUsesUsdt || (app.contactPaymentContext?.requiresAssetSelection == true && currentRoot == .amount && flow.navigationPath.isEmpty)
        {
            flow.hasValidatedAfterSync = true
            return .ready
        }
        let request = app.contactPaymentContext?.incomingPaymentRequest
        let requestedAmount = try? request?.payment(using: app.paykitPaymentMethod, at: Date()).amount.atomic
        if request != nil && requestedAmount == nil {
            app.toast(PaykitAmountError.rateUnavailable)
            return .failed
        }

        if let lnurlPayData = app.lnurlPayData, let requestedAmount {
            let minimumAmount = max(1, lnurlPayData.minSendableSat)
            guard requestedAmount >= minimumAmount else {
                showPaymentSetupFailure(
                    title: t("wallet__lnurl_pay__error_min__title"),
                    description: t(
                        "wallet__lnurl_pay__error_min__description",
                        variables: ["amount": CurrencyFormatter.formatSats(minimumAmount)]
                    ),
                    accessibilityIdentifier: "LnurlPayAmountTooLowToast"
                )
                flow.hasValidatedAfterSync = true
                return .failed
            }
            guard requestedAmount <= lnurlPayData.maxSendableSat else {
                showPaymentSetupFailure(
                    title: t("wallet__lnurl_pay__error_max__title"),
                    description: t("wallet__lnurl_pay__error_max__description"),
                    accessibilityIdentifier: "LnurlPayAmountTooHighToast"
                )
                flow.hasValidatedAfterSync = true
                return .failed
            }
            guard LightningService.shared.canSend(amountSats: requestedAmount) else {
                let spendingBalance = LightningService.shared.balances?.totalLightningBalanceSats ?? 0
                showInsufficientSpendingToast(invoiceAmount: requestedAmount, spendingBalance: spendingBalance)
                flow.hasValidatedAfterSync = true
                return .failed
            }

            flow.hasValidatedAfterSync = true
            return .ready
        }

        // Validate lightning payment if present
        if let lightningInvoice = app.scannedLightningInvoice {
            // For lightning, if we have channels but none are usable yet, wait for them
            // to become usable. If there are no channels at all, or channels are already
            // usable, proceed with validation/fallback.
            // Use channelCount as fallback in case channels array is nil but count is cached
            let hasAnyChannels = (wallet.channels?.isEmpty == false) || wallet.channelCount > 0
            if hasAnyChannels, !wallet.hasUsableChannels, !ignoreChannelWait {
                // We have channels but none usable yet → wait
                return .waiting
            }

            // Check if we can afford the lightning payment
            let paymentAmount = requestedAmount ?? lightningInvoice.amountSatoshis
            let canSend = LightningService.shared.canSend(amountSats: paymentAmount)

            if !canSend {
                // For unified invoices, fall back to onchain
                if let onchainInvoice = app.scannedOnchainInvoice {
                    // Switch to onchain wallet type
                    app.selectedWalletToPayFrom = .onchain
                    app.scannedOnchainInvoice = onchainInvoice
                    app.scannedLightningInvoice = nil

                    let onchainAmount = try? request?.payment(using: app.paykitPaymentMethod).amount.atomic
                    if request != nil && onchainAmount == nil {
                        return .failed
                    }
                    if let onchainAmount {
                        wallet.sendAmountSats = onchainAmount
                    }

                    // Validate onchain balance BEFORE navigating
                    let onchainBalance = max(
                        LightningService.shared.balances?.spendableOnchainBalanceSats ?? 0,
                        hwWalletManager.maximumFundingBalanceSats
                    )
                    guard validateOnchainBalanceAndDismissIfInsufficient(
                        invoiceAmount: onchainAmount ?? onchainInvoice.amountSatoshis,
                        onchainBalance: onchainBalance
                    ) else {
                        flow.hasValidatedAfterSync = true
                        return .failed
                    }

                    // Onchain balance is sufficient → navigate to amount screen
                    // (the sheet may have opened with .confirm or .quickpay route)
                    if requestedAmount == nil {
                        flow.navigationPath = [.amount]
                    }
                    if let onchainAmount {
                        selectHardwareFundingSourceAfterOnchainFallback(amountSats: onchainAmount)
                    }
                    flow.hasValidatedAfterSync = true
                    return .ready
                } else {
                    // For pure lightning invoices, show error toast and dismiss sheet
                    let spendingBalance = LightningService.shared.balances?.totalLightningBalanceSats ?? 0
                    showInsufficientSpendingToast(invoiceAmount: paymentAmount, spendingBalance: spendingBalance)
                    flow.hasValidatedAfterSync = true
                    return .failed
                }
            } else {
                // Lightning payment is valid, we're done
                flow.hasValidatedAfterSync = true
                return .ready
            }
        }

        // Validate onchain payment balance (for pure onchain invoices)
        if let onchainInvoice = app.scannedOnchainInvoice {
            let onchainBalance = max(
                LightningService.shared.balances?.spendableOnchainBalanceSats ?? 0,
                hwWalletManager.maximumFundingBalanceSats
            )
            guard validateOnchainBalanceAndDismissIfInsufficient(
                invoiceAmount: requestedAmount ?? onchainInvoice.amountSatoshis,
                onchainBalance: onchainBalance
            ) else {
                flow.hasValidatedAfterSync = true
                return .failed
            }
        }

        flow.hasValidatedAfterSync = true
        return .ready
    }

    private func requestPinCheck() async -> Bool {
        // Prevent stacking multiple PIN screens if already presented.
        if flow.navigationPath.last != .pin {
            flow.navigationPath.append(.pin)
        }

        return await withCheckedContinuation { continuation in
            flow.pinCheckContinuations.append(continuation)
        }
    }

    private func resolvePinCheck(_ approved: Bool) {
        let continuations = flow.pinCheckContinuations
        flow.pinCheckContinuations.removeAll()
        continuations.forEach { $0.resume(returning: approved) }

        if flow.navigationPath.last == .pin {
            flow.navigationPath.removeLast()
        }
    }

    private func isCurrentIncomingRequest(_ requestId: PaykitPaymentRequest.ID) -> Bool {
        !Task.isCancelled
            && sheets.activeSheetConfiguration?.id == (isEmbedded ? .subscription : .send)
            && flow.incomingPaymentRequest?.id == requestId
            && app.contactPaymentContext?.incomingPaymentRequest?.id == requestId
    }

    private func selectHardwareFundingSourceAfterOnchainFallback(amountSats: UInt64) {
        guard let request = flow.incomingPaymentRequest else { return }
        flow.isFallbackFundingPending = true
        Task {
            _ = await selectHardwareFundingSourceIfNeeded(amountSats: amountSats, requestId: request.id)
            flow.isFallbackFundingPending = false
        }
    }

    private func selectHardwareFundingSourceIfNeeded(
        amountSats: UInt64,
        requestId: PaykitPaymentRequest.ID
    ) async -> Bool {
        guard isCurrentIncomingRequest(requestId) else { return false }
        guard app.selectedWalletToPayFrom == .onchain,
              let invoice = app.scannedOnchainInvoice,
              let satsPerVByte = wallet.selectedFeeRateSatsPerVByte
        else { return true }

        if let request = flow.incomingPaymentRequest,
           let proof = try? await PaykitPaymentProofService.shared.retainedHardwarePaymentForRetry(request: request),
           let walletId = proof.onchainWalletId
        {
            guard isCurrentIncomingRequest(requestId), proof.onchainAddress == invoice.address,
                  (try? hwWalletManager.getFundingAccount(walletId: walletId)) != nil
            else { return false }
            hwSend.selectWallet(walletId, initialAvailableSats: hwWalletManager.fundingBalance(walletId: walletId))
            hwSend.seedAvailable(
                walletId: walletId, availableSats: hwWalletManager.fundingBalance(walletId: walletId),
                retainedFeeSats: proof.hardwareMiningFeeSats
            )
            return true
        }

        let savingsAvailable: UInt64?
        do {
            savingsAvailable = try await wallet.calculateMaxSendableAmount(
                address: invoice.address,
                satsPerVByte: satsPerVByte
            )
        } catch is CancellationError {
            return false
        } catch {
            savingsAvailable = nil
            Logger.error(error, context: "SendSheet failed to estimate Savings availability")
        }
        guard isCurrentIncomingRequest(requestId) else { return false }
        if let savingsAvailable, savingsAvailable >= amountSats {
            return true
        }

        var hardwareSources: [(wallet: HwWallet, available: UInt64)] = []
        var hasUnavailableSource = savingsAvailable == nil
        for hardwareWallet in hwWalletManager.wallets {
            do {
                let available = try await hwWalletManager.maxSpendableFunding(
                    walletId: hardwareWallet.walletId,
                    destinationAddress: invoice.address,
                    satsPerVByte: UInt64(satsPerVByte)
                )
                hardwareSources.append((wallet: hardwareWallet, available: available))
            } catch is CancellationError {
                return false
            } catch {
                hasUnavailableSource = true
                Logger.error(error, context: "SendSheet failed to estimate hardware availability")
            }
            guard isCurrentIncomingRequest(requestId) else { return false }
        }
        if let source = hardwareSources
            .filter({ $0.available >= amountSats })
            .max(by: { $0.available < $1.available })
        {
            hwSend.selectWallet(
                source.wallet.walletId,
                initialAvailableSats: source.available
            )
            return true
        }

        // A failed estimate is not proof of insufficient funds. Keep the sheet open so the normal
        // confirmation path can retry instead of rejecting a payable request.
        guard !hasUnavailableSource else { return true }
        let maximumAvailable = max(savingsAvailable ?? 0, hardwareSources.map(\.available).max() ?? 0)
        _ = validateOnchainBalanceAndDismissIfInsufficient(
            invoiceAmount: amountSats,
            onchainBalance: maximumAvailable
        )
        return false
    }

    @ViewBuilder
    private func viewForRoute(_ route: SendRoute) -> some View {
        switch route {
        case .options:
            SendOptionsView(navigationPath: $flow.navigationPath, hwSend: hwSend)
        case .contact:
            SendContactSelectView(navigationPath: $flow.navigationPath, hwSend: hwSend)
        case .comingSoon:
            SendComingSoonView()
        case .manual:
            SendEnterManuallyView(navigationPath: $flow.navigationPath, hwSend: hwSend)
        case .amount:
            SendAmountView(navigationPath: $flow.navigationPath, hwSend: hwSend)
        case let .usdt(recipient, amount):
            UsdtSendView(onDetails: { id in
                flow.usdtDetails = id
            }, initialRecipient: recipient, initialAmount: amount, embedded: true, paymentContext: app.contactPaymentContext,
            sendPayment: { quote in
                guard let context = app.contactPaymentContext else { throw PaykitPaymentRequestError.requestUnavailable }
                let paymentTerms = app.paykitPaymentTerms
                try await PaykitUsdtPaymentService.shared.prepare(context: context, quote: quote, wallet: wallet.usdtWallet,
                                                                  amount: app.paykitReviewedAmount, paymentTerms: paymentTerms)
                guard app.ownsContactPaymentContext(context) else { throw PaykitPaymentRequestError.requestUnavailable }
                try await prepareIncomingPaymentRequest()
                guard app.ownsContactPaymentContext(context) else { throw PaykitPaymentRequestError.requestUnavailable }
                try await PaykitUsdtPaymentService.shared.send(quote, context: context, paymentTerms: paymentTerms, wallet: wallet.usdtWallet) {
                    if let request = context.incomingPaymentRequest {
                        try await paykitPaymentRequestManager.ensurePaymentAllowed(request)
                    }
                    guard app.ownsContactPaymentContext(context) else { throw PaykitPaymentRequestError.requestUnavailable }
                }
            }, onReviewChange: { flow.isReviewingUsdtPayment = $0 },
            onBack: { flow.navigationPath.removeLast() }, onClose: { sheets.hideSheet() })
        case let .usdtAddress(recipient, amount):
            UsdtSendView(onDetails: { id in
                flow.usdtDetails = id
            }, initialRecipient: recipient, initialAmount: amount, hosted: true,
            onReviewChange: { flow.isReviewingUsdtPayment = $0 },
            onBack: { flow.navigationPath.removeLast() }, onClose: { sheets.hideSheet() })
        case .utxoSelection:
            SendUtxoSelectionView(navigationPath: $flow.navigationPath)
        case .confirm:
            SendConfirmationView(
                navigationPath: $flow.navigationPath,
                isSubmittingPayment: $flow.isSubmittingPayment,
                hwSend: hwSend,
                requestPinCheck: requestPinCheck,
                prepareIncomingPaymentRequest: prepareIncomingPaymentRequest,
                routingCacheResetAttempted: flow.routingCacheResetAttempted,
                preparingRequest: isPreparingRequest ? config.preparation?.request : nil,
                amountIsRoot: currentRoot == .amount,
                isSetupPending: flow.isSetupPending || flow.isFallbackFundingPending
            )
        case .hardwareSign:
            let contactContext = app.contactPaymentContext
            let address = app.scannedOnchainInvoice?.address
            let walletId = hwSend.walletId
            let paymentIdentity = pubkyProfile.publicKey
            HwSendSignView(
                navigationPath: $flow.navigationPath,
                hwSend: hwSend,
                contactPaymentRequestId: contactContext?.incomingPaymentRequest?.id,
                contactPaymentIdentity: paymentIdentity,
                prepareContactPayment: { signedTx in
                    try await prepareHardwareContactPayment(
                        context: contactContext,
                        address: address,
                        walletId: walletId,
                        paymentIdentity: paymentIdentity,
                        signedTx: signedTx
                    )
                },
                authorizeContactPayment: {
                    try await authorizeHardwareContactPayment(context: contactContext, paymentIdentity: paymentIdentity)
                },
                completeContactPayment: { txid in
                    await completeHardwareContactPayment(context: contactContext, walletId: walletId, paymentIdentity: paymentIdentity, txid: txid)
                },
                cancelContactPayment: { outcome in
                    await cancelHardwareContactPayment(
                        context: contactContext,
                        walletId: walletId,
                        paymentIdentity: paymentIdentity,
                        outcome: outcome
                    )
                }
            )
        case .feeRate:
            SendFeeRate(navigationPath: $flow.navigationPath, hwSend: hwSend)
        case .feeCustom:
            SendFeeCustom(navigationPath: $flow.navigationPath, hwSend: hwSend)
        case .tag:
            SendTagScreen(navigationPath: $flow.navigationPath)
        case .quickpay:
            SendQuickpay(
                navigationPath: $flow.navigationPath,
                routingCacheResetAttempted: flow.routingCacheResetAttempted,
                replaceQuickPay: replaceQuickPay(with:),
                sessionID: QuickPayPaymentCoordinator.SessionID(
                    presentationID: flow.quickPayPresentationID,
                    sendStateGeneration: app.sendStateGeneration,
                    attempt: flow.quickPaySession
                ),
                isCurrentPresentation: { isCurrentPresentation }
            )
            .id(flow.quickPaySession)
        case .pin:
            SendPinScreen(onCancel: { resolvePinCheck(false) }, onPinVerified: { resolvePinCheck(true) })
        case let .pending(paymentHash, retryRoute, paymentRequest, paykitPaymentRequestId):
            SendPendingScreen(
                paymentHash: paymentHash,
                retryRoute: retryRoute,
                paymentRequest: paymentRequest,
                paykitPaymentRequestId: paykitPaymentRequestId,
                routingCacheResetAttempted: flow.routingCacheResetAttempted,
                navigationPath: $flow.navigationPath
            )
        case let .onchainPending(context):
            SendPendingScreen(
                paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: nil,
                routingCacheResetAttempted: flow.routingCacheResetAttempted, ordinaryPendingContext: context,
                requestPinCheck: requestPinCheck, navigationPath: $flow.navigationPath
            )
        case let .onchainOperationPending(context, requestId):
            SendPendingScreen(
                paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: requestId,
                routingCacheResetAttempted: flow.routingCacheResetAttempted, ordinaryPendingContext: context,
                requestPinCheck: requestPinCheck, navigationPath: $flow.navigationPath
            )
        case let .hardwarePending(requestId, walletId, transactionId, paymentIdentity):
            SendPendingScreen(
                paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: requestId,
                routingCacheResetAttempted: flow.routingCacheResetAttempted,
                hardwareWalletId: walletId, hardwareTransactionId: transactionId,
                hardwarePaymentIdentity: paymentIdentity,
                navigationPath: $flow.navigationPath
            )
        case let .success(paymentId, walletId):
            SendSuccess(
                paymentId: paymentId,
                walletId: walletId,
                isInitialSubscriptionPayment: app.contactPaymentContext?.isInitialSubscriptionPayment == true
            )
        case let .failure(context):
            SendFailure(
                context: context,
                onRetryReady: { didResetRoutingCaches in
                    if didResetRoutingCaches {
                        flow.routingCacheResetAttempted = true
                    }
                    if let requestId = context.incomingPaymentRequestId {
                        await retryIncomingPaymentRequest(
                            requestId,
                            isInitialSubscriptionPayment: context.isInitialSubscriptionPayment
                        )
                    } else {
                        resetNavigationForRetry(context.retryRoute)
                    }
                },
                onSecondaryAction: context.isInitialSubscriptionPayment
                    ? { sheets.hideSheet(reason: "Initial subscription payment deferred") }
                    : nil
            )
        case .lnurlPayAmount:
            LnurlPayAmount(navigationPath: $flow.navigationPath, amountViewModel: flow.amountInput(for: app.sendStateGeneration))
                .id(app.sendStateGeneration)
        case .lnurlPayConfirm:
            LnurlPayConfirm(
                navigationPath: $flow.navigationPath,
                isSubmittingPayment: $flow.isSubmittingPayment,
                requestPinCheck: requestPinCheck,
                prepareIncomingPaymentRequest: prepareIncomingPaymentRequest,
                routingCacheResetAttempted: flow.routingCacheResetAttempted
            )
        case .lnurlWithdrawAmount:
            LnurlWithdrawAmount {
                flow.navigationPath.append(.lnurlWithdrawConfirm)
            }
        case .lnurlWithdrawConfirm:
            LnurlWithdrawConfirm { amount in
                flow.navigationPath.append(.lnurlWithdrawFailure(amount: amount))
            }
        case let .lnurlWithdrawFailure(amount):
            LnurlWithdrawFailure(amount: amount)
        }
    }

    private func prepareIncomingPaymentRequest() async throws {
        try await prepareIncomingPaymentRequest(context: app.contactPaymentContext)
    }

    private func prepareIncomingPaymentRequest(context: ContactPaymentContext?) async throws {
        guard let context,
              let request = context.incomingPaymentRequest
        else { return }
        // A durable USDT attempt must keep its recovery and payment proof on the same rail.
        guard app.paykitUsesUsdt || !PaykitUsdtPaymentService.shared.hasBinding(for: request.id) else {
            throw PaykitPaymentRequestError.operationInProgress
        }

        guard !app.paykitUsesUsdt, let privatePaymentContext = context.privatePaymentContext,
              privatePaymentContext.paymentListVersion != nil
        else {
            try await paykitPaymentRequestManager.prepareForPayment(request)
            return
        }
        try await paykitPaymentRequestManager.prepareForPayment(request) {
            try await PrivatePaykitService.shared.consumePrivatePaymentList(
                publicKey: context.publicKey,
                context: privatePaymentContext,
                attemptId: context.id
            )
        }
    }

    private func prepareHardwareContactPayment(
        context: ContactPaymentContext?,
        address: String?,
        walletId: String?,
        paymentIdentity: String?,
        signedTx: HwFundingSignedTx
    ) async throws {
        guard let request = context?.incomingPaymentRequest else {
            try await prepareIncomingPaymentRequest(context: context)
            return
        }
        guard let address, let walletId, let paymentIdentity,
              PubkyPublicKeyFormat.matches(pubkyProfile.publicKey, paymentIdentity)
        else { throw PaykitPaymentRequestError.requestUnavailable }
        _ = try hwWalletManager.getFundingAccount(walletId: walletId)

        let paymentTerms = app.paykitPaymentTerms
        let endpointIdentifier = PublicPaykitService.onchainMethodId(for: address).rawValue
        guard let privateContext = context?.privatePaymentContext else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        try await PaykitPaymentProofService.shared.prepare(
            request: request,
            paymentAppId: privateContext.paymentAppId(for: endpointIdentifier),
            paymentEndpointIdentifier: endpointIdentifier,
            kind: .onchain,
            paymentTerms: paymentTerms
        )
        let previousVersion = await PrivatePaykitService.shared.consumedPaymentListVersion(publicKey: request.counterparty, attemptId: context?.id)
        do {
            try await prepareIncomingPaymentRequest(context: context)
            guard context.map(app.ownsContactPaymentContext) == true, !request.isExpired(at: Date()),
                  signedTx.totalSpent >= signedTx.miningFeeSats,
                  paymentTerms != nil || request.amount.asset == .btc,
                  request.acceptsPaymentAmount(
                      signedTx.totalSpent - signedTx.miningFeeSats,
                      method: PublicPaykitService.onchainMethodId(for: address),
                      paymentTerms: paymentTerms
                  )
            else { throw PaykitPaymentRequestError.amountMismatch }
            try await PaykitPaymentProofService.shared.markOnchainPaymentStarted(
                request, address: address, hardwareWalletId: walletId, paymentIdentity: paymentIdentity,
                signedTx: signedTx, privatePaymentListVersion: privateContext.paymentListVersion,
                previousPrivatePaymentListVersion: previousVersion
            )
        } catch {
            _ = await paykitPaymentRequestManager.paymentRequestForRetry(request.id)
            await context?.resolvePrivatePaymentListConsumption(.definitePreBroadcastFailure)
            await PaykitPaymentProofService.shared.cancelPreparation(request)
            throw error
        }
    }

    private func authorizeHardwareContactPayment(context: ContactPaymentContext?, paymentIdentity: String?) async throws {
        guard let request = context?.incomingPaymentRequest else { return }
        guard PubkyPublicKeyFormat.matches(pubkyProfile.publicKey, paymentIdentity)
        else { throw PaykitPaymentRequestError.requestUnavailable }
        if try await PaykitPaymentProofService.shared.retainedHardwarePaymentForRetry(request: request) != nil,
           !paykitPaymentRequestManager.isApprovedForPayment(request)
        {
            // Fresh authorization for the original signed payment; its list version is already retained.
            try await paykitPaymentRequestManager.prepareForPayment(request)
        }
        try await paykitPaymentRequestManager.ensurePaymentAllowed(request)
    }

    private func completeHardwareContactPayment(context: ContactPaymentContext?, walletId: String?, paymentIdentity: String?,
                                                txid: String) async -> Bool
    {
        guard let request = context?.incomingPaymentRequest else { return true }
        guard let walletId, let paymentIdentity else { return false }

        let verified = await PaykitPaymentProofService.shared.completeHardwareOnchainPayment(
            request,
            paymentIdentity: paymentIdentity,
            walletId: walletId,
            txid: txid
        )
        await context?.resolvePrivatePaymentListConsumption(verified ? .succeeded : .uncertain)
        return verified
    }

    private func cancelHardwareContactPayment(context: ContactPaymentContext?, walletId: String?, paymentIdentity: String?,
                                              outcome: PrivatePaymentListSendOutcome) async
    {
        await Self.cancelHardwareContactPayment(
            context, outcome: outcome, app: app, manager: paykitPaymentRequestManager,
            hardwareWalletId: walletId, paymentIdentity: paymentIdentity
        )
    }

    @MainActor
    static func cancelHardwareContactPayment(
        _ context: ContactPaymentContext?,
        outcome: PrivatePaymentListSendOutcome,
        app: AppViewModel,
        manager: PaykitPaymentRequestManager,
        privatePaykitService: PrivatePaykitService = .shared,
        paymentProofService: PaykitPaymentProofService = .shared,
        hardwareWalletId: String? = nil,
        paymentIdentity: String? = nil
    ) async {
        guard let request = context?.incomingPaymentRequest else { return }
        await context?.resolvePrivatePaymentListConsumption(outcome, service: privatePaykitService)
        guard outcome == .definitePreBroadcastFailure else { return }
        if let hardwareWalletId {
            guard let paymentIdentity else { return }
            await paymentProofService.cancelHardwarePaymentBeforeDispatch(
                request, paymentIdentity: paymentIdentity, walletId: hardwareWalletId,
                privatePaykitService: privatePaykitService
            )
        } else {
            await paymentProofService.failOnchainPayment(request)
        }
        await paymentProofService.cancelPreparation(request)
        if let context {
            await restoreHardwareContactPaymentForRetry(context, app: app, manager: manager)
        }
    }

    @MainActor
    static func restoreHardwareContactPaymentForRetry(
        _ context: ContactPaymentContext,
        app: AppViewModel,
        manager: PaykitPaymentRequestManager
    ) async {
        guard let request = context.incomingPaymentRequest,
              let retriedRequest = await manager.paymentRequestForRetry(request.id),
              app.ownsContactPaymentContext(context)
        else { return }

        app.contactPaymentContext = ContactPaymentContext(
            id: context.id,
            publicKey: context.publicKey,
            privatePaymentContext: context.privatePaymentContext,
            incomingPaymentRequest: retriedRequest,
            isInitialSubscriptionPayment: context.isInitialSubscriptionPayment,
            endpoints: context.endpoints
        )
    }

    private func replaceQuickPay(with route: SendRoute) {
        app.resetQuickPay()
        let next = PaymentNavigationHelper.replacingQuickPay(in: flow.navigationPath, root: currentRoot, with: route)
        flow.rootOverride = next.root == config.initialRoute ? nil : next.root
        flow.navigationPath = next.path
    }

    private var reconnectPairingBinding: Binding<Bool> {
        Binding(
            get: { trezorManager.showPairingCode },
            set: { isPresented in
                if !isPresented, trezorManager.showPairingCode {
                    trezorManager.cancelPairingCode()
                }
            }
        )
    }

    private func resetNavigationForRetry(_ retryRoute: SendRetryRoute) {
        let route = retryRoute.sendRoute
        if retryRoute == .quickpay {
            app.resetQuickPay()
            flow.quickPaySession += 1
        }
        if route == config.initialRoute || currentRoot == route {
            if route == config.initialRoute {
                flow.rootOverride = nil
            }
            flow.navigationPath = []
            return
        }

        flow.navigationPath = [route]
    }

    private func exitMissingLnurlPayment() {
        if !Self.isLnurlPayRoute(currentRoot), let index = flow.navigationPath.firstIndex(where: Self.isLnurlPayRoute) {
            flow.navigationPath.removeSubrange(index...)
        } else {
            sheets.hideSheetIfActive(isEmbedded ? .subscription : .send, reason: "LNURL payment data is no longer available")
        }
    }

    private func replaceRootRoute(with route: SendRoute) {
        flow.rootOverride = nil
        flow.rootRoute = route
        flow.navigationPath = []
        flow.rootRouteGeneration &+= 1
    }

    @MainActor
    private func retryIncomingPaymentRequest(
        _ requestId: PaykitPaymentRequest.ID,
        isInitialSubscriptionPayment: Bool
    ) async {
        guard let request = await paykitPaymentRequestManager.paymentRequestForRetry(requestId) else {
            app.toast(PaykitPaymentRequestError.requestUnavailable)
            return
        }

        if isEmbedded, isInitialSubscriptionPayment {
            await retryEmbeddedInitialSubscriptionPayment(request)
            return
        }

        app.resetSendState(ownerID: config.presentationID)
        wallet.resetSendState(speed: settings.defaultTransactionSpeed)
        _ = paykitPaymentRequestManager.requestPresentation(request)
        sheets.hideSheet(reason: "Retrying incoming payment request with fresh private payment details")
    }

    @MainActor
    private func retryEmbeddedInitialSubscriptionPayment(_ request: PaykitPaymentRequest) async {
        guard sheets.activeSheetConfiguration?.id == .subscription else { return }

        app.resetSendState(ownerID: config.presentationID)
        wallet.resetSendState(speed: settings.defaultTransactionSpeed)

        let resolution: PublicPaykitPaymentLaunchResult
        do {
            resolution = try await PrivatePaykitService.shared.beginPaymentRequestWaitingForUpdatedList(request)
        } catch {
            showEmbeddedInitialPaymentFailure(request, error: error)
            return
        }

        guard case let .opened(paymentTarget, privatePaymentContext, endpoints) = resolution else {
            showEmbeddedInitialPaymentFailure(request, error: PaykitPaymentRequestError.requestUnavailable)
            return
        }
        guard sheets.activeSheetConfiguration?.id == .subscription else { return }

        let context = ContactPaymentContext(
            publicKey: request.counterparty,
            privatePaymentContext: privatePaymentContext,
            incomingPaymentRequest: request,
            isInitialSubscriptionPayment: true, endpoints: endpoints
        )
        guard app.claimContactPaymentContext(context) else {
            app.toast(PaykitPaymentRequestError.operationInProgress)
            return
        }

        do {
            try await app.handleScannedData(
                paymentTarget,
                claimedContactPaymentContext: context,
                alternativeOnchainBalanceSats: hwWalletManager.maximumFundingBalanceSats,
                sendPresentationID: config.presentationID
            )
        } catch {
            guard sheets.activeSheetConfiguration?.id == .subscription,
                  app.ownsContactPaymentContext(context)
            else {
                if app.ownsContactPaymentContext(context) {
                    app.resetSendState(ownerID: config.presentationID)
                }
                return
            }
            showEmbeddedInitialPaymentFailure(request, error: error, context: context)
            return
        }

        // The retry task outlives the sheet, so it must not set the rate of a send opened after it.
        func isCurrentRetry() -> Bool {
            sheets.activeSheetConfiguration?.id == .subscription && app.ownsContactPaymentContext(context)
        }
        // `resetSendState` cleared the rate and setup does not run again, so the automatic payment would wait for it forever.
        if isCurrentRetry() {
            do {
                try await wallet.loadFeeRateWithRetry(speed: settings.defaultTransactionSpeed) {
                    try await wallet.setFeeRate(speed: $0, isCurrentSend: isCurrentRetry)
                }
            } catch is CancellationError {
                // The ownership check below releases a retry that no longer owns the send.
            } catch {
                Logger.error("Failed to set default fee rate for retry: \(error)")
            }
        }

        guard sheets.activeSheetConfiguration?.id == .subscription,
              app.ownsContactPaymentContext(context)
        else {
            if app.ownsContactPaymentContext(context) {
                app.resetSendState(ownerID: config.presentationID)
            }
            return
        }
        guard app.hasSendPaymentTarget else {
            showEmbeddedInitialPaymentFailure(
                request,
                error: PaykitPaymentRequestError.requestUnavailable,
                context: context
            )
            return
        }

        if !context.requiresAssetSelection {
            do {
                wallet.sendAmountSats = try request.payment(using: app.paykitPaymentMethod).amount.atomic
            } catch {
                showEmbeddedInitialPaymentFailure(request, error: error, context: context)
                return
            }
        }
        flow.pendingEmbeddedRetryRoute = context.requiresAssetSelection ? .amount : app.lnurlPayData == nil ? .confirm : .lnurlPayConfirm
        flow.hasValidatedAfterSync = false
        guard !shouldShowSyncOverlay else { return }
        validatePaymentAfterSync()
    }

    @MainActor
    private func showEmbeddedInitialPaymentFailure(
        _ request: PaykitPaymentRequest,
        error: Error,
        context existingContext: ContactPaymentContext? = nil
    ) {
        guard sheets.activeSheetConfiguration?.id == .subscription else {
            if let existingContext, app.ownsContactPaymentContext(existingContext) {
                app.resetSendState(ownerID: config.presentationID)
            }
            return
        }

        let context = existingContext ?? ContactPaymentContext(
            publicKey: request.counterparty,
            incomingPaymentRequest: request,
            isInitialSubscriptionPayment: true
        )
        if !app.ownsContactPaymentContext(context), !app.claimContactPaymentContext(context) {
            app.toast(PaykitPaymentRequestError.operationInProgress)
            return
        }

        let failure = SendFailureContext(
            error: error,
            retryRoute: .confirm,
            routingCacheResetAttempted: flow.routingCacheResetAttempted,
            contactPaymentContext: context
        )
        replaceRootRoute(with: .failure(failure))
    }
}

private struct SendComingSoonView: View {
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("coming_soon__nav_title"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                Image("stopwatch")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 48)

                DisplayText(t("coming_soon__headline"))
                    .frame(maxWidth: .infinity, alignment: .leading)

                BodyMText(t("coming_soon__description"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)

                CustomButton(title: t("coming_soon__button")) {
                    sheets.hideSheet()
                }
                .padding(.top, 32)
            }
        }
        .sheetBackground()
        .padding(.horizontal, 16)
    }
}
