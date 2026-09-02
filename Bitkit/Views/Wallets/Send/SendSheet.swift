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

    init(error: Error, retryRoute: SendRetryRoute, routingCacheResetAttempted: Bool = false, paymentRequest: String? = nil) {
        let shouldResetRoutingCaches = shouldResetRoutingCachesOnRetry(for: error)

        message = sendFailureMessage(for: error)
        self.retryRoute = retryRoute
        resetRoutingCachesOnRetry = shouldResetRoutingCaches && !routingCacheResetAttempted
        failureType = sendFailureType(for: error)
        self.paymentRequest = paymentRequest
        self.routingCacheResetAttempted = routingCacheResetAttempted
    }
}

enum SendRoute: Hashable {
    case options
    case contact
    case comingSoon
    case manual
    case amount
    case utxoSelection
    case confirm
    case hardwareSign
    case feeRate
    case feeCustom
    case tag
    case quickpay
    case pin
    case pending(paymentHash: String, retryRoute: SendRetryRoute, paymentRequest: String?)
    case success(paymentId: String, walletId: String = WalletScope.default)
    case failure(SendFailureContext)
    case lnurlPayAmount
    case lnurlPayConfirm
    case lnurlWithdrawAmount
    case lnurlWithdrawConfirm
    case lnurlWithdrawFailure(amount: UInt64)
}

struct SendConfig {
    let initialRoute: SendRoute
    let hardwareWalletId: String?

    init(view: SendRoute = .options, hardwareWalletId: String? = nil) {
        initialRoute = view
        self.hardwareWalletId = hardwareWalletId
    }
}

struct SendSheetItem: SheetItem {
    let id: SheetID = .send
    let size: SheetSize = .large
    let initialRoute: SendRoute
    let hardwareWalletId: String?

    init(initialRoute: SendRoute = .options, hardwareWalletId: String? = nil) {
        self.initialRoute = initialRoute
        self.hardwareWalletId = hardwareWalletId
    }
}

