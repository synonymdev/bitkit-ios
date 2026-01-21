import BitkitCore
import Combine
import LDKNode
import SwiftUI

enum ManualEntryValidationResult: Equatable {
    case valid
    case empty
    case invalid
    case insufficientSavings
    case insufficientSpending
    case expiredLightningOnly
}

@MainActor
class AppViewModel: ObservableObject {
    // Send flow
    @Published var scannedLightningInvoice: LightningInvoice?
    @Published var scannedOnchainInvoice: OnChainInvoice?
    @Published var selectedWalletToPayFrom: WalletType = .onchain
    @Published var manualEntryInput: String = ""
    @Published var isManualEntryInputValid: Bool = false
    @Published var manualEntryValidationResult: ManualEntryValidationResult = .empty

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
    private var manualEntryValidationSequence: UInt64 = 0

    // Combine infrastructure for debounced validation
    private var manualEntryValidationCancellable: AnyCancellable?
    private let manualEntryValidationSubject = PassthroughSubject<(String, Int, Int, UInt64), Never>()

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

        setupManualEntryValidationDebounce()

        Task {
            await checkGeoStatus()
            // Check for app updates on startup
            await AppUpdateService.shared.checkForAppUpdate()
        }
    }

    private func setupManualEntryValidationDebounce() {
        manualEntryValidationCancellable = manualEntryValidationSubject
            .debounce(for: .milliseconds(1000), scheduler: DispatchQueue.main)
            .sink { [weak self] rawValue, savingsBalanceSats, spendingBalanceSats, queuedSequence in
                guard let self else { return }
                // Skip if sequence changed (reset was called or new validation queued)
                guard queuedSequence == manualEntryValidationSequence else { return }
                Task {
                    await self.performValidation(rawValue, savingsBalanceSats: savingsBalanceSats, spendingBalanceSats: spendingBalanceSats)
                }
            }
    }

    private func showValidationErrorToast(for result: ManualEntryValidationResult) {
        switch result {
        case .invalid:
            toast(
                type: .error,
                title: t("other__scan_err_decoding"),
                description: t("other__scan__error__generic"),
                accessibilityIdentifier: "InvalidAddressToast"
            )
        case .insufficientSavings:
            toast(
                type: .error,
                title: t("other__pay_insufficient_savings"),
                description: t("other__pay_insufficient_savings_description"),
                accessibilityIdentifier: "InsufficientSavingsToast"
            )
        case .insufficientSpending:
            toast(
                type: .error,
                title: t("other__pay_insufficient_spending"),
                description: t("other__pay_insufficient_savings_description"),
                accessibilityIdentifier: "InsufficientSpendingToast"
            )
        case .expiredLightningOnly:
            toast(
                type: .error,
                title: t("other__scan_err_decoding"),
                description: t("other__scan__error__expired"),
                accessibilityIdentifier: "ExpiredLightningToast"
            )
        case .valid, .empty:
            break
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

        // Workaround for duplicated BIP21 URIs (bitkit-core#63)
        if Bip21Utils.isDuplicatedBip21(uri) {
            toast(
                type: .error,
                title: t("other__scan_err_decoding"),
                description: t("other__scan__error__generic"),
                accessibilityIdentifier: "InvalidAddressToast"
            )
            return
        }

        let data = try await decode(invoice: uri)

        switch data {
        // BIP21 (Unified) invoice handling
        case let .onChain(invoice):
            // Check network first - treat wrong network as decoding error
            let addressValidation = try? validateBitcoinAddress(address: invoice.address)
            let addressNetwork: LDKNode.Network? = addressValidation.map { NetworkValidationHelper.convertNetworkType($0.network) }
            if NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: Env.network) {
                toast(
                    type: .error,
                    title: t("other__scan_err_decoding"),
                    description: t("other__scan__error__generic"),
                    accessibilityIdentifier: "InvalidAddressToast"
                )
                return
            }

            if let lnInvoice = invoice.params?["lightning"] {
                guard lightningService.status?.isRunning == true else {
                    toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                    return
                }
                // Lightning invoice param found, prefer lightning payment if possible
                if case let .lightning(lightningInvoice) = try await decode(invoice: lnInvoice) {
                    // Check lightning invoice network
                    let lnNetwork = NetworkValidationHelper.convertNetworkType(lightningInvoice.networkType)
                    let lnNetworkMatch = !NetworkValidationHelper.isNetworkMismatch(addressNetwork: lnNetwork, currentNetwork: Env.network)

                    let canSend = lightningService.canSend(amountSats: lightningInvoice.amountSatoshis)

                    if lnNetworkMatch, !lightningInvoice.isExpired, canSend {
                        handleScannedLightningInvoice(lightningInvoice, bolt11: lnInvoice, onchainInvoice: invoice)
                        return
                    }

                    // If Lightning is expired or insufficient, fall back to on-chain silently (no toast)
                }
            }

            // Fallback to on-chain if address is available
            guard !invoice.address.isEmpty else { return }

            // Check on-chain balance
            let onchainBalance = lightningService.balances?.spendableOnchainBalanceSats ?? 0
            if invoice.amountSatoshis > 0 {
                guard onchainBalance >= invoice.amountSatoshis else {
                    let amountNeeded = invoice.amountSatoshis - onchainBalance
                    toast(
                        type: .error,
                        title: t("other__pay_insufficient_savings"),
                        description: t(
                            "other__pay_insufficient_savings_amount_description",
                            variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)]
                        ),
                        accessibilityIdentifier: "InsufficientSavingsToast"
                    )
                    return
                }
            } else {
                // Zero-amount invoice: user must have some balance to proceed
                guard onchainBalance > 0 else {
                    toast(
                        type: .error,
                        title: t("other__pay_insufficient_savings"),
                        description: t("other__pay_insufficient_savings_description"),
                        accessibilityIdentifier: "InsufficientSavingsToast"
                    )
                    return
                }
            }

            handleScannedOnchainInvoice(invoice)
        case let .lightning(invoice):
            // Check network first - treat wrong network as decoding error
            let invoiceNetwork = NetworkValidationHelper.convertNetworkType(invoice.networkType)
            if NetworkValidationHelper.isNetworkMismatch(addressNetwork: invoiceNetwork, currentNetwork: Env.network) {
                toast(
                    type: .error,
                    title: t("other__scan_err_decoding"),
                    description: t("other__scan__error__generic"),
                    accessibilityIdentifier: "InvalidAddressToast"
                )
                return
            }

            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }

            guard lightningService.canSend(amountSats: invoice.amountSatoshis) else {
                let spendingBalance = lightningService.balances?.totalLightningBalanceSats ?? 0
                let amountNeeded = invoice.amountSatoshis > spendingBalance ? invoice.amountSatoshis - spendingBalance : 0
                let description = amountNeeded > 0
                    ? t("other__pay_insufficient_spending_amount_description", variables: ["amount": CurrencyFormatter.formatSats(amountNeeded)])
                    : t("other__pay_insufficient_spending_description")
                toast(
                    type: .error,
                    title: t("other__pay_insufficient_spending"),
                    description: description,
                    accessibilityIdentifier: "InsufficientSpendingToast"
                )
                return
            }

            guard !invoice.isExpired else {
                toast(
                    type: .error,
                    title: t("other__scan_err_decoding"),
                    description: t("other__scan__error__expired"),
                    accessibilityIdentifier: "ExpiredLightningToast"
                )
                return
            }

            handleScannedLightningInvoice(invoice, bolt11: uri)
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

            // Check network - treat wrong network as decoding error
            let nodeNetwork = NetworkValidationHelper.convertNetworkType(network)
            if NetworkValidationHelper.isNetworkMismatch(addressNetwork: nodeNetwork, currentNetwork: Env.network) {
                toast(
                    type: .error,
                    title: t("other__scan_err_decoding"),
                    description: t("other__scan__error__generic"),
                    accessibilityIdentifier: "InvalidAddressToast"
                )
                return
            }

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
        normalizedData.minSendable = max(1, LightningAmountConversion.satsCeil(fromMsats: normalizedData.minSendable))
        normalizedData.maxSendable = max(normalizedData.minSendable, LightningAmountConversion.satsFloor(fromMsats: normalizedData.maxSendable))

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

        let minMsats = data.minWithdrawable ?? Env.msatsPerSat
        let maxMsats = data.maxWithdrawable

        // Check if minWithdrawable > maxWithdrawable
        if minMsats > maxMsats {
            toast(
                type: .warning,
                title: t("other__lnurl_withdr_error"),
                description: t("other__lnurl_withdr_error_minmax")
            )
            return
        }

        var normalizedData = data
        let minSats = max(1, LightningAmountConversion.satsCeil(fromMsats: minMsats))
        let maxSats = max(minSats, LightningAmountConversion.satsFloor(fromMsats: maxMsats))
        normalizedData.minWithdrawable = minSats
        normalizedData.maxWithdrawable = maxSats

        // Check if we have enough receiving capacity
        let lightningBalance = lightningService.balances?.totalLightningBalanceSats ?? 0
        if lightningBalance < minSats {
            toast(
                type: .warning,
                title: t("other__lnurl_withdr_error"),
                description: t("other__lnurl_withdr_error_no_capacity")
            )
            return
        }

        lnurlWithdrawData = normalizedData
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
        resetManualEntryInput()
    }
}

