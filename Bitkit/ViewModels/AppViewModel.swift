import BitkitCore
import LDKNode
import SwiftUI

@MainActor
class AppViewModel: ObservableObject {
    // Send flow
    @Published var scannedLightningInvoice: LightningInvoice?
    @Published var scannedOnchainInvoice: OnChainInvoice?
    @Published var selectedWalletToPayFrom: WalletType = .onchain

    // LNURL
    @Published var lnurlPayData: LnurlPayData?
    @Published var lnurlWithdrawData: LnurlWithdrawData?

    // Onboarding
    @AppStorage("hasSeenContactsIntro") var hasSeenContactsIntro: Bool = false
    @AppStorage("hasSeenProfileIntro") var hasSeenProfileIntro: Bool = false
    @AppStorage("hasSeenNotificationsIntro") var hasSeenNotificationsIntro: Bool = false
    @AppStorage("hasSeenQuickpayIntro") var hasSeenQuickpayIntro: Bool = false
    @AppStorage("hasSeenShopIntro") var hasSeenShopIntro: Bool = false
    @AppStorage("hasSeenTransferIntro") var hasSeenTransferIntro: Bool = false
    @AppStorage("hasSeenTransferToSpendingIntro") var hasSeenTransferToSpendingIntro: Bool = false
    @AppStorage("hasSeenTransferToSavingsIntro") var hasSeenTransferToSavingsIntro: Bool = false
    @AppStorage("hasSeenWidgetsIntro") var hasSeenWidgetsIntro: Bool = false

    // When to show empty state UI
    @AppStorage("showHomeViewEmptyState") var showHomeViewEmptyState: Bool = false

    // App update tracking
    @AppStorage("appUpdateIgnoreTimestamp") var appUpdateIgnoreTimestamp: TimeInterval = 0

    // Backup warning tracking
    @AppStorage("backupVerified") var backupVerified: Bool = false
    @AppStorage("backupIgnoreTimestamp") var backupIgnoreTimestamp: TimeInterval = 0

    // High balance warning tracking
    @AppStorage("highBalanceIgnoreCount") var highBalanceIgnoreCount: Int = 0
    @AppStorage("highBalanceIgnoreTimestamp") var highBalanceIgnoreTimestamp: TimeInterval = 0

    // Drawer menu
    @Published var showDrawer = false

    // App status initialization
    @Published var appStatusInitialized: Bool = false

    func showAllEmptyStates(_ show: Bool) {
        showHomeViewEmptyState = show
    }

    private func startAppStatusInitializationTimer() {
        // Give the app some time to initialize before showing the real status
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.appStatusInitialized = true
        }
    }

    private let lightningService: LightningService
    private let coreService: CoreService
    private let sheetViewModel: SheetViewModel
    private let navigationViewModel: NavigationViewModel

    init(
        lightningService: LightningService = .shared,
        coreService: CoreService = .shared,
        sheetViewModel: SheetViewModel,
        navigationViewModel: NavigationViewModel
    ) {
        self.lightningService = lightningService
        self.coreService = coreService
        self.sheetViewModel = sheetViewModel
        self.navigationViewModel = navigationViewModel

        // Start app status initialization timer
        startAppStatusInitializationTimer()

        Task {
            await checkGeoStatus()
            // Check for app updates on startup
            await AppUpdateService.shared.checkForAppUpdate()
        }
    }

    // Convenience initializer for previews and testing
    convenience init() {
        self.init(sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel())
    }

    deinit {}

    func checkGeoStatus() async {
        // Delegate to GeoService singleton for centralized geo-blocking management
        await GeoService.shared.checkGeoStatus()
    }

    func wipe() async throws {
        hasSeenContactsIntro = false
        hasSeenProfileIntro = false
        hasSeenNotificationsIntro = false
        hasSeenQuickpayIntro = false
        hasSeenShopIntro = false
        hasSeenTransferToSpendingIntro = false
        hasSeenTransferToSavingsIntro = false
        hasSeenWidgetsIntro = false
        showHomeViewEmptyState = false
        appUpdateIgnoreTimestamp = 0
        backupVerified = false
        backupIgnoreTimestamp = 0
        highBalanceIgnoreCount = 0
        highBalanceIgnoreTimestamp = 0
    }
}

// MARK: Toast notifications

