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

@MainActor
class TransferViewModel: ObservableObject {
    @Published var uiState = TransferUiState()
    @Published var lightningSetupStep: Int = 0
    @Published var transferValues = TransferValues()
    @Published var selectedChannelIds: [String] = []
    @Published var channelsToClose: [ChannelDetails] = []

    private let coreService: CoreService
    private let lightningService: LightningService
    private let currencyService: CurrencyService
    private let transferService: TransferService
    private weak var sheetViewModel: SheetViewModel?

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    private let retryInterval: TimeInterval = 60 // 1 min
    private let giveUpInterval: TimeInterval = 30 * 60 // 30 min
    private var coopCloseRetryTask: Task<Void, Never>?

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared,
        transferService: TransferService,
        sheetViewModel: SheetViewModel? = nil
    ) {
        self.coreService = coreService
        self.lightningService = lightningService
        self.currencyService = currencyService
        self.transferService = transferService
        self.sheetViewModel = sheetViewModel
    }

    /// Convenience initializer for testing and previews
    convenience init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared
    ) {
        let transferService = TransferService(
            lightningService: lightningService,
            blocktankService: coreService.blocktank
        )
        self.init(
            coreService: coreService,
            lightningService: lightningService,
            currencyService: currencyService,
            transferService: transferService
        )
    }

    deinit {
        RunLoop.main.perform { [weak self] in
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

        let totalValue = btChannels.reduce(0) { sum, channel in
            sum + channel.channelValueSats
        }

        return totalValue
    }

    func onOrderCreated(order: IBtOrder) {
        uiState.order = order
        uiState.isAdvanced = false
        uiState.defaultOrder = nil
    }

    func onAdvancedOrderCreated(order: IBtOrder) {
        let defaultOrder = uiState.order
        uiState.order = order
        uiState.defaultOrder = defaultOrder
        uiState.isAdvanced = true
    }

    func payOrder(order: IBtOrder, speed: TransactionSpeed) async throws {
        var fees = try? await coreService.blocktank.fees(refresh: true)
        if fees == nil {
            Logger.warn("Failed to fetch fresh fee rate, using cached rate.")
            fees = try await coreService.blocktank.fees(refresh: false)
        }

        guard let fees else {
            throw AppError(message: "Fees unavailable from bitkit-core", debugMessage: nil)
        }

        let satsPerVbyte = speed.getFeeRate(from: fees)

        guard let address = order.payment?.onchain?.address else {
            throw AppError(message: "Order payment onchain address is nil", debugMessage: nil)
        }

        let txid = try await lightningService.send(address: address, sats: order.feeSat, satsPerVbyte: satsPerVbyte)

        // Create transfer tracking record for spending
        do {
            let transferId = try await transferService.createTransfer(
                type: .toSpending,
                amountSats: order.clientBalanceSat,
                fundingTxId: txid,
                lspOrderId: order.id
            )
            Logger.info("Created transfer tracking record: \(transferId)", context: "TransferViewModel")
        } catch {
            Logger.error("Failed to create transfer tracking record", context: error.localizedDescription)
            // Don't throw - we still want to continue with the order
        }

        lightningSetupStep = 0
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
        let defaultOrder = uiState.defaultOrder
        uiState.order = defaultOrder
        uiState.defaultOrder = nil
        uiState.isAdvanced = false
    }

    func resetState() {
        uiState = TransferUiState()
        transferValues = TransferValues()
        selectedChannelIds = []
    }

    // MARK: - Balance Calculation Functions

    func getDefaultLspBalance(clientBalanceSat: UInt64, maxLspBalance: UInt64) -> UInt64 {
        // Get current rates
        guard let rates = currencyService.loadCachedRates(),
              let eurRate = currencyService.getCurrentRate(for: "EUR", from: rates)
        else {
            Logger.error("Failed to get rates for getDefaultLspBalance", context: "TransferViewModel")
            return 0
        }

        // Calculate thresholds in sats
        let threshold1 = currencyService.convertFiatToSats(fiatValue: 225, rate: eurRate)
        let threshold2 = currencyService.convertFiatToSats(fiatValue: 495, rate: eurRate)
        let defaultLspBalanceSats = currencyService.convertFiatToSats(fiatValue: 450, rate: eurRate)

        var lspBalance = Int64(defaultLspBalanceSats) - Int64(clientBalanceSat)

        // Ensure non-negative result
        if lspBalance < 0 {
            lspBalance = 0
        }

        if clientBalanceSat > threshold1 {
            lspBalance = Int64(clientBalanceSat)
        }

        if clientBalanceSat > threshold2 {
            lspBalance = Int64(maxLspBalance)
        }

        return min(UInt64(lspBalance), maxLspBalance)
    }

    func getMinLspBalance(clientBalance: UInt64, minChannelSize: UInt64) -> UInt64 {
        // LSP balance must be at least 2.5% of the channel size for LDK to accept (reserve balance)
        let ldkMinimum = UInt64(Double(clientBalance) * 0.025)
        // Channel size must be at least minChannelSize
        let lspMinimum = clientBalance < minChannelSize ? minChannelSize - clientBalance : 0

        return max(ldkMinimum, lspMinimum)
    }

    func getMaxClientBalance(maxChannelSize: UInt64) -> UInt64 {
        // Remote balance must be at least 2.5% of the channel size for LDK to accept (reserve balance)
        let minRemoteBalance = UInt64(Double(maxChannelSize) * 0.025)
        return maxChannelSize - minRemoteBalance
    }

    func updateTransferValues(clientBalanceSat: UInt64, blocktankInfo: IBtInfo?) {
        transferValues = calculateTransferValues(clientBalanceSat: clientBalanceSat, blocktankInfo: blocktankInfo)
    }

    func calculateTransferValues(clientBalanceSat: UInt64, blocktankInfo: IBtInfo?) -> TransferValues {
        guard let blocktankInfo else {
            return TransferValues()
        }

        // Calculate the total value of existing Blocktank channels
        let channelsSize = totalBtChannelsValueSats(blocktankInfo: blocktankInfo)

        let minChannelSizeSat = UInt64(blocktankInfo.options.minChannelSizeSat)
        let maxChannelSizeSat = UInt64(blocktankInfo.options.maxChannelSizeSat)

        // Because LSP limits constantly change depending on network fees
        // Add a 2% buffer to avoid fluctuations while making the order
        let maxChannelSize1 = UInt64(Double(maxChannelSizeSat) * 0.98)

        // The maximum channel size the user can open including existing channels
        let maxChannelSize2 = maxChannelSize1 > channelsSize ? maxChannelSize1 - channelsSize : 0
        let maxChannelSize = min(maxChannelSize1, maxChannelSize2)

        let minLspBalance = getMinLspBalance(clientBalance: clientBalanceSat, minChannelSize: minChannelSizeSat)
        let maxLspBalance = maxChannelSize > clientBalanceSat ? maxChannelSize - clientBalanceSat : 0
        let defaultLspBalance = getDefaultLspBalance(clientBalanceSat: clientBalanceSat, maxLspBalance: maxLspBalance)
        let maxClientBalance = getMaxClientBalance(maxChannelSize: maxChannelSize)

        return TransferValues(
            defaultLspBalance: defaultLspBalance,
            minLspBalance: minLspBalance,
            maxLspBalance: maxLspBalance,
            maxClientBalance: maxClientBalance
        )
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

        // Create transfer tracking records for each channel being closed
        for channel in channels {
            do {
                let transferId = try await transferService.createTransfer(
                    type: .toSavings,
                    amountSats: channel.amountOnClose,
                    channelId: channel.channelId.description
                )
                Logger.info("Created transfer tracking record for channel closure: \(transferId)", context: "TransferViewModel")
            } catch {
                Logger.error("Failed to create transfer tracking record for channel: \(channel.channelId)", context: error.localizedDescription)
                // Continue with closure even if tracking fails
            }
        }

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

        // Sync transfer states after attempting closures
        try? await transferService.syncTransferStates()

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

            Logger.info("Giving up on coop close. Showing force transfer UI.")

            // Show force transfer sheet
            sheetViewModel?.showSheet(.forceTransfer)
        }
    }

    /// Force close all channels that failed to cooperatively close
    func forceCloseChannel() async throws {
        guard !channelsToClose.isEmpty else {
            Logger.warning("No channels to force close")
            return
        }

        Logger.info("Force closing \(channelsToClose.count) channel(s)")

        for channel in channelsToClose {
            do {
                try await lightningService.closeChannel(
                    channel,
                    force: true,
                    forceCloseReason: "User requested force close after cooperative close failed"
                )
                Logger.info("Successfully initiated force close for channel: \(channel.channelId)")
            } catch {
                Logger.error("Failed to force close channel: \(channel.channelId)", context: error.localizedDescription)
                throw error
            }
        }

        // Clear the channels to close list after force closing
        channelsToClose = []

        // Sync transfer states
        try? await transferService.syncTransferStates()
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
