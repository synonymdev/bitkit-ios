import BitkitCore
import LDKNode
import SwiftUI

struct TransferUiState {
    var order: IBtOrder?
    var defaultOrder: IBtOrder?
    var isAdvanced: Bool = false
}

struct TransferValues {
    var defaultLspBalance: UInt64 = 0
    var minLspBalance: UInt64 = 0
    var maxLspBalance: UInt64 = 0
    var maxClientBalance: UInt64 = 0
}

/// Limits/flags for the hardware-wallet transfer-to-spending flow, sourced from the device balance.
struct HwSpendingState: Equatable {
    var isLoading = false
    var isSigning = false
    var hasPendingBroadcast = false
    var maxAllowedToSend: UInt64 = 0
    var balanceAfterFee: UInt64 = 0
    var quarterAmount: UInt64 = 0
}

private struct PendingHwFundingBroadcast {
    let orderId: String
    let deviceId: String
    let address: String
    let amountSats: UInt64
    let signedTx: HwFundingSignedTx

    func matches(order: IBtOrder, deviceId: String, address: String) -> Bool {
        orderId == order.id &&
            self.deviceId == deviceId &&
            self.address == address &&
            amountSats == order.feeSat
    }
}

/// A recoverable failure surfaced by the hardware-wallet transfer flow. The Sign screen maps each
/// case to the matching localized toast.
enum HwTransferError: Error, Equatable {
    /// Reconnect failed. `isBluetooth` selects the softer INFO toast for a known BLE device
    /// (advertises intermittently — "check that it is unlocked and try again") vs the ERROR toast.
    case reconnect(isBluetooth: Bool)
    case signingTimeout
    case broadcastUncertain
    case funding(String?)
    case generic(String?)
}

/// The hardware-wallet funding capability the transfer flow needs. Implemented by `HwWalletManager`;
/// declared as a protocol so the flow stays testable.
@MainActor
protocol HwTransferFunding: Sendable {
    func getFundingAccount(deviceId: String, addressType: AddressScriptType) throws -> HwFundingAccount
    func maxSpendableFunding(
        deviceId: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType: AddressScriptType
    ) async throws -> UInt64
    func composeFundingTransaction(
        deviceId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType
    ) async throws -> HwFundingTransaction
    func signFunding(deviceId: String, funding: HwFundingTransaction) async throws -> HwFundingSignedTx
    func broadcastFunding(serializedTx: String) async throws -> String
}

/// The device-session capability the transfer flow needs for on-device signing. Implemented by
/// `TrezorManager`.
@MainActor
protocol HwTransferConnecting: Sendable {
    func ensureConnected(deviceId: String) async throws
    func disconnectStaleSession(deviceId: String) async
    /// Whether the device is a known Bluetooth device, so a reconnect failure can show the softer
    /// BLE "check that it is unlocked and try again" toast instead of the generic reconnect error.
    func isKnownBluetoothDevice(deviceId: String) -> Bool
    /// Best-effort pre-connect when the sign screen appears, so tapping Open Trezor Connect is less
    /// likely to hit a cold reconnect. Fire-and-forget.
    func warmUpConnection(deviceId: String)
}

@MainActor
class TransferViewModel: ObservableObject {
    @Published var uiState = TransferUiState()
    @Published var lightningSetupStep: Int = 0
    @Published var transferValues = TransferValues()
    @Published var selectedChannelIds: [String] = []
    @Published var channelsToClose: [ChannelDetails] = []
    @Published var transferUnavailable = false

    /// Hardware-wallet transfer-to-spending state.
    @Published var hwSpending = HwSpendingState()
    /// Bumped when a hardware funding tx is signed + broadcast, so the Sign screen advances.
    @Published var hwSignedEvent = 0
    /// A recoverable hardware transfer failure the Sign screen should toast, then clear.
    @Published var hwTransferError: HwTransferError?

    private let coreService: CoreService
    private let lightningService: LightningService
    private let currencyService: CurrencyService
    private let transferService: TransferService
    private let sheetViewModel: SheetViewModel
    private let onBalanceRefresh: (() async -> Void)?
    /// The device-signing orchestration for a hardware-wallet transfer; nil when the HW capabilities
    /// aren't injected (previews/plain init).
    private let hwSigner: HwFundingSigner?

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var hwSignTask: Task<Void, Never>?
    private var pendingHwFundingBroadcast: PendingHwFundingBroadcast?

