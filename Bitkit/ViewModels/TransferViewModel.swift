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
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    private let retryInterval: TimeInterval = 60 // 1 min
    private let giveUpInterval: TimeInterval = 30 * 60 // 30 min
    private var coopCloseRetryTask: Task<Void, Never>?

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared
    ) {
        self.coreService = coreService
        self.lightningService = lightningService
        self.currencyService = currencyService
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

        _ = try await lightningService.send(address: address, sats: order.feeSat, satsPerVbyte: satsPerVbyte)
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

            Logger.info("Giving up on coop close.")
            // TODO: Show force transfer UI
        }
    }
}
