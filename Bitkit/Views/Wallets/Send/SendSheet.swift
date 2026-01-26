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
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var tagManager: TagManager

    let config: SendSheetItem

    @State private var navigationPath: [SendRoute] = []
    @State private var hasValidatedAfterSync = false

    /// Show sync overlay when node is not ready for lightning payments
    /// For lightning: need node running AND at least one usable channel (peer connected)
    /// For onchain: only need node running
    private var shouldShowSyncOverlay: Bool {
        // Node must be running
        guard wallet.nodeLifecycleState == .running else { return true }

        // For lightning payments, also need usable channels (peer connected)
        let isLightningPayment = app.scannedLightningInvoice != nil
            || app.lnurlPayData != nil
            || app.selectedWalletToPayFrom == .lightning

        if isLightningPayment {
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
            // For pure onchain payments, validate when node is running
            let isLightningPayment = app.scannedLightningInvoice != nil
                || app.lnurlPayData != nil
                || app.selectedWalletToPayFrom == .lightning

            if state == .running, !isLightningPayment, !hasValidatedAfterSync {
                validatePaymentAfterSync()
            }
        }
        .onChange(of: wallet.hasUsableChannels) { hasUsable in
            // For lightning payments, validate when channels become usable (node must also be running)
            let isLightningPayment = app.scannedLightningInvoice != nil
                || app.lnurlPayData != nil
                || app.selectedWalletToPayFrom == .lightning

            if isLightningPayment, hasUsable, wallet.nodeLifecycleState == .running, !hasValidatedAfterSync {
                validatePaymentAfterSync()
            }
        }
    }

    /// Validates payment affordability after sync completes
    /// For lightning: falls back to onchain for unified invoices, shows error for pure lightning invoices
    /// For onchain: validates balance and shows error if insufficient
    private func validatePaymentAfterSync() {
        // Validate lightning payment if present
        if let lightningInvoice = app.scannedLightningInvoice {
            // For lightning, we also need usable channels
            guard wallet.hasUsableChannels else {
                // Wait for channels to become usable
                return
            }

            // Check if we can afford the lightning payment
            let canSend = LightningService.shared.canSend(amountSats: lightningInvoice.amountSatoshis)

            if !canSend {
                // For unified invoices, fall back to onchain
                if let onchainInvoice = app.scannedOnchainInvoice {
                    app.selectedWalletToPayFrom = .onchain
                    app.scannedOnchainInvoice = onchainInvoice
                    app.scannedLightningInvoice = nil
                    // Continue to validate onchain balance below
                } else {
                    // For pure lightning invoices, show error toast
                    let spendingBalance = LightningService.shared.balances?.totalLightningBalanceSats ?? 0
                    let amountNeeded = lightningInvoice.amountSatoshis > spendingBalance ? lightningInvoice.amountSatoshis - spendingBalance : 0
                    let description = amountNeeded > 0
                        ? t("other__pay_insufficient_spending_amount_description", variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)])
                        : t("other__pay_insufficient_spending_description")
                    app.toast(
                        type: .error,
                        title: t("other__pay_insufficient_spending"),
                        description: description,
                        accessibilityIdentifier: "InsufficientSpendingToast"
                    )
                    hasValidatedAfterSync = true
                    return
                }
            } else {
                // Lightning payment is valid, we're done
                hasValidatedAfterSync = true
                return
            }
        }

        // Validate onchain payment balance
        if let onchainInvoice = app.scannedOnchainInvoice {
            let onchainBalance = LightningService.shared.balances?.spendableOnchainBalanceSats ?? 0

            if onchainInvoice.amountSatoshis > 0 {
                guard onchainBalance >= onchainInvoice.amountSatoshis else {
                    let amountNeeded = onchainInvoice.amountSatoshis - onchainBalance
                    app.toast(
                        type: .error,
                        title: t("other__pay_insufficient_savings"),
                        description: t(
                            "other__pay_insufficient_savings_amount_description",
                            variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)]
                        ),
                        accessibilityIdentifier: "InsufficientSavingsToast"
                    )
                    hasValidatedAfterSync = true
                    return
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
                    hasValidatedAfterSync = true
                    return
                }
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