extension AppViewModel {
    func toast(
        type: Toast.ToastType,
        title: String,
        description: String? = nil,
        autoHide: Bool = true,
        visibilityTime: Double = 4.0,
        accessibilityIdentifier: String? = nil
    ) {
        switch type {
        case .error:
            Haptics.notify(.error)
        case .success:
            Haptics.notify(.success)
        case .info:
            Haptics.play(.heavy)
        case .lightning:
            Haptics.play(.rigid)
        case .warning:
            Haptics.notify(.warning)
        }

        let toast = Toast(
            type: type,
            title: title,
            description: description,
            autoHide: autoHide,
            visibilityTime: visibilityTime,
            accessibilityIdentifier: accessibilityIdentifier
        )
        ToastWindowManager.shared.showToast(toast)
    }

    func toast(_ error: Error) {
        toast(type: .error, title: "Error", description: error.localizedDescription)
    }

    func hideToast() {
        ToastWindowManager.shared.hideToast()
    }
}

// MARK: Scanning/pasting handling

extension AppViewModel {
    func handleScannedData(_ uri: String) async throws {
        // Reset send state before handling new data
        resetSendState()

        let data = try await decode(invoice: uri)

        switch data {
        // BIP21 (Unified) invoice handling
        case let .onChain(invoice):
            if let lnInvoice = invoice.params?["lightning"] {
                guard lightningService.status?.isRunning == true else {
                    toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                    return
                }
                // Lightning invoice param found, prefer lightning payment if possible
                if case let .lightning(lightningInvoice) = try await decode(invoice: lnInvoice) {
                    if lightningService.canSend(amountSats: lightningInvoice.amountSatoshis) {
                        handleScannedLightningInvoice(lightningInvoice, bolt11: lnInvoice, onchainInvoice: invoice)
                        return
                    }
                }
            }

            // No LN invoice found, proceed with onchain payment
            handleScannedOnchainInvoice(invoice)
        case let .lightning(invoice):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }

            Logger.debug("Lightning: \(invoice)")
            if lightningService.canSend(amountSats: invoice.amountSatoshis) {
                handleScannedLightningInvoice(invoice, bolt11: uri)
            } else {
                toast(type: .error, title: "Insufficient Funds", description: "You do not have enough funds to send this payment.")
            }
        case let .lnurlPay(data: lnurlPayData):
            Logger.debug("LNURL: \(lnurlPayData)")
            handleLnurlPayInvoice(lnurlPayData)
        case let .lnurlWithdraw(data: lnurlWithdrawData):
            Logger.debug("LNURL: \(lnurlWithdrawData)")
            handleLnurlWithdraw(lnurlWithdrawData)
        case let .lnurlChannel(data: lnurlChannelData):
            Logger.debug("LNURL: \(lnurlChannelData)")
            handleLnurlChannel(lnurlChannelData)
        case let .lnurlAuth(data: lnurlAuthData):
            Logger.debug("LNURL: \(lnurlAuthData)")
            handleLnurlAuth(lnurlAuthData, lnurl: uri)
        case let .nodeId(url, network):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }

            // TODO: add network check

