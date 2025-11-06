import BitkitCore
import SwiftUI

@MainActor
class BlocktankViewModel: ObservableObject {
    @Published var orders: [IBtOrder]? = nil
    @Published var cJitEntries: [IcJitEntry]? = nil
    @Published var info: IBtInfo? = nil

    // Use -1 as a sentinel value to represent nil
    @AppStorage("minCjitSats") private var minCjitSatsStorage: Int = -1

    var minCjitSats: UInt64? {
        get { minCjitSatsStorage == -1 ? nil : UInt64(minCjitSatsStorage) }
        set { minCjitSatsStorage = newValue == nil ? -1 : Int(newValue!) }
    }

    private let defaultChannelExpiryWeeks: UInt32 = 6
    private let defaultSource = "bitkit"

    @Published private(set) var isRefreshing = false

    private let coreService: CoreService
    private let lightningService: LightningService
    private let currencyService: CurrencyService
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared
    ) {
        self.coreService = coreService
        self.lightningService = lightningService
        self.currencyService = currencyService

        Task { try? await refreshInfo() }
        startPolling()
    }

    deinit {
        RunLoop.main.perform { [weak self] in
            Logger.debug("Stopping poll for orders")
            self?.stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: Env.blocktankOrderRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            refreshTask?.cancel()
            refreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await refreshOrders()
            }
        }

        // Initial refresh
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await refreshOrders()
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshInfo() async throws {
        info = try await getInfo(refresh: false) // Instant set cached info to state before refreshing
        info = try await getInfo(refresh: true)
        coreService.blocktank.notifyStateChanged()
    }

    func refreshOrders() async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        Logger.debug("Refreshing orders...")

        // Sync UI instantly from cache
        orders = try await coreService.blocktank.orders(refresh: false)
        cJitEntries = try await coreService.blocktank.cjitOrders(refresh: false)

        // The update from server
        orders = try await coreService.blocktank.orders(refresh: true)
        cJitEntries = try await coreService.blocktank.cjitOrders(refresh: true)

        Logger.debug("Orders refreshed")
        coreService.blocktank.notifyStateChanged()
    }

    func refreshOrder(id: String) async throws -> IBtOrder? {
        let refreshedOrders = try await coreService.blocktank.orders(orderIds: [id], refresh: true)
        guard let refreshedOrder = refreshedOrders.first else { return nil }

        // Update the order in the published array if it exists
        if let index = orders?.firstIndex(where: { $0.id == id }) {
            orders?[index] = refreshedOrder
        }

        coreService.blocktank.notifyStateChanged()
        return refreshedOrder
    }

    func createCjit(amountSats: UInt64, description: String) async throws -> IcJitEntry {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let lspBalance = try await getDefaultLspBalance(clientBalance: amountSats)
        let channelSizeSat = amountSats + lspBalance

        return try await coreService.blocktank.createCjit(
            channelSizeSat: channelSizeSat,
            invoiceSat: amountSats,
            invoiceDescription: description,
            nodeId: nodeId,
            channelExpiryWeeks: defaultChannelExpiryWeeks,
            options: .init(source: defaultSource, discountCode: nil)
        )
    }

    func createOrder(clientBalance: UInt64, lspBalance: UInt64? = nil) async throws -> IBtOrder {
        let finalReceivingBalanceSats = lspBalance ?? (clientBalance * 2)

        if let btBOptions = info?.options {
            // Validate they're within the limits
            if (clientBalance + finalReceivingBalanceSats) > btBOptions.maxChannelSizeSat {
                Logger.error("Channel size exceeds maximum: \(clientBalance + finalReceivingBalanceSats) > \(btBOptions.maxChannelSizeSat)")
                throw CustomServiceError.channelSizeExceedsMaximum
            }
        } else {
            Logger.warn("Has not refreshed Blocktank info yet, skipping validation of limits")
        }

        let options = try await defaultCreateOrderOptions(clientBalanceSat: clientBalance)

        Logger.debug("Buying channel with lspBalanceSat: \(finalReceivingBalanceSats) and options: \(options)")

        return try await coreService.blocktank.newOrder(
            lspBalanceSat: finalReceivingBalanceSats,
            channelExpiryWeeks: defaultChannelExpiryWeeks,
            options: options
        )
    }

    func openChannel(orderId: String) async throws -> IBtOrder {
        let order = try await coreService.blocktank.open(orderId: orderId)

        // Update the order in the published array if it exists
        if let index = orders?.firstIndex(where: { $0.id == orderId }) {
            orders?[index] = order
        }

        coreService.blocktank.notifyStateChanged()
        return order
    }

    func estimateOrderFee(clientBalance: UInt64, lspBalance: UInt64) async throws -> (
        feeSat: UInt64, networkFeeSat: UInt64, serviceFeeSat: UInt64
    ) {
        let options = try await defaultCreateOrderOptions(clientBalanceSat: clientBalance)

        let estimate = try await coreService.blocktank.estimateFee(
            lspBalanceSat: lspBalance,
            channelExpiryWeeks: defaultChannelExpiryWeeks,
            options: options
        )

        return (
            feeSat: estimate.feeSat,
            networkFeeSat: estimate.networkFeeSat,
            serviceFeeSat: estimate.serviceFeeSat
        )
    }

    /// Creates default options for channel creation or fee estimation
    private func defaultCreateOrderOptions(clientBalanceSat: UInt64) async throws -> CreateOrderOptions {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let timestamp = Date().formatted(.iso8601)
        let signature = try await lightningService.sign(message: "channelOpen-\(timestamp)")

        return CreateOrderOptions(
            clientBalanceSat: clientBalanceSat,
            lspNodeId: nil,
            couponCode: "",
            source: defaultSource,
            discountCode: nil,
            zeroConf: true,
            zeroConfPayment: false,
            zeroReserve: true,
            clientNodeId: nodeId,
            signature: signature,
            timestamp: timestamp,
            refundOnchainAddress: nil,
            announceChannel: false
        )
    }

    private func getDefaultLspBalance(clientBalance: UInt64) async throws -> UInt64 {
        if info == nil {
            try await refreshInfo()
        }
        let maxLspBalance = info?.options.maxChannelSizeSat ?? 0

        // Get current rates
        guard let rates = currencyService.loadCachedRates(),
              let eurRate = currencyService.getCurrentRate(for: "EUR", from: rates)
        else {
            Logger.error("Failed to get EUR rate for lspBalance calculation")
            throw CustomServiceError.currencyRateUnavailable
        }

        // Calculate thresholds in sats
        let threshold1 = currencyService.convertFiatToSats(fiatValue: 225, rate: eurRate)
        let threshold2 = currencyService.convertFiatToSats(fiatValue: 495, rate: eurRate)
        let defaultLspBalance = currencyService.convertFiatToSats(fiatValue: 450, rate: eurRate)

        Logger.debug("getDefaultLspBalance - clientBalance: \(clientBalance)")
        Logger.debug("getDefaultLspBalance - maxLspBalance: \(maxLspBalance)")
        Logger.debug("getDefaultLspBalance - defaultLspBalance: \(defaultLspBalance)")

        // Safely calculate lspBalance to avoid arithmetic overflow
        var lspBalance: UInt64 = 0
        if defaultLspBalance > clientBalance {
            lspBalance = defaultLspBalance - clientBalance
        }

        if clientBalance > threshold1 {
            lspBalance = clientBalance
        }

        if clientBalance > threshold2 {
            lspBalance = maxLspBalance
        }

        return min(lspBalance, maxLspBalance)
    }

    func refreshMinCjitSats() async throws {
        do {
            let lspBalance = try await getDefaultLspBalance(clientBalance: 0)

            // Get fees and calculate minimum
            let fees = try await estimateOrderFee(clientBalance: 0, lspBalance: lspBalance)
            let minimum = UInt64(ceil(Double(fees.feeSat) * 1.1 / 1000) * 1000)
            minCjitSats = minimum
            Logger.debug("Updated minCjitSats to \(minimum)")
        } catch {
            Logger.error("Failed to refresh minCjitSats: \(error)")
            throw error
        }
    }

    /// Checks for pending orders and notifies TransferViewModel to start watching them
    /// This should be called on app startup to resume watching orders after app restart
    func startWatchingPendingOrders(transferViewModel: TransferViewModel) async {
        guard let orders else { return }

        let pendingOrders = orders.filter { order in
            // Watch orders that are created or paid but not yet completed
            order.state2 == .created || order.state2 == .paid
        }

        if !pendingOrders.isEmpty {
            Logger.info("Found \(pendingOrders.count) pending orders to watch: \(pendingOrders.map(\.id))")

            // Notify TransferViewModel to start watching each pending order
            for order in pendingOrders {
                await transferViewModel.startWatchingOrderFromRestart(order)
            }
        }
    }
}