struct SendSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paykitPaymentRequestManager
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(TrezorManager.self) private var trezorManager

    let config: SendSheetItem

    @State private var navigationPath: [SendRoute] = []
    @State private var rootOverride: SendRoute?
    @State private var quickPaySession = 0
    @State private var hasValidatedAfterSync = false
    @State private var incomingPaymentRequest: PaykitPaymentRequest?
    @State private var routingCacheResetAttempted = false
    @State private var syncTimedOut = false
    @State private var pinCheckContinuations: [CheckedContinuation<Bool, Never>] = []
    @State private var hwSend: HwSendCoordinator
    @State private var setupTask: Task<Void, Never>?

    init(config: SendSheetItem) {
        self.config = config
        _hwSend = State(initialValue: HwSendCoordinator(walletId: config.hardwareWalletId))
    }

    private var currentRoot: SendRoute {
        rootOverride ?? config.initialRoute
    }

    /// How long the sync overlay may wait for channels to become usable before falling back
    private static let syncTimeoutSeconds: TimeInterval = 20

    /// Show sync overlay when node is not ready for payments
    /// For lightning: need node running AND at least one usable channel (peer connected).
    /// If there are no channels at all, we should NOT wait behind the sync UI – that's a capacity issue, not a sync issue.
    /// For onchain: only need node running.
    private var shouldShowSyncOverlay: Bool {
        if hwSend.isActive {
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
        Sheet(id: .send, data: config) {
            if shouldShowSyncOverlay {
                SendSyncScreen()
                    .transition(.opacity)
            } else {
                NavigationStack(path: $navigationPath) {
                    viewForRoute(currentRoot)
                        .navigationDestination(for: SendRoute.self) { route in
                            viewForRoute(route)
                        }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: shouldShowSyncOverlay)
        .interactiveDismissDisabled(hwSend.isSigning || hwSend.isBroadcastUnresolved)
        .sheet(isPresented: reconnectPairingBinding) {
            HardwarePairingSheet(config: HardwarePairingSheetItem())
        }
        .offlineSheetOverlay(title: t("wallet__send_bitcoin"), forceShow: syncTimedOut)
        .onChange(of: shouldShowSyncOverlay, initial: true) { _, isShowing in
            Logger.debug("shouldShowSyncOverlay: \(isShowing) (node: \(wallet.nodeLifecycleState))", context: "SendSheet")
        }
        .onAppear {
            tagManager.clearSelectedTags()
            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
            if let walletId = config.hardwareWalletId {
                let balance = hwWalletManager.fundingBalance(walletId: walletId)
                let reserve = HwFundingSigner.feeReserve(
                    balanceSats: balance,
                    satsPerVByte: wallet.selectedFeeRateSatsPerVByte.map(UInt64.init)
                )
                hwSend.seedAvailable(
                    walletId: walletId,
                    availableSats: balance > reserve ? balance - reserve : 0
                )
            }
            if let request = app.contactPaymentContext?.incomingPaymentRequest {
                incomingPaymentRequest = request
                guard paykitPaymentRequestManager.markPresentedIfPending(request) else {
                    app.resetSendState()
                    sheets.hideSheetIfActive(.send, reason: "Incoming payment request is no longer available")
                    return
                }
                wallet.sendAmountSats = request.amountSats
            }
            hasValidatedAfterSync = false
            syncTimedOut = false

            // A plain Send open (TabBar) must not inherit invoice state from an earlier scan,
            // e.g. one abandoned behind the sync overlay. Invoice-carrying opens use other routes.
            if config.initialRoute == .options {
                app.resetSendState()
            }

            setupTask?.cancel()
            setupTask = Task {
                do {
                    try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
                } catch is CancellationError {
                    return
                } catch {
                    Logger.error("Failed to set default fee rate: \(error)")
                }

                if let request = incomingPaymentRequest {
                    guard isCurrentIncomingRequest(request.id) else { return }
                    guard await selectHardwareFundingSourceIfNeeded(
                        amountSats: request.amountSats,
                        requestId: request.id
                    ) else { return }
                    guard isCurrentIncomingRequest(request.id) else { return }
                    if !shouldShowSyncOverlay {
                        validatePaymentAfterSync()
                    }
                }
            }
        }
        .onDisappear {
            setupTask?.cancel()
            setupTask = nil
            hwSend.cancel()
            if let incomingPaymentRequest {
                paykitPaymentRequestManager.finishPayment(incomingPaymentRequest)
            }
            incomingPaymentRequest = nil
            app.contactPaymentContext = nil
            app.resetQuickPay()
            QuickPayPaymentCoordinator.shared.detach()
        }
        .onChange(of: wallet.nodeLifecycleState) { _, state in
            // When the node becomes running and we have a scanned invoice, run deferred validation.
            // This covers:
            // - Pure onchain invoices (node was not running at scan time)
            // - Unified invoices where we may need to fall back from lightning to onchain
            // Lightning-first flows where the node was already running are handled in AppViewModel.
            let hasScannedInvoice = app.scannedLightningInvoice != nil
                || app.scannedOnchainInvoice != nil
                || app.lnurlPayData != nil
            guard hasScannedInvoice else { return }

            if state == .running, !hasValidatedAfterSync {
                validatePaymentAfterSync()
            }
        }
        .onChange(of: wallet.hasUsableChannels) { _, hasUsable in
            // Only validate if channels just became usable and we have a scanned invoice
            // (Validation already happened in AppViewModel if channels were already usable)
            let hasScannedInvoice = app.scannedLightningInvoice != nil || app.scannedOnchainInvoice != nil || app.lnurlPayData != nil
            guard hasScannedInvoice else { return }

            let isLightningPayment = app.scannedLightningInvoice != nil
                || app.lnurlPayData != nil
                || app.selectedWalletToPayFrom == .lightning

            if isLightningPayment, hasUsable, wallet.nodeLifecycleState == .running, !hasValidatedAfterSync {
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
                    syncTimedOut = false
                }
                return
            }

            try? await Task.sleep(for: .seconds(Self.syncTimeoutSeconds))
            guard !Task.isCancelled, syncTimeoutPhase.isActive, !hasValidatedAfterSync else { return }

            handleSyncTimeout()
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
            syncTimedOut = true
        }
    }

    /// Validates onchain balance and shows toast + dismisses sheet if insufficient.
    /// Returns true if sufficient, false if insufficient.
    private func validateOnchainBalanceAndDismissIfInsufficient(invoiceAmount: UInt64, onchainBalance: UInt64) -> Bool {
        if invoiceAmount > 0 {
            guard onchainBalance >= invoiceAmount else {
                let amountNeeded = invoiceAmount - onchainBalance
                app.toast(
                    type: .error,
                    title: t("other__pay_insufficient_savings"),
                    description: t(
                        "other__pay_insufficient_savings_amount_description",
                        variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)]
                    ),
                    accessibilityIdentifier: "InsufficientSavingsToast"
                )
                sheets.hideSheet()
                return false
            }
        } else {
            // Zero-amount invoice: user must have some balance to proceed
            guard onchainBalance > 0 else {
                app.toast(
                    type: .error,
                    title: t("other__pay_insufficient_savings"),
                    description: t("other__pay_insufficient_savings_description"),
                    accessibilityIdentifier: "InsufficientSavingsToast"
                )
                sheets.hideSheet()
                return false
            }
        }
        return true
    }

    /// Shows insufficient spending toast with amount-specific or generic description
    private func showInsufficientSpendingToast(invoiceAmount: UInt64, spendingBalance: UInt64) {
        let amountNeeded = invoiceAmount > spendingBalance ? invoiceAmount - spendingBalance : 0
        let description = amountNeeded > 0
            ? t("other__pay_insufficient_spending_amount_description", variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)])
            : t("other__pay_insufficient_spending_description")
        app.toast(
            type: .error,
            title: t("other__pay_insufficient_spending"),
            description: description,
            accessibilityIdentifier: "InsufficientSpendingToast"
        )
    }

    /// Validates payment affordability after sync completes
    /// For lightning: falls back to onchain for unified invoices, shows error for pure lightning invoices
    /// For onchain: validates balance and shows error if insufficient
    /// Pass `ignoreChannelWait: true` to validate even while channels are unusable (sync timeout).
    private func validatePaymentAfterSync(ignoreChannelWait: Bool = false) {
        let requestedAmount = app.contactPaymentContext?.incomingPaymentRequest?.amountSats

        if let lnurlPayData = app.lnurlPayData, let requestedAmount {
            let minimumAmount = max(1, lnurlPayData.minSendableSat)
            guard requestedAmount >= minimumAmount else {
                app.toast(
                    type: .error,
                    title: t("wallet__lnurl_pay__error_min__title"),
                    description: t(
                        "wallet__lnurl_pay__error_min__description",
                        variables: ["amount": CurrencyFormatter.formatSats(minimumAmount)]
                    ),
                    accessibilityIdentifier: "LnurlPayAmountTooLowToast"
                )
                sheets.hideSheet()
                hasValidatedAfterSync = true
                return
            }
            guard requestedAmount <= lnurlPayData.maxSendableSat else {
                app.toast(
                    type: .error,
                    title: t("wallet__lnurl_pay__error_max__title"),
                    description: t("wallet__lnurl_pay__error_max__description"),
                    accessibilityIdentifier: "LnurlPayAmountTooHighToast"
                )
                sheets.hideSheet()
                hasValidatedAfterSync = true
                return
            }
            guard LightningService.shared.canSend(amountSats: requestedAmount) else {
                let spendingBalance = LightningService.shared.balances?.totalLightningBalanceSats ?? 0
                showInsufficientSpendingToast(invoiceAmount: requestedAmount, spendingBalance: spendingBalance)
                sheets.hideSheet()
                hasValidatedAfterSync = true
                return
            }

            hasValidatedAfterSync = true
            return
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
                return
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

                    // Validate onchain balance BEFORE navigating
                    let onchainBalance = max(
                        LightningService.shared.balances?.spendableOnchainBalanceSats ?? 0,
                        hwWalletManager.maximumFundingBalanceSats
                    )
                    guard validateOnchainBalanceAndDismissIfInsufficient(
                        invoiceAmount: requestedAmount ?? onchainInvoice.amountSatoshis,
                        onchainBalance: onchainBalance
                    ) else {
                        hasValidatedAfterSync = true
                        return
                    }

                    // Onchain balance is sufficient → navigate to amount screen
                    // (the sheet may have opened with .confirm or .quickpay route)
                    if requestedAmount == nil {
                        navigationPath = [.amount]
                    }
                    hasValidatedAfterSync = true
                    return
                } else {
                    // For pure lightning invoices, show error toast and dismiss sheet
                    let spendingBalance = LightningService.shared.balances?.totalLightningBalanceSats ?? 0
                    showInsufficientSpendingToast(invoiceAmount: paymentAmount, spendingBalance: spendingBalance)
                    sheets.hideSheet()
                    hasValidatedAfterSync = true
                    return
                }
            } else {
                // Lightning payment is valid, we're done
                hasValidatedAfterSync = true
                return
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
                hasValidatedAfterSync = true
                return
            }
        }

        hasValidatedAfterSync = true
    }

    private func requestPinCheck() async -> Bool {
        // Prevent stacking multiple PIN screens if already presented.
        if navigationPath.last != .pin {
            navigationPath.append(.pin)
        }

        return await withCheckedContinuation { continuation in
            pinCheckContinuations.append(continuation)
        }
    }

    private func resolvePinCheck(_ approved: Bool) {
        let continuations = pinCheckContinuations
        pinCheckContinuations.removeAll()
        continuations.forEach { $0.resume(returning: approved) }

        if navigationPath.last == .pin {
            navigationPath.removeLast()
        }
    }

    private func isCurrentIncomingRequest(_ requestId: PaykitPaymentRequest.ID) -> Bool {
        !Task.isCancelled
            && sheets.activeSheetConfiguration?.id == .send
            && incomingPaymentRequest?.id == requestId
            && app.contactPaymentContext?.incomingPaymentRequest?.id == requestId
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
        if let savingsAvailable, savingsAvailable >= amountSats { return true }

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
            SendOptionsView(navigationPath: $navigationPath, hwSend: hwSend)
        case .contact:
            SendContactSelectView(navigationPath: $navigationPath, hwSend: hwSend)
        case .comingSoon:
            SendComingSoonView()
        case .manual:
            SendEnterManuallyView(navigationPath: $navigationPath, hwSend: hwSend)
        case .amount:
            SendAmountView(navigationPath: $navigationPath, hwSend: hwSend)
        case .utxoSelection:
            SendUtxoSelectionView(navigationPath: $navigationPath)
        case .confirm:
            SendConfirmationView(
                navigationPath: $navigationPath,
                hwSend: hwSend,
                requestPinCheck: requestPinCheck,
                prepareIncomingPaymentRequest: prepareIncomingPaymentRequest,
                routingCacheResetAttempted: routingCacheResetAttempted
            )
        case .hardwareSign:
            HwSendSignView(
                navigationPath: $navigationPath,
                hwSend: hwSend,
                prepareContactPayment: prepareHardwareContactPayment,
                completeContactPayment: completeHardwareContactPayment,
                cancelContactPayment: cancelHardwareContactPayment
            )
        case .feeRate:
            SendFeeRate(navigationPath: $navigationPath, hwSend: hwSend)
        case .feeCustom:
            SendFeeCustom(navigationPath: $navigationPath, hwSend: hwSend)
        case .tag:
            SendTagScreen(navigationPath: $navigationPath)
        case .quickpay:
            SendQuickpay(
                navigationPath: $navigationPath,
                routingCacheResetAttempted: routingCacheResetAttempted,
                replaceQuickPay: replaceQuickPay(with:)
            )
            .id(quickPaySession)
        case .pin:
            SendPinScreen(onCancel: { resolvePinCheck(false) }, onPinVerified: { resolvePinCheck(true) })
        case let .pending(paymentHash, retryRoute, paymentRequest):
            SendPendingScreen(
                paymentHash: paymentHash,
                retryRoute: retryRoute,
                paymentRequest: paymentRequest,
                routingCacheResetAttempted: routingCacheResetAttempted,
                navigationPath: $navigationPath
            )
        case let .success(paymentId, walletId):
            SendSuccess(paymentId: paymentId, walletId: walletId)
        case let .failure(context):
            SendFailure(
                context: context,
                onRetryReady: { didResetRoutingCaches in
                    if didResetRoutingCaches {
                        routingCacheResetAttempted = true
                    }
                    resetNavigationForRetry(context.retryRoute)
                }
            )
        case .lnurlPayAmount:
            LnurlPayAmount(navigationPath: $navigationPath)
        case .lnurlPayConfirm:
            LnurlPayConfirm(
                navigationPath: $navigationPath,
                requestPinCheck: requestPinCheck,
                prepareIncomingPaymentRequest: prepareIncomingPaymentRequest,
                routingCacheResetAttempted: routingCacheResetAttempted
            )
        case .lnurlWithdrawAmount:
            LnurlWithdrawAmount {
                navigationPath.append(.lnurlWithdrawConfirm)
            }
        case .lnurlWithdrawConfirm:
            LnurlWithdrawConfirm { amount in
                navigationPath.append(.lnurlWithdrawFailure(amount: amount))
            }
        case let .lnurlWithdrawFailure(amount):
            LnurlWithdrawFailure(amount: amount)
        }
    }

    private func prepareIncomingPaymentRequest() async throws {
        guard let context = app.contactPaymentContext,
              let request = context.incomingPaymentRequest
        else { return }
        guard !paykitPaymentRequestManager.isApprovedForPayment(request) else { return }

        try await paykitPaymentRequestManager.prepareForPayment(request) {
            guard let privatePaymentContext = context.privatePaymentContext else { return }
            try await PrivatePaykitService.shared.consumePrivatePaymentList(
                publicKey: context.publicKey,
                context: privatePaymentContext
            )
        }
    }

    private func prepareHardwareContactPayment() async throws {
        guard let request = app.contactPaymentContext?.incomingPaymentRequest,
              let address = app.scannedOnchainInvoice?.address
        else {
            try await prepareIncomingPaymentRequest()
            return
        }

        let endpointIdentifier = PublicPaykitService.onchainMethodId(for: address).rawValue
        try await PaykitPaymentProofService.shared.prepare(
            request: request,
            paymentEndpointIdentifier: endpointIdentifier,
            kind: .onchain
        )
        do {
            try await prepareIncomingPaymentRequest()
        } catch {
            await PaykitPaymentProofService.shared.cancelPreparation(request)
            throw error
        }
    }

    private func completeHardwareContactPayment(txid: String) async {
        guard let request = app.contactPaymentContext?.incomingPaymentRequest,
              let address = app.scannedOnchainInvoice?.address
        else { return }

        await PaykitPaymentProofService.shared.completeOnchainPayment(
            request,
            txid: txid,
            paymentEndpointIdentifier: PublicPaykitService.onchainMethodId(for: address).rawValue
        )
    }

    private func cancelHardwareContactPayment() async {
        guard let request = app.contactPaymentContext?.incomingPaymentRequest else { return }
        await PaykitPaymentProofService.shared.cancelPreparation(request)
    }

    private func replaceQuickPay(with route: SendRoute) {
        app.resetQuickPay()
        let next = PaymentNavigationHelper.replacingQuickPay(in: navigationPath, root: currentRoot, with: route)
        rootOverride = next.root == config.initialRoute ? nil : next.root
        navigationPath = next.path
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
            quickPaySession += 1
        }
        if route == config.initialRoute || currentRoot == route {
            if route == config.initialRoute {
                rootOverride = nil
            }
            navigationPath = []
            return
        }

        navigationPath = [route]
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