            handleNodeUri(url, network)
        case let .gift(code, amount):
            sheetViewModel.showSheet(.gift, data: GiftConfig(code: code, amount: Int(amount)))
        default:
            Logger.warn("Unhandled invoice type: \(data)")
            toast(type: .error, title: "Unsupported", description: "This type of invoice is not supported yet")
        }
    }

    private func handleScannedLightningInvoice(_ invoice: LightningInvoice, bolt11: String, onchainInvoice: OnChainInvoice? = nil) {
        scannedLightningInvoice = invoice
        scannedOnchainInvoice = onchainInvoice // Keep onchain invoice if provided
        selectedWalletToPayFrom = .lightning

        if invoice.amountSatoshis > 0 {
            Logger.debug("Found amount in invoice, proceeding with payment")
        } else {
            Logger.debug("No amount found in invoice, proceeding entering amount manually")
        }
    }

    private func handleScannedOnchainInvoice(_ invoice: OnChainInvoice) {
        selectedWalletToPayFrom = .onchain
        scannedOnchainInvoice = invoice
        scannedLightningInvoice = nil
    }

    private func handleLnurlPayInvoice(_ data: LnurlPayData) {
        // Check if lightning service is running
        guard lightningService.status?.isRunning == true else {
            toast(type: .error, title: "Lightning not running", description: "Please try again later.")
            return
        }

        var normalizedData = data
        normalizedData.minSendable = max(1, normalizedData.minSendable / 1000)
        normalizedData.maxSendable = max(normalizedData.minSendable, normalizedData.maxSendable / 1000)

        // Check if user has enough lightning balance to pay the minimum amount
        let lightningBalance = lightningService.balances?.totalLightningBalanceSats ?? 0
        if lightningBalance < normalizedData.minSendable {
            toast(
                type: .warning,
                title: t("other__lnurl_pay_error"),
                description: t("other__lnurl_pay_error_no_capacity")
            )
            return
        }

        selectedWalletToPayFrom = .lightning
        lnurlPayData = normalizedData
    }

    private func handleLnurlWithdraw(_ data: LnurlWithdrawData) {
        // Check if lightning service is running
        guard lightningService.status?.isRunning == true else {
            toast(type: .error, title: "Lightning not running", description: "Please try again later.")
            return
        }

        // Check if minWithdrawable > maxWithdrawable
        if (data.minWithdrawable ?? 1000) > data.maxWithdrawable {
            toast(
                type: .warning,
                title: t("other__lnurl_withdr_error"),
                description: t("other__lnurl_withdr_error_minmax")
            )
            return
        }

        // Check if we have enough receiving capacity
        let lightningBalance = lightningService.balances?.totalLightningBalanceSats ?? 0
        if lightningBalance < (data.minWithdrawable ?? 1000) / 1000 {
            toast(
                type: .warning,
                title: t("other__lnurl_withdr_error"),
                description: t("other__lnurl_withdr_error_no_capacity")
            )
            return
        }

        lnurlWithdrawData = data
    }

    private func handleLnurlChannel(_ data: LnurlChannelData) {
        // Check if lightning service is running
        guard lightningService.status?.isRunning == true else {
            toast(type: .error, title: "Lightning not running", description: "Please try again later.")
            return
        }

        sheetViewModel.hideSheet()
        navigationViewModel.navigate(.lnurlChannel(channelData: data))
    }

    private func handleLnurlAuth(_ data: LnurlAuthData, lnurl: String) {
        // Check if lightning service is running
        guard lightningService.status?.isRunning == true else {
            toast(type: .error, title: "Lightning not running", description: "Please try again later.")
            return
        }

        sheetViewModel.showSheet(.lnurlAuth, data: LnurlAuthConfig(lnurl: lnurl, authData: data))
    }

    private func handleNodeUri(_ url: String, _ network: NetworkType) {
        sheetViewModel.hideSheet()
        navigationViewModel.navigate(.fundManual(nodeUri: url))
    }

    func resetSendState() {
        scannedLightningInvoice = nil
        scannedOnchainInvoice = nil
        selectedWalletToPayFrom = .onchain // Reset to default
        lnurlPayData = nil
        lnurlWithdrawData = nil
    }
}

// MARK: LDK Node Events