    private let retryInterval: TimeInterval = 60 // 1 min
    private let giveUpInterval: TimeInterval = 30 * 60 // 30 min
    private var coopCloseRetryTask: Task<Void, Never>?

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared,
        transferService: TransferService,
        sheetViewModel: SheetViewModel,
        hwFunding: HwTransferFunding? = nil,
        hwConnecting: HwTransferConnecting? = nil,
        hwFeeRateProvider: (() async -> UInt64?)? = nil,
        hwAddressProvider: (() async throws -> String)? = nil,
        hwTimeouts: (reconnect: Double, compose: Double, sign: Double, broadcast: Double) = (reconnect: 30, compose: 45, sign: 120, broadcast: 120),
        onBalanceRefresh: (() async -> Void)? = nil
    ) {
        self.coreService = coreService
        self.lightningService = lightningService
        self.currencyService = currencyService
        self.transferService = transferService
        self.sheetViewModel = sheetViewModel
        self.onBalanceRefresh = onBalanceRefresh
        if let hwFunding, let hwConnecting {
            hwSigner = HwFundingSigner(
                funding: hwFunding,
                connecting: hwConnecting,
                feeRateProvider: hwFeeRateProvider ?? { nil },
                addressProvider: hwAddressProvider ?? { throw AppError(message: "No address provider", debugMessage: "") },
                timeouts: hwTimeouts
            )
        } else {
            hwSigner = nil
        }
    }

    /// Convenience initializer for testing and previews
    convenience init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared,
        sheetViewModel: SheetViewModel = SheetViewModel()
    ) {
        let transferService = TransferService(
            lightningService: lightningService,
            blocktankService: coreService.blocktank
        )
        self.init(
            coreService: coreService,
            lightningService: lightningService,
            currencyService: currencyService,
            transferService: transferService,
            sheetViewModel: sheetViewModel
        )
    }

    /// Convenience initializer for hardware-wallet transfer tests. Builds the `TransferService`
    /// inside the app module so callers don't construct cross-module service types.
    convenience init(
        hwFunding: HwTransferFunding?,
        hwConnecting: HwTransferConnecting?,
        hwFeeRateProvider: (() async -> UInt64?)? = nil,
        hwAddressProvider: (() async throws -> String)? = nil,
        hwTimeouts: (reconnect: Double, compose: Double, sign: Double, broadcast: Double) = (reconnect: 30, compose: 45, sign: 120, broadcast: 120),
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        sheetViewModel: SheetViewModel = SheetViewModel()
    ) {
        let transferService = TransferService(
            lightningService: lightningService,
            blocktankService: coreService.blocktank
        )
        self.init(
            coreService: coreService,
            lightningService: lightningService,
            transferService: transferService,
            sheetViewModel: sheetViewModel,
            hwFunding: hwFunding,
            hwConnecting: hwConnecting,
            hwFeeRateProvider: hwFeeRateProvider,
            hwAddressProvider: hwAddressProvider,
            hwTimeouts: hwTimeouts
        )
    }

    deinit {
        Task { @MainActor [weak self] in
            Logger.debug("Stopping poll for order")
            self?.stopPolling()
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Calculates the total value of channels connected to Blocktank nodes
    func totalBtChannelsValueSats(blocktankInfo: IBtInfo?) -> UInt64 {
        guard let channels = lightningService.channels else { return 0 }
        guard let btNodeIds = blocktankInfo?.nodes.map(\.pubkey) else { return 0 }

        let btChannels = channels.filter { channel in
            btNodeIds.contains(channel.counterpartyNodeId)
        }

        return btChannels.reduce(0) { sum, channel in
            sum + channel.channelValueSats
        }
    }

    func onOrderCreated(order: IBtOrder) {
        clearPendingHwFundingBroadcast()
        uiState.order = order
        uiState.isAdvanced = false
        uiState.defaultOrder = nil
    }

    func onAdvancedOrderCreated(order: IBtOrder) {
        clearPendingHwFundingBroadcast()
        let defaultOrder = uiState.order
        uiState.order = order
        uiState.defaultOrder = defaultOrder
        uiState.isAdvanced = true
    }

    func displayOrder(for order: IBtOrder) -> IBtOrder {
        uiState.order ?? order
    }

    func payOrder(
        order: IBtOrder,
        speed: TransactionSpeed,
        txFee: UInt64,
        satsPerVbyte: UInt32,
        utxosToSpend: [SpendableUtxo]? = nil,
        isMaxAmount: Bool = false,
        maxSendableAmount: UInt64? = nil
    ) async throws {
        guard let address = order.payment?.onchain?.address else {
            throw AppError(message: "Order payment onchain address is nil", debugMessage: nil)
        }

        let preTransferOnchainSats = lightningService.balances?.totalOnchainBalanceSats ?? 0

        // Verify we can afford the transfer when using sendAll
        if isMaxAmount, let maxSendable = maxSendableAmount, maxSendable < order.feeSat {
            throw AppError(
                message: t("other__pay_insufficient_savings"),
                debugMessage: "Fee rate changed. Max sendable: \(maxSendable), order requires: \(order.feeSat)"
            )
        }

        // For sendAll (change would be dust), send entire balance
        // Otherwise, send exact order.feeSat amount
        let txid = try await lightningService.send(
            address: address,
            sats: order.feeSat,
            satsPerVbyte: satsPerVbyte,
            utxosToSpend: utxosToSpend,
            isMaxAmount: isMaxAmount
        )

        let txTotalSats = order.feeSat + txFee

        // Pre-activity metadata lets the LDK activity sync recognize this send as a transfer.
        let currentTime = UInt64(Date().timeIntervalSince1970)
        let preActivityMetadata = BitkitCore.PreActivityMetadata(
            walletId: WalletScope.default,
            paymentId: txid,
            tags: [],
            paymentHash: nil,
            txId: txid,
            address: address,
            isReceive: false,
            feeRate: UInt64(satsPerVbyte),
            isTransfer: true,
            channelId: nil,
            createdAt: currentTime
        )
        try? await coreService.activity.addPreActivityMetadata(preActivityMetadata)

        await fundPaidOrder(
            order: order,
            txId: txid,
            txTotalSats: txTotalSats,
            preTransferOnchainSats: preTransferOnchainSats
        )
    }

    /// Records a paid order and starts watching it, after the funding tx was broadcast (local LDK
    /// send or hardware-signed). For the hardware path, also creates the pending on-chain activity
    /// (the tx is broadcast externally, so LDK's own activity sync won't surface it).
    private func fundPaidOrder(
        order: IBtOrder,
        txId: String,
        createTransferActivity: Bool = false,
        fee: UInt64 = 0,
        feeRate: UInt64 = 0,
        txTotalSats: UInt64? = nil,
        preTransferOnchainSats: UInt64? = nil
    ) async {
        do {
            let transferId = try await transferService.createTransfer(
                type: .toSpending,
                amountSats: order.clientBalanceSat,
                fundingTxId: txId,
                lspOrderId: order.id,
                txTotalSats: txTotalSats,
                preTransferOnchainSats: preTransferOnchainSats
            )
            Logger.info("Created transfer tracking record: \(transferId)", context: "TransferViewModel")
        } catch {
            Logger.error("Failed to create transfer tracking record", context: error.localizedDescription)
            // Don't throw - we still want to continue with the order
        }

        if createTransferActivity {
            await transferService.createPendingToSpendingActivity(order: order, txId: txId, fee: fee, feeRate: feeRate)
        }

        lightningSetupStep = 0
        await onBalanceRefresh?()
        watchOrder(orderId: order.id)
    }

    /// Starts watching an order from app restart (when no UI state is set)
    func startWatchingOrderFromRestart(_ order: IBtOrder) async {
        Logger.info("Starting to watch order from restart: \(order.id)")

        // Set the order in UI state so the watching logic works
        uiState.order = order
        uiState.isAdvanced = false
        uiState.defaultOrder = nil

        // Start watching the order
        watchOrder(orderId: order.id)
    }

    private func watchOrder(orderId: String, frequencyMs: Double = 15000) {
        stopPolling()

        let frequencySecs = frequencyMs / 1000.0
        Logger.debug("Starting to watch order \(orderId)")

        refreshTimer = Timer.scheduledTimer(withTimeInterval: frequencySecs, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshTask?.cancel()
                refreshTask = Task { @MainActor [weak self] in
                    guard let self else { return }

                    do {
                        Logger.debug("Refreshing order \(orderId)")
                        let orders = try await coreService.blocktank.orders(orderIds: [orderId], refresh: true)
                        guard let order = orders.first else {
                            Logger.error("Order not found \(orderId)", context: "TransferViewModel")
                            return
                        }

                        let step = try await updateOrder(order: order)
                        lightningSetupStep = step
                        Logger.debug("LN setup step: \(step)")

                        if order.state2 == .expired {
                            Logger.error("Order expired \(orderId)", context: "TransferViewModel")
                            stopPolling()
                            return
                        }

                        if step > 2 {
                            Logger.debug("Order settled, stopping polling")

                            // Sync transfer states when order completes
                            try? await transferService.syncTransferStates()

                            stopPolling()
                            return
                        }
                    } catch {
                        Logger.error(error, context: "Failed to watch order")
                        stopPolling()
                    }
                }
            }
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let orders = try await coreService.blocktank.orders(orderIds: [orderId], refresh: true)
                guard let order = orders.first else {
                    Logger.error("Order not found \(orderId)", context: "TransferViewModel")
                    return
                }

                let step = try await updateOrder(order: order)
                lightningSetupStep = step
            } catch {
                Logger.error(error, context: "Failed in initial order check")
                stopPolling()
            }
        }
    }

    private func updateOrder(order: IBtOrder) async throws -> Int {
        var currentStep = 0

        if order.channel != nil {
            do {
                try await transferService.syncTransferStates()
            } catch {
                Logger.error("Failed to sync transfer states after updateOrder", context: error.localizedDescription)
                // Don't throw - we don't want to fail the entire sync if transfer sync fails
            }

            return 3
        }

        switch order.state2 {
        case .created:
            currentStep = 0

        case .paid:
            currentStep = 1

            do {
                _ = try await coreService.blocktank.open(orderId: order.id)
            } catch {
                Logger.error("Error opening channel: \(error.localizedDescription)", context: "TransferViewModel")
            }

        case .executed:
            currentStep = 2

        default:
            break
        }

        return currentStep
    }

    func onDefaultClick() {
        clearPendingHwFundingBroadcast()
        let defaultOrder = uiState.defaultOrder
        uiState.order = defaultOrder
        uiState.defaultOrder = nil
        uiState.isAdvanced = false
    }

    // MARK: - Hardware Wallet Transfer

    /// Compute the available/MAX/quarter limits for a hardware-wallet transfer: the signer resolves
    /// the device's native-segwit balance minus an on-chain fee reserve, then the shared
    /// spending-limit calculation clamps it to the LSP receiving cap.
    func updateHwLimits(
        deviceId: String,
        blocktankInfo: IBtInfo?,
        estimateOrderFee: @escaping (_ clientBalance: UInt64, _ lspBalance: UInt64) async throws
            -> (networkFeeSat: UInt64, serviceFeeSat: UInt64)
    ) async {
        guard let hwSigner else { return }
        hwSpending = HwSpendingState(isLoading: true)

        let availability: HwFundingSigner.Availability
        do {
            availability = try await hwSigner.availability(deviceId: deviceId)
        } catch {
            hwSpending = HwSpendingState(isLoading: false)
            hwTransferError = .generic((error as? AppError)?.message ?? error.localizedDescription)
            return
        }

        do {
            let (avail, maxAmount) = try await calculateSpendingLimits(
                onchainAvailable: availability.available,
                lspMaxClientBalance: blocktankInfo?.options.maxClientBalanceSat,
                transferValues: { self.calculateTransferValues(clientBalanceSat: $0, blocktankInfo: blocktankInfo) },
                estimateOrderFee: estimateOrderFee
            )
            hwSpending.balanceAfterFee = avail
            hwSpending.maxAllowedToSend = maxAmount
            hwSpending.quarterAmount = min(availability.balanceSats / 4, maxAmount)
        } catch {
            hwSpending.balanceAfterFee = 0
            hwSpending.maxAllowedToSend = 0
            hwSpending.quarterAmount = 0
        }

        hwSpending.isLoading = false
    }

    /// Pay for the order by composing and signing the funding send on the Trezor (via the signer),
    /// then record and watch it. Coordination only — the device orchestration lives in `HwFundingSigner`.
    func onTransferToSpendingHwConfirm(order: IBtOrder, deviceId: String) {
        guard !hwSpending.isSigning else { return }
        guard let hwSigner else {
            hwTransferError = .generic(t("common__error"))
            return
        }
        guard let address = order.payment?.onchain?.address, !address.isEmpty else {
            hwTransferError = .generic(t("common__error"))
            return
        }

        hwSpending.isSigning = true
        hwTransferError = nil

        hwSignTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.hwSpending.isSigning = false
                self.hwSignTask = nil
            }

            do {
                let signedTx: HwFundingSignedTx
                if let pending = pendingHwFundingBroadcast, pending.matches(order: order, deviceId: deviceId, address: address) {
                    signedTx = pending.signedTx
                } else {
                    signedTx = try await hwSigner.prepareSignedFunding(order: order, deviceId: deviceId, address: address)
                    pendingHwFundingBroadcast = PendingHwFundingBroadcast(
                        orderId: order.id,
                        deviceId: deviceId,
                        address: address,
                        amountSats: order.feeSat,
                        signedTx: signedTx
                    )
                    hwSpending.hasPendingBroadcast = true
                }
                let result = try await hwSigner.broadcastSignedFunding(signedTx)
                clearPendingHwFundingBroadcast()
                await fundPaidOrder(
                    order: order,
                    txId: result.txId,
                    createTransferActivity: true,
                    fee: result.miningFeeSats,
                    feeRate: result.feeRate
                )
                hwSignedEvent += 1
            } catch is CancellationError {
                // User dismissed the flow — no toast.
            } catch let error as HwTransferError {
                self.handleHardwareTransferFailure(error, deviceId: deviceId)
            } catch {
                if error.isTrezorUserCancellation() {
                    Logger.info("Hardware transfer cancelled on device '\(deviceId)'", context: "TransferViewModel")
                    return
                }
                hwTransferError = .generic((error as? AppError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Pre-connect the hardware device when the sign screen appears, mirroring Android's warm-up, so
    /// tapping Open Trezor Connect is less likely to hit a cold reconnect. Best-effort no-op without
    /// the HW capabilities.
    func warmUpHardwareConnection(deviceId: String) {
        guard !hwSpending.hasPendingBroadcast else { return }
        hwSigner?.warmUp(deviceId: deviceId)
    }

    /// Cancel an in-flight hardware signing task when the user abandons the sign flow, so a later
    /// on-device approval can't still sign/broadcast/record. Idempotent.
    func cancelHwSigning() {
        hwSignTask?.cancel()
        hwSignTask = nil
        hwSpending.isSigning = false
    }

    private func clearPendingHwFundingBroadcast() {
        pendingHwFundingBroadcast = nil
        hwSpending.hasPendingBroadcast = false
    }

    private func handleHardwareTransferFailure(_ error: HwTransferError, deviceId: String) {
        switch error {
        case .reconnect:
            Logger.error("Failed to reconnect hardware device '\(deviceId)'", context: "TransferViewModel")
        case .signingTimeout:
            Logger.warn("Timed out hardware transfer signing for '\(deviceId)'", context: "TransferViewModel")
        case .broadcastUncertain:
            Logger.warn("Hardware funding broadcast timed out (uncertain) for '\(deviceId)'", context: "TransferViewModel")
        case let .funding(message):
            Logger.warn("Failed to compose hardware funding for '\(deviceId)': \(message ?? "")", context: "TransferViewModel")
        case .generic:
            break
        }
        hwTransferError = error
    }

    // MARK: - Balance Calculation

    /// Calculates channel liquidity options using bitkit-core
    func calculateTransferValues(clientBalanceSat: UInt64, blocktankInfo: IBtInfo?) -> TransferValues {
        guard let blocktankInfo else {
            return TransferValues()
        }

        guard let rates = currencyService.loadCachedRates(),
              let eurRate = currencyService.getCurrentRate(for: "EUR", from: rates)
        else {
            Logger.error("Failed to get rates for calculateTransferValues", context: "TransferViewModel")
            return TransferValues()
        }

        let satsPerEur = currencyService.convertFiatToSats(fiatValue: 1, rate: eurRate)
        let existingChannelsTotalSat = totalBtChannelsValueSats(blocktankInfo: blocktankInfo)

        let params = ChannelLiquidityParams(
            clientBalanceSat: clientBalanceSat,
            existingChannelsTotalSat: existingChannelsTotalSat,
            minChannelSizeSat: blocktankInfo.options.minChannelSizeSat,
            maxChannelSizeSat: blocktankInfo.options.maxChannelSizeSat,
            satsPerEur: satsPerEur
        )

        let options = BitkitCore.calculateChannelLiquidityOptions(params: params)

        return TransferValues(
            defaultLspBalance: options.defaultLspBalanceSat,
            minLspBalance: options.minLspBalanceSat,
            maxLspBalance: options.maxLspBalanceSat,
            maxClientBalance: options.maxClientBalanceSat
        )
    }

    func updateTransferValues(clientBalanceSat: UInt64, blocktankInfo: IBtInfo?) {
        transferValues = calculateTransferValues(clientBalanceSat: clientBalanceSat, blocktankInfo: blocktankInfo)
    }

    /// Calculates the max amount transferable to spending and the value to display as "Available".
    ///
    /// The prospective client balance is clamped to the LSP's `maxClientBalanceSat` before
    /// computing liquidity options: an on-chain balance larger than the LSP's max channel size
    /// otherwise makes the liquidity calculation report `maxClientBalanceSat = 0` (the balance
    /// already saturates the channel), collapsing the spendable amount to zero and stranding the
    /// funds on-chain.
    ///
    /// - `transferValues`: liquidity options for a given client balance (prod: `calculateTransferValues`)
    /// - `estimateOrderFee`: Blocktank order fee for a given client/LSP balance
    func calculateSpendingLimits(
        onchainAvailable: UInt64,
        lspMaxClientBalance: UInt64?,
        transferValues: (_ clientBalance: UInt64) -> TransferValues,
        estimateOrderFee: (_ clientBalance: UInt64, _ lspBalance: UInt64) async throws -> (networkFeeSat: UInt64, serviceFeeSat: UInt64)
    ) async rethrows -> (available: UInt64, max: UInt64) {
        // First pass: estimate the LSP fee against the full on-chain balance.
        let values1 = transferValues(onchainAvailable)
        let lspBalance1 = max(values1.defaultLspBalance, values1.minLspBalance)
        let fee1 = try await estimateOrderFee(onchainAvailable, lspBalance1)
        let initialFees = fee1.networkFeeSat + fee1.serviceFeeSat
        let balanceAfterLspFee = onchainAvailable > initialFees ? onchainAvailable - initialFees : 0

        let cappedClientBalance: UInt64 = {
            guard let cap = lspMaxClientBalance, cap > 0 else { return balanceAfterLspFee }
            return min(balanceAfterLspFee, cap)
        }()

        // Second pass with the clamped balance.
        let values2 = transferValues(cappedClientBalance)
        guard values2.maxClientBalance > 0 else { return (0, 0) }
        let lspBalance2 = max(values2.defaultLspBalance, values2.minLspBalance)
        let fee2 = try await estimateOrderFee(cappedClientBalance, lspBalance2)
        let finalFees = fee2.networkFeeSat + fee2.serviceFeeSat
        let afterFee = onchainAvailable > finalFees ? onchainAvailable - finalFees : 0
        let result = min(values2.maxClientBalance, afterFee)
        return (result, result)
    }

    /// Calculates max client balance accounting for LDK reserve requirement
    func getMaxClientBalance(maxChannelSize: UInt64) -> UInt64 {
        let minRemoteBalance = UInt64(Double(maxChannelSize) * 0.025)
        return maxChannelSize - minRemoteBalance
    }

    // MARK: - Manual Channel Opening

    /// Opens a manual channel and tracks the transfer
    /// - Parameters:
    ///   - peer: The Lightning peer to open the channel with
    ///   - amountSats: The channel funding amount in satoshis
    ///   - onEvent: Closure to register an event listener (receives eventId and handler)
    ///   - removeEvent: Closure to remove an event listener (receives eventId)
    /// - Returns: Tuple containing the channel ID and optional funding transaction ID
    /// - Throws: Error if channel opening fails
    func openManualChannel(
        peer: LnPeer,
        amountSats: UInt64,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async throws -> (channelId: String, fundingTxId: String?) {
        // Open the channel - this returns the user channel ID
        let userChannelId = try await lightningService.openChannel(
            peer: peer,
            channelAmountSats: amountSats
        )

        Logger.info("Channel opened successfully with user channel ID: \(userChannelId)", context: "TransferViewModel")

        // Wait for the channel pending event to capture both the actual channel ID and funding tx
        let (actualChannelId, fundingTxId) = await Self.waitForChannelPendingEvent(
            userChannelId: userChannelId,
            onEvent: onEvent,
            removeEvent: removeEvent
        )

        guard let actualChannelId else {
            throw AppError(
                message: "Timeout waiting for channel pending event",
                debugMessage: "Did not receive channelPending event for userChannelId: \(userChannelId)"
            )
        }

        Logger.info(
            "Captured actual channel ID: \(actualChannelId) and fundingTxId: \(fundingTxId ?? "nil")",
            context: "TransferViewModel"
        )

        // Create transfer tracking record with the ACTUAL channel ID (not user channel ID)
        do {
            let transferId = try await transferService.createTransfer(
                type: .toSpending,
                amountSats: amountSats,
                channelId: actualChannelId,
                fundingTxId: fundingTxId
            )
            Logger.info(
                "Created transfer tracking record: \(transferId) with channelId: \(actualChannelId) fundingTxId: \(fundingTxId ?? "nil")",
                context: "TransferViewModel"
            )
        } catch {
            Logger.error("Failed to create transfer tracking record", context: error.localizedDescription)
            // Don't throw - channel is already open
        }

        return (actualChannelId, fundingTxId)
    }

    /// Waits for a channel pending event and captures both the channel ID and funding transaction ID
    /// - Parameters:
    ///   - userChannelId: The user channel ID returned from openChannel
    ///   - onEvent: Closure to register an event listener
    ///   - removeEvent: Closure to remove an event listener
    /// - Returns: Tuple with actual channel ID and funding transaction ID (both nil if timeout)
    private static func waitForChannelPendingEvent(
        userChannelId: String,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async -> (channelId: String?, fundingTxId: String?) {
        let channelCapture = ChannelPendingCapture()
        let eventId = "manual-channel-funding-\(userChannelId)"

        onEvent(eventId) { event in
            if case let .channelPending(
                eventChannelId,
                eventUserChannelId,
                _,
                _,
                fundingTxo
            ) = event {
                // Match by user channel ID
                if eventUserChannelId.description == userChannelId {
                    Task {
                        await channelCapture.setChannelData(
                            channelId: eventChannelId.description,
                            fundingTxId: fundingTxo.txid.description
                        )
                        Logger.debug(
                            "Captured channel pending event: channelId=\(eventChannelId.description) userChannelId=\(userChannelId) fundingTxId=\(fundingTxo.txid.description)",
                            context: "TransferViewModel"
                        )
                    }
                }
            }
        }

        let (channelId, fundingTxId) = await waitForChannelData(
            capture: channelCapture,
            maxAttempts: 10,
            initialDelayMs: 50
        )

        removeEvent(eventId)

        return (channelId, fundingTxId)
    }

    /// Wait for channel data (channel ID and funding tx) with exponential backoff
    /// - Parameters:
    ///   - capture: The actor holding the channel data
    ///   - maxAttempts: Maximum number of polling attempts
    ///   - initialDelayMs: Initial delay in milliseconds (will be doubled each attempt)
    /// - Returns: Tuple with channel ID and funding transaction ID (both nil if timeout)
    private static func waitForChannelData(
        capture: ChannelPendingCapture,
        maxAttempts: Int,
        initialDelayMs: UInt64
    ) async -> (channelId: String?, fundingTxId: String?) {
        var delayMs = initialDelayMs

        for attempt in 1 ... maxAttempts {
            // Check if we have the channel data
            if let data = await capture.getChannelData() {
                Logger.debug(
                    "Got channel data on attempt \(attempt): channelId=\(data.channelId)",
                    context: "TransferViewModel"
                )
                return (data.channelId, data.fundingTxId)
            }

            // Don't sleep after the last attempt
            guard attempt < maxAttempts else { break }

            // Sleep with exponential backoff
            let delayNs = delayMs * 1_000_000 // Convert ms to nanoseconds
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                Logger.debug("Sleep interrupted while waiting for channel data", context: "TransferViewModel")
                break
            }

            // Exponential backoff: double the delay, max 2 seconds
            delayMs = min(delayMs * 2, 2000)
        }

        return (nil, nil)
    }

    // MARK: - Savings Transfer Methods

    func setSelectedChannelIds(_ ids: [String]) {
        selectedChannelIds = ids
    }

    func onTransferToSavingsConfirm(channels: [ChannelDetails]) {
        selectedChannelIds = []
        channelsToClose = channels
    }

    func closeSelectedChannels() async throws -> [ChannelDetails] {
        return try await closeChannels(channels: channelsToClose)
    }

    func closeChannels(channels: [ChannelDetails]) async throws -> [ChannelDetails] {
        var failedChannels: [ChannelDetails] = []
        var successfulChannels: [ChannelDetails] = []

        // Close channels in parallel and track which ones succeeded
        try await withThrowingTaskGroup(of: ChannelDetails?.self) { group in
            for channel in channels {
                group.addTask {
                    do {
                        Logger.info("Closing channel: \(channel.channelId)")
                        try await self.lightningService.closeChannel(channel)
                        return nil
                    } catch {
                        Logger.error("Error closing channel: \(channel.channelId)", context: error.localizedDescription)
                        return channel
                    }
                }
            }

            for try await result in group {
                if let failedChannel = result {
                    failedChannels.append(failedChannel)
                }
            }
        }

        // Determine which channels closed successfully
        successfulChannels = channels.filter { channel in
            !failedChannels.contains { $0.channelId == channel.channelId }
        }

        // Create transfer tracking records only for successfully closed channels
        for channel in successfulChannels {
            do {
                let transferId = try await transferService.createTransfer(
                    type: .toSavings,
                    amountSats: channel.amountOnClose,
                    channelId: channel.channelId.description
                )
                Logger.info("Created transfer tracking record for channel closure: \(transferId)", context: "TransferViewModel")
            } catch {
                Logger.error("Failed to create transfer tracking record for channel: \(channel.channelId)", context: error.localizedDescription)
                // Don't fail the entire operation - the channel is already closed
            }
        }

        // Sync transfer states after attempting closures
        try? await transferService.syncTransferStates()

        await onBalanceRefresh?()

        return failedChannels
    }

    func startCoopCloseRetries(channels: [ChannelDetails], startTime: Date = Date()) {
        channelsToClose = channels
        coopCloseRetryTask?.cancel()

        coopCloseRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let giveUpTime = startTime.addingTimeInterval(giveUpInterval)

            while !Task.isCancelled && Date() < giveUpTime {
                Logger.info("Trying coop close...")
                do {
                    let channelsFailedToCoopClose = try await closeChannels(channels: channelsToClose)

                    if channelsFailedToCoopClose.isEmpty {
                        channelsToClose = []
                        Logger.info("Coop close success.")

                        // Final sync after successful closure
                        try? await transferService.syncTransferStates()
                        await onBalanceRefresh?()

                        return
                    } else {
                        channelsToClose = channelsFailedToCoopClose
                        Logger.info("Coop close failed: \(channelsFailedToCoopClose.map(\.channelId))")
                    }
                } catch {
                    Logger.error("Error during coop close retry", context: error.localizedDescription)
                }

                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            }

            Logger.info("Giving up on coop close. Checking if force close is possible.")

            // Check if any channels can be force closed (filter out trusted peers)
            let (_, nonTrustedChannels) = lightningService.separateTrustedChannels(channelsToClose)

            if !nonTrustedChannels.isEmpty {
                sheetViewModel.showSheet(.forceTransfer)
            } else {
                Logger.warn("All channels are with trusted peers. Cannot force close.")
                channelsToClose.removeAll()
                transferUnavailable = true
            }
        }
    }

    /// Force close all channels that failed to cooperatively close
    /// Returns the number of trusted peer channels that were skipped
    func forceCloseChannel() async throws -> Int {
        guard !channelsToClose.isEmpty else {
            Logger.warn("No channels to force close")
            return 0
        }

        // Filter out trusted peer channels (cannot force close LSP channels)
        let (trustedChannels, nonTrustedChannels) = lightningService.separateTrustedChannels(channelsToClose)

        if !trustedChannels.isEmpty {
            Logger.warn("Skipping \(trustedChannels.count) trusted peer channel(s)")
        }

        guard !nonTrustedChannels.isEmpty else {
            channelsToClose.removeAll()
            throw AppError(
                message: "Cannot force close channels with trusted peer",
                debugMessage: "All channels are with trusted peers (LSP). Force close is disabled."
            )
        }

        Logger.info("Force closing \(nonTrustedChannels.count) channel(s)")

        var errors: [(channelId: String, error: Error)] = []
        var successfulChannels: [ChannelDetails] = []

        for channel in nonTrustedChannels {
            do {
                // Force close the channel first
                try await lightningService.closeChannel(
                    channel,
                    force: true,
                    forceCloseReason: "User requested force close after cooperative close failed"
                )
                Logger.info("Successfully initiated force close for channel: \(channel.channelId)")
                successfulChannels.append(channel)

                // Only create transfer tracking record if force close succeeded
                do {
                    let transferId = try await transferService.createTransfer(
                        type: .toSavings,
                        amountSats: channel.amountOnClose,
                        channelId: channel.channelId.description
                    )
                    Logger.info("Created transfer tracking record for force channel closure: \(transferId)", context: "TransferViewModel")
                } catch {
                    Logger.error(
                        "Failed to create transfer tracking record for force-closed channel: \(channel.channelId)",
                        context: error.localizedDescription
                    )
                    // Don't fail the entire operation - the channel is already force-closed
                }
            } catch {
                Logger.error("Failed to force close channel: \(channel.channelId)", context: error.localizedDescription)
                errors.append((channelId: channel.channelId, error: error))
            }
        }

        // Remove successfully closed channels and trusted peer channels from the list
        channelsToClose.removeAll { channel in
            successfulChannels.contains { $0.channelId == channel.channelId } ||
                trustedChannels.contains { $0.channelId == channel.channelId }
        }

        try? await transferService.syncTransferStates()

        await onBalanceRefresh?()

        // If any errors occurred, throw an aggregated error
        if !errors.isEmpty {
            let errorMessages = errors.map { "\($0.channelId): \($0.error.localizedDescription)" }.joined(separator: ", ")
            throw AppError(
                message: "Failed to force close \(errors.count) of \(errors.count + successfulChannels.count) channel(s)",
                debugMessage: errorMessages
            )
        }

        return trustedChannels.count
    }
}

/// Actor to safely capture channel data from channel pending events
/// Ensures thread-safe access when the event callback may execute on different threads
actor ChannelPendingCapture {
    struct ChannelData {
        let channelId: String
        let fundingTxId: String
    }

    private var channelData: ChannelData?

    func setChannelData(channelId: String, fundingTxId: String) {
        channelData = ChannelData(channelId: channelId, fundingTxId: fundingTxId)
    }

    func getChannelData() -> ChannelData? {
        return channelData
    }
}

// MARK: - Hardware transfer capability conformances

extension HwWalletManager: HwTransferFunding {}
extension TrezorManager: HwTransferConnecting {}