// MARK: Manual entry validation

extension AppViewModel {
    func normalizeManualEntry(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }

    func resetManualEntryInput() {
        manualEntryValidationSequence &+= 1
        manualEntryInput = ""
        isManualEntryInputValid = false
        manualEntryValidationResult = .empty
    }

    /// Queue validation with debounce
    func validateManualEntryInput(_ rawValue: String, savingsBalanceSats: Int, spendingBalanceSats: Int) {
        // Increment sequence first so any pending debounced requests become stale
        manualEntryValidationSequence &+= 1
        let currentSequence = manualEntryValidationSequence

        let normalized = normalizeManualEntry(rawValue)

        // Immediately update state for empty input (no debounce needed)
        guard !normalized.isEmpty else {
            manualEntryValidationResult = .empty
            isManualEntryInputValid = false
            return
        }

        // Queue the validation with debounce, including the sequence to detect stale requests
        manualEntryValidationSubject.send((rawValue, savingsBalanceSats, spendingBalanceSats, currentSequence))
    }

    /// Perform the actual validation
    private func performValidation(_ rawValue: String, savingsBalanceSats: Int, spendingBalanceSats: Int) async {
        let currentSequence = manualEntryValidationSequence

        let normalized = normalizeManualEntry(rawValue)

        guard !normalized.isEmpty else {
            manualEntryValidationResult = .empty
            isManualEntryInputValid = false
            return
        }

        // Workaround for duplicated BIP21 URIs (bitkit-core#63)
        if Bip21Utils.isDuplicatedBip21(normalized) {
            guard currentSequence == manualEntryValidationSequence else { return }
            manualEntryValidationResult = .invalid
            isManualEntryInputValid = false
            showValidationErrorToast(for: .invalid)
            return
        }

        // Try to decode the invoice
        guard let decodedData = try? await decode(invoice: normalized) else {
            guard currentSequence == manualEntryValidationSequence else { return }
            manualEntryValidationResult = .invalid
            isManualEntryInputValid = false
            showValidationErrorToast(for: .invalid)
            return
        }

        guard currentSequence == manualEntryValidationSequence else { return }

        // Determine validation result based on invoice type and balance
        var result: ManualEntryValidationResult = .valid

        switch decodedData {
        case let .lightning(invoice):
            // Priority 0: Check network first - treat wrong network as invalid
            let invoiceNetwork = NetworkValidationHelper.convertNetworkType(invoice.networkType)
            if NetworkValidationHelper.isNetworkMismatch(addressNetwork: invoiceNetwork, currentNetwork: Env.network) {
                result = .invalid
                break
            }

            // Lightning-only invoice: check spending balance and expiry
            let amountSats = invoice.amountSatoshis

            // Priority 1: Insufficient spending balance (only check if amount > 0)
            if amountSats > 0 && spendingBalanceSats < Int(amountSats) {
                result = .insufficientSpending
            } else if invoice.isExpired {
                // Priority 2: Expired invoice (only after balance check passes)
                result = .expiredLightningOnly
            }

        case let .onChain(invoice):
            // Priority 0: Check network first - treat wrong network as invalid
            let addressValidation = try? validateBitcoinAddress(address: invoice.address)
            let addressNetwork: LDKNode.Network? = addressValidation.map { NetworkValidationHelper.convertNetworkType($0.network) }
            if NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: Env.network) {
                result = .invalid
                break
            }

            // BIP21 with potential lightning parameter
            var canPayLightning = false
            if let lnInvoice = invoice.params?["lightning"],
               case let .lightning(lightningInvoice) = try? await decode(invoice: lnInvoice)
            {
                // Check for stale request after async decode
                guard currentSequence == manualEntryValidationSequence else { return }

                // Check lightning invoice network too
                let lnNetwork = NetworkValidationHelper.convertNetworkType(lightningInvoice.networkType)
                let lnNetworkMatch = !NetworkValidationHelper.isNetworkMismatch(addressNetwork: lnNetwork, currentNetwork: Env.network)

                // Has lightning fallback - check if lightning is viable
                canPayLightning = lnNetworkMatch && !lightningInvoice.isExpired &&
                    (lightningInvoice.amountSatoshis == 0 || spendingBalanceSats >= Int(lightningInvoice.amountSatoshis))
            }

            if !canPayLightning {
                // On-chain: check savings balance
                if invoice.amountSatoshis > 0 && savingsBalanceSats < Int(invoice.amountSatoshis) {
                    result = .insufficientSavings
                } else if invoice.amountSatoshis == 0 && savingsBalanceSats == 0 {
                    // Zero-amount invoice: user must have some balance to proceed
                    result = .insufficientSavings
                }
            }

        case .lnurlPay, .lnurlWithdraw, .lnurlChannel, .lnurlAuth, .nodeId, .gift:
            // These types are valid if decoded successfully
            result = .valid

        default:
            result = .invalid
        }

