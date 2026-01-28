import SwiftUI

enum SendRoute: Hashable {
    case options
    case manual
    case amount
    case utxoSelection
    case confirm
    case feeRate
    case feeCustom
    case tag
    case quickpay
    case success(String)
    case failure
    case lnurlPayAmount
    case lnurlPayConfirm
    case lnurlWithdrawAmount
    case lnurlWithdrawConfirm
    case lnurlWithdrawFailure(amount: UInt64)
}

struct SendConfig {
    let initialRoute: SendRoute

    init(view: SendRoute = .options) {
        initialRoute = view
    }
}

struct SendSheetItem: SheetItem {
    let id: SheetID = .send
    let size: SheetSize = .large
    let initialRoute: SendRoute

    init(initialRoute: SendRoute = .options) {
        self.initialRoute = initialRoute
    }
}

struct SendSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel

    let config: SendSheetItem

    @State private var navigationPath: [SendRoute] = []
    @State private var hasValidatedAfterSync = false

    /// Show sync overlay when node is not ready for payments
    /// For lightning: need node running AND at least one usable channel (peer connected).
    /// If there are no channels at all, we should NOT wait behind the sync UI – that's a capacity issue, not a sync issue.
    /// For onchain: only need node running.
    private var shouldShowSyncOverlay: Bool {
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

    var body: some View {
        Sheet(id: .send, data: config) {
            if shouldShowSyncOverlay {
                SyncNodeView()
                    .transition(.opacity)
            } else {
                NavigationStack(path: $navigationPath) {
                    viewForRoute(config.initialRoute)
                        .navigationDestination(for: SendRoute.self) { route in
                            viewForRoute(route)
                        }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: shouldShowSyncOverlay)
        .onAppear {
            tagManager.clearSelectedTags()
            wallet.resetSendState(speed: settings.defaultTransactionSpeed)
            hasValidatedAfterSync = false

            Task {
                do {
                    try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
                } catch {
                    Logger.error("Failed to set default fee rate: \(error)")
                }
            }
        }
        .onChange(of: wallet.nodeLifecycleState) { state in
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
        .onChange(of: wallet.hasUsableChannels) { hasUsable in
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
    private func validatePaymentAfterSync() {
        // Validate lightning payment if present
        if let lightningInvoice = app.scannedLightningInvoice {
            // For lightning, if we have channels but none are usable yet, wait for them
            // to become usable. If there are no channels at all, or channels are already
            // usable, proceed with validation/fallback.
            // Use channelCount as fallback in case channels array is nil but count is cached
            let hasAnyChannels = (wallet.channels?.isEmpty == false) || wallet.channelCount > 0
            if hasAnyChannels, !wallet.hasUsableChannels {
                // We have channels but none usable yet → wait
                return
            }

            // Check if we can afford the lightning payment
            let canSend = LightningService.shared.canSend(amountSats: lightningInvoice.amountSatoshis)

            if !canSend {
                // For unified invoices, fall back to onchain
                if let onchainInvoice = app.scannedOnchainInvoice {
                    // Switch to onchain wallet type
                    app.selectedWalletToPayFrom = .onchain
                    app.scannedOnchainInvoice = onchainInvoice
                    app.scannedLightningInvoice = nil

                    // Validate onchain balance BEFORE navigating
                    let onchainBalance = LightningService.shared.balances?.spendableOnchainBalanceSats ?? 0
                    guard validateOnchainBalanceAndDismissIfInsufficient(
                        invoiceAmount: onchainInvoice.amountSatoshis,
                        onchainBalance: onchainBalance
                    ) else {
                        hasValidatedAfterSync = true
                        return
                    }

                    // Onchain balance is sufficient → navigate to amount screen
                    // (the sheet may have opened with .confirm or .quickpay route)
                    navigationPath = [.amount]
                    hasValidatedAfterSync = true
                    return
                } else {
                    // For pure lightning invoices, show error toast and dismiss sheet
                    let spendingBalance = LightningService.shared.balances?.totalLightningBalanceSats ?? 0
                    showInsufficientSpendingToast(invoiceAmount: lightningInvoice.amountSatoshis, spendingBalance: spendingBalance)
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
            let onchainBalance = LightningService.shared.balances?.spendableOnchainBalanceSats ?? 0
            guard validateOnchainBalanceAndDismissIfInsufficient(
                invoiceAmount: onchainInvoice.amountSatoshis,
                onchainBalance: onchainBalance
            ) else {
                hasValidatedAfterSync = true
                return
            }
        }

        hasValidatedAfterSync = true
    }

    @ViewBuilder
    private func viewForRoute(_ route: SendRoute) -> some View {
        switch route {
        case .options:
            SendOptionsView(navigationPath: $navigationPath)
        case .manual:
            SendEnterManuallyView(navigationPath: $navigationPath)
        case .amount:
            SendAmountView(navigationPath: $navigationPath)
        case .utxoSelection:
            SendUtxoSelectionView(navigationPath: $navigationPath)
        case .confirm:
            SendConfirmationView(navigationPath: $navigationPath)
        case .feeRate:
            SendFeeRate(navigationPath: $navigationPath)
        case .feeCustom:
            SendFeeCustom(navigationPath: $navigationPath)
        case .tag:
            SendTagScreen(navigationPath: $navigationPath)
        case .quickpay:
            SendQuickpay(navigationPath: $navigationPath)
        case let .success(paymentId):
            SendSuccess(paymentId: paymentId)
        case .failure:
            SendFailure()
        case .lnurlPayAmount:
            LnurlPayAmount(navigationPath: $navigationPath)
        case .lnurlPayConfirm:
            LnurlPayConfirm(navigationPath: $navigationPath)
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
}