extension AppViewModel {
    func handleLdkNodeEvent(_ event: Event) {
        switch event {
        case let .paymentReceived(paymentId, paymentHash, amountMsat, customRecords):
            sheetViewModel.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .lightning, sats: amountMsat / 1000))
        case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            // Only relevant for channels to external nodes
            break
        case .channelReady(let channelId, userChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            if let channel = lightningService.channels?.first(where: { $0.channelId == channelId }) {
                Task {
                    let cjitOrder = try await CoreService.shared.blocktank.getCjit(channel: channel)
                    if cjitOrder != nil {
                        let amount = channel.spendableBalanceSats
                        let now = UInt64(Date().timeIntervalSince1970)

                        let ln = LightningActivity(
                            id: channel.fundingTxo?.txid ?? "",
                            txType: .received,
                            status: .succeeded,
                            value: amount,
                            fee: 0,
                            invoice: cjitOrder?.invoice.request ?? "",
                            message: "",
                            timestamp: now,
                            preimage: nil,
                            createdAt: now,
                            updatedAt: nil
                        )

                        try await CoreService.shared.activity.insert(.lightning(ln))
                    } else {
                        toast(
                            type: .lightning,
                            title: t("lightning__channel_opened_title"),
                            description: t("lightning__channel_opened_msg"),
                            visibilityTime: 5.0,
                            accessibilityIdentifier: "SpendingBalanceReadyToast"
                        )
                    }
                }
            } else {
                toast(
                    type: .lightning,
                    title: t("lightning__channel_opened_title"),
                    description: t("lightning__channel_opened_msg"),
                    visibilityTime: 5.0,
                    accessibilityIdentifier: "SpendingBalanceReadyToast"
                )
            }
        case .channelClosed(channelId: _, userChannelId: _, counterpartyNodeId: _, reason: _):
            break
        case let .paymentSuccessful(paymentId, paymentHash, paymentPreimage, feePaidMsat):
            // TODO: fee is not the sats sent. Need to get this amount from elsewhere like send flow or something.
            break
        case .paymentClaimable:
            break
        case .paymentFailed(paymentId: _, paymentHash: _, reason: _):
            toast(
                type: .error,
                title: t("wallet__toast_payment_failed_title"),
                description: t("wallet__toast_payment_failed_description"),
                accessibilityIdentifier: "PaymentFailedToast"
            )
        case .paymentForwarded:
            break

        // MARK: New Onchain Transaction Events

        case let .onchainTransactionReceived(txid, details):
            // Show notification for incoming transactions
            if details.amountSats > 0 {
                let sats = UInt64(abs(Int64(details.amountSats)))

                Task {
                    // Show sheet for new transactions or replacements with value changes
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms delay
                    let shouldShow = await CoreService.shared.activity.shouldShowReceivedSheet(txid: txid, value: sats)

                    await MainActor.run {
                        if !shouldShow {
                            return
                        }

                        sheetViewModel.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, sats: sats))
                    }
                }
            }
        case let .onchainTransactionConfirmed(txid, blockHash, blockHeight, confirmationTime, details):
            Logger.info("Transaction confirmed: \(txid) at block \(blockHeight)")
        case let .onchainTransactionReplaced(txid, conflicts):
            Logger.info("Transaction replaced: \(txid) by \(conflicts.count) conflict(s)")
            Task {
                if await CoreService.shared.activity.isReceivedTransaction(txid: txid) {
                    await MainActor.run {
                        toast(
                            type: .info,
                            title: t("wallet__toast_received_transaction_replaced_title"),
                            description: t("wallet__toast_received_transaction_replaced_description"),
                            accessibilityIdentifier: "ReceivedTransactionReplacedToast"
                        )
                    }
                } else {
                    await MainActor.run {
                        toast(
                            type: .info,
                            title: t("wallet__toast_transaction_replaced_title"),
                            description: t("wallet__toast_transaction_replaced_description"),
                            accessibilityIdentifier: "TransactionReplacedToast"
                        )
                    }
                }
            }
        case let .onchainTransactionReorged(txid):
            Logger.warn("Transaction reorged: \(txid)")
            toast(
                type: .warning,
                title: t("wallet__toast_transaction_unconfirmed_title"),
                description: t("wallet__toast_transaction_unconfirmed_description"),
                accessibilityIdentifier: "TransactionUnconfirmedToast"
            )
        case let .onchainTransactionEvicted(txid):
            Task {
                let wasReplaced = await CoreService.shared.activity.wasTransactionReplaced(txid: txid)

                await MainActor.run {
                    if wasReplaced {
                        Logger.info("Transaction \(txid) was replaced, skipping evicted toast", context: "AppViewModel")
                        return
                    }

                    Logger.warn("Transaction removed from mempool: \(txid)")
                    toast(
                        type: .warning,
                        title: t("wallet__toast_transaction_removed_title"),
                        description: t("wallet__toast_transaction_removed_description"),
                        accessibilityIdentifier: "TransactionRemovedToast"
                    )
                }
            }

        // MARK: Splice Events

        case .splicePending, .spliceFailed:
            break

        // MARK: Sync Events

        case let .syncProgress(syncType, progressPercent, currentBlockHeight, targetBlockHeight):
            Logger.debug("Sync progress: \(syncType) \(progressPercent)%")
        case let .syncCompleted(syncType, syncedBlockHeight):
            Logger.info("Sync completed: \(syncType) at height \(syncedBlockHeight)")

        // MARK: Balance Events

        case let .balanceChanged(oldSpendableOnchain, newSpendableOnchain, oldTotalOnchain, newTotalOnchain, oldLightning, newLightning):
            Logger.debug("Balance changed: onchain \(oldSpendableOnchain)->\(newSpendableOnchain) lightning \(oldLightning)->\(newLightning)")
        }
    }
}

// MARK: - Timed Sheets

extension AppViewModel {
    func ignoreAppUpdate() {
        appUpdateIgnoreTimestamp = Date().timeIntervalSince1970
    }

    func ignoreBackup() {
        backupIgnoreTimestamp = Date().timeIntervalSince1970
    }

    func ignoreHighBalance() {
        highBalanceIgnoreCount += 1
        highBalanceIgnoreTimestamp = Date().timeIntervalSince1970
    }
}