        guard currentSequence == manualEntryValidationSequence else { return }

        manualEntryValidationResult = result
        isManualEntryInputValid = (result == .valid)

        // Show toast for error results
        if result != .valid && result != .empty {
            showValidationErrorToast(for: result)
        }
    }
}

// MARK: LDK Node Events

extension AppViewModel {
    func handleLdkNodeEvent(_ event: Event) {
        switch event {
        case let .paymentReceived(paymentId, paymentHash, amountMsat, customRecords):
            Task {
                if let paymentId {
                    if await CoreService.shared.activity.isActivitySeen(id: paymentId) {
                        return
                    }
                    await CoreService.shared.activity.markActivityAsSeen(id: paymentId)
                }

                await MainActor.run {
                    sheetViewModel.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .lightning, sats: amountMsat / 1000))
                }
            }
        case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            // Only relevant for channels to external nodes
            break
        case .channelReady(let channelId, userChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            if let channel = lightningService.channels?.first(where: { $0.channelId == channelId }) {
                Task {
                    let cjitOrder = try await CoreService.shared.blocktank.getCjit(channel: channel)
                    if cjitOrder != nil {
                        let amount = channel.balanceOnCloseSats
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
                            updatedAt: nil,
                            seenAt: nil
                        )

                        try await CoreService.shared.activity.insert(.lightning(ln))

                        // Show receivedTx sheet for CJIT payment
                        await MainActor.run {
                            sheetViewModel.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .lightning, sats: amount))
                        }
                    } else {
                        let channelCount = lightningService.channels?.count ?? 0
                        if channelCount == 1 {
                            toast(
                                type: .lightning,
                                title: t("lightning__channel_opened_title"),
                                description: t("lightning__channel_opened_msg"),
                                visibilityTime: 5.0,
                                accessibilityIdentifier: "SpendingBalanceReadyToast"
                            )
                        }
                    }
                }
            } else {
                let channelCount = lightningService.channels?.count ?? 0
                if channelCount == 1 {
                    toast(
                        type: .lightning,
                        title: t("lightning__channel_opened_title"),
                        description: t("lightning__channel_opened_msg"),
                        visibilityTime: 5.0,
                        accessibilityIdentifier: "SpendingBalanceReadyToast"
                    )
                }
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

                    if await CoreService.shared.activity.isOnchainActivitySeen(txid: txid) {
                        return
                    }

                    let shouldShow = await CoreService.shared.activity.shouldShowReceivedSheet(txid: txid, value: sats)
                    guard shouldShow else { return }

                    await CoreService.shared.activity.markOnchainActivityAsSeen(txid: txid)

                    await MainActor.run {
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

            if MigrationsService.shared.needsPostMigrationSync {
                Task { @MainActor in
                    try? await CoreService.shared.activity.syncLdkNodePayments(LightningService.shared.payments ?? [])
                    await CoreService.shared.activity.markAllUnseenActivitiesAsSeen()
                    await MigrationsService.shared.reapplyMetadataAfterSync()
                    try? await LightningService.shared.restart()

                    SettingsViewModel.shared.updatePinEnabledState()

                    MigrationsService.shared.cleanupAfterMigration()

                    MigrationsService.shared.needsPostMigrationSync = false
                    MigrationsService.shared.isRestoringFromRNRemoteBackup = false

                    if MigrationsService.shared.isShowingMigrationLoading {
                        MigrationsService.shared.isShowingMigrationLoading = false
                    }
                }
            }

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
