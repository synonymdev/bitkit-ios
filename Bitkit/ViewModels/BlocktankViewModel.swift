import BitkitCore
import SwiftUI

struct BlocktankOrderClient {
    typealias Submit = (UInt64, UInt32, CreateOrderOptions) async throws -> IBtOrder
    typealias Estimate = (UInt64, UInt32, CreateOrderOptions) async throws -> IBtEstimateFeeResponse2

    let nodeId: () -> String?
    let sign: (String) async throws -> String
    let submit: Submit
    let estimate: Estimate

    init(coreService: CoreService, lightningService: LightningService) {
        nodeId = { lightningService.nodeId }
        sign = { try await lightningService.sign(message: $0) }
        submit = { lspBalanceSat, channelExpiryWeeks, options in
            try await coreService.blocktank.newOrder(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
        estimate = { lspBalanceSat, channelExpiryWeeks, options in
            try await coreService.blocktank.estimateFee(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    init(
        nodeId: @escaping () -> String?,
        sign: @escaping (String) async throws -> String,
        submit: @escaping Submit,
        estimate: @escaping Estimate
    ) {
        self.nodeId = nodeId
        self.sign = sign
        self.submit = submit
        self.estimate = estimate
    }
}

@MainActor
class BlocktankViewModel: ObservableObject {
    @Published var orders: [IBtOrder]? = nil
    @Published var cJitEntries: [IcJitEntry]? = nil
    @Published var info: IBtInfo? = nil

    /// Use -1 as a sentinel value to represent nil
    @AppStorage("minCjitSats") private var minCjitSatsStorage: Int = -1

    var minCjitSats: UInt64? {
        get { minCjitSatsStorage == -1 ? nil : UInt64(minCjitSatsStorage) }
        set { minCjitSatsStorage = newValue == nil ? -1 : Int(newValue!) }
    }

    private let defaultChannelExpiryWeeks: UInt32 = 6
    private let defaultSource = "bitkit-ios"

    @Published private(set) var isRefreshing = false

    private let coreService: CoreService
    private let lightningService: LightningService
    private let currencyService: CurrencyService
    private let orderClient: BlocktankOrderClient
    private let refundAddressProvider: any BlocktankRefundAddressProviding
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        currencyService: CurrencyService = .shared,
        orderClient: BlocktankOrderClient? = nil,
        refundAddressProvider: (any BlocktankRefundAddressProviding)? = nil,
        startPolling: Bool = true
    ) {
        self.coreService = coreService
        self.lightningService = lightningService
        self.currencyService = currencyService
        self.orderClient = orderClient ?? BlocktankOrderClient(coreService: coreService, lightningService: lightningService)
        self.refundAddressProvider = refundAddressProvider ?? BlocktankRefundAddressProvider(
            lightningService: lightningService,
            utilityService: coreService.utility
        )

        if startPolling {
            Task { try? await refreshInfo() }
            self.startPolling()
        }
    }

    deinit {
        Task { @MainActor [weak self] in
            Logger.debug("Stopping poll for orders")
            self?.stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: Env.blocktankOrderRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshTask?.cancel()
                refreshTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await refreshOrders()
                }
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

        let maxChannelSizeSat = await freshMaxChannelSizeSat()
        let lspBalance = try await getDefaultLspBalance(clientBalance: amountSats)
        guard amountSats <= UInt64.max - lspBalance else {
            throw CustomServiceError.channelSizeExceedsMaximum
        }

        let channelSizeSat = amountSats + lspBalance

        if let maxChannelSizeSat, channelSizeSat > maxChannelSizeSat {
            Logger.error("CJIT channel size exceeds maximum: \(channelSizeSat) > \(maxChannelSizeSat)")
            throw CustomServiceError.channelSizeExceedsMaximum
        }

        do {
            let entry = try await coreService.blocktank.createCjit(
                channelSizeSat: channelSizeSat,
                invoiceSat: amountSats,
                invoiceDescription: description,
                nodeId: nodeId,
                channelExpiryWeeks: defaultChannelExpiryWeeks,
                options: .init(source: defaultSource, discountCode: nil)
            )
            try Self.validateCjitEntry(entry, receiveAmountSats: amountSats)
            return entry
        } catch {
            throw Self.normalizedCreateCjitError(error)
        }
    }

    nonisolated static func validateCjitEntry(_ entry: IcJitEntry, receiveAmountSats: UInt64) throws {
        guard entry.feeSat < receiveAmountSats else {
            throw CustomServiceError.invalidCjitQuote
        }

        let userBalanceSats = receiveAmountSats - entry.feeSat
        guard entry.channelSizeSat >= userBalanceSats else {
            throw CustomServiceError.invalidCjitQuote
        }
    }

    nonisolated static func normalizedCreateCjitError(_ error: Error) -> Error {
        if isNodeCapacityError(error) {
            return CustomServiceError.cjitNodeCapacityExceeded
        }

        if isMaxChannelSizeError(error) {
            return CustomServiceError.channelSizeExceedsMaximum
        }

        return error
    }

    private func canCreateCjit(amountSats: UInt64, maxChannelSizeSat: UInt64) async throws -> Bool {
        let lspBalance = try await getDefaultLspBalance(clientBalance: amountSats)
        guard amountSats <= maxChannelSizeSat else {
            return false
        }

        return lspBalance <= maxChannelSizeSat - amountSats
    }

    func maxCjitAmountSats() async throws -> UInt64? {
        guard let maxChannelSizeSat = await freshMaxChannelSizeSat() else {
            return nil
        }

        var lowerBound: UInt64 = 0
        var upperBound = maxChannelSizeSat

        while lowerBound < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound + 1) / 2
            if try await canCreateCjit(amountSats: candidate, maxChannelSizeSat: maxChannelSizeSat) {
                lowerBound = candidate
            } else {
                upperBound = candidate - 1
            }
        }

        return lowerBound
    }

    private func freshMaxChannelSizeSat() async -> UInt64? {
        do {
            try await refreshInfo()
        } catch {
            Logger.warn("Failed to refresh Blocktank info before CJIT max check; using cached info: \(error)")
        }

        guard let maxChannelSizeSat = info?.options.maxChannelSizeSat, maxChannelSizeSat > 0 else {
            return nil
        }

        return maxChannelSizeSat
    }

    private nonisolated static func isNodeCapacityError(_ error: Error) -> Bool {
        if error.isCjitNodeCapacityExceeded {
            return true
        }

        return errorDescriptionCandidates(error).contains {
            $0.localizedCaseInsensitiveContains("capacity is above our capacity limit")
        }
    }

    private nonisolated static func isMaxChannelSizeError(_ error: Error) -> Bool {
        if error.isChannelSizeExceedsMaximum {
            return true
        }

        return errorDescriptionCandidates(error).contains {
            $0.localizedCaseInsensitiveContains("Channel size is too big")
                || $0.localizedCaseInsensitiveContains("channelSizeExceedsMaximum")
                || $0.localizedCaseInsensitiveContains("maxChannelSizeSat")
        }
    }

    private nonisolated static func errorDescriptionCandidates(_ error: Error) -> [String] {
        var candidates = [
            String(describing: error),
            String(reflecting: error),
            error.localizedDescription,
        ]

        if let appError = error as? AppError {
            candidates.append(appError.message)
            if let debugMessage = appError.debugMessage {
                candidates.append(debugMessage)
            }
            if let underlyingError = appError.underlyingError {
                candidates.append(String(describing: underlyingError))
                candidates.append(underlyingError.localizedDescription)
            }
        }

        appendMirroredErrorDescriptions(from: error, to: &candidates)

        return candidates
    }

    private nonisolated static func appendMirroredErrorDescriptions(from value: Any, to candidates: inout [String]) {
        for child in Mirror(reflecting: value).children {
            appendMirroredErrorDescription(from: child.value, to: &candidates)
        }
    }

    private nonisolated static func appendMirroredErrorDescription(from value: Any, to candidates: inout [String]) {
        if let string = value as? String {
            candidates.append(string)
            return
        }

        if let error = value as? Error {
            candidates.append(String(describing: error))
            candidates.append(error.localizedDescription)
            return
        }

        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional, let wrappedValue = mirror.children.first?.value else {
            return
        }

        appendMirroredErrorDescription(from: wrappedValue, to: &candidates)
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

        guard orderClient.nodeId() != nil else {
            throw CustomServiceError.nodeNotStarted
        }
        try Task.checkCancellation()
        let refundAddress = try await refundAddressProvider.addressForOrder()
        let options = try await defaultCreateOrderOptions(
            clientBalanceSat: clientBalance,
            refundOnchainAddress: refundAddress
        )

        Logger.debug(
            "Buying channel with lspBalanceSat: \(finalReceivingBalanceSats), clientBalanceSat: \(clientBalance), expiryWeeks: \(defaultChannelExpiryWeeks)"
        )

        try Task.checkCancellation()
        return try await orderClient.submit(finalReceivingBalanceSats, defaultChannelExpiryWeeks, options)
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

        let estimate = try await orderClient.estimate(lspBalance, defaultChannelExpiryWeeks, options)

        return (
            feeSat: estimate.feeSat,
            networkFeeSat: estimate.networkFeeSat,
            serviceFeeSat: estimate.serviceFeeSat
        )
    }

    /// Creates default options for channel creation or fee estimation
    private func defaultCreateOrderOptions(
        clientBalanceSat: UInt64,
        refundOnchainAddress: String? = nil
    ) async throws -> CreateOrderOptions {
        guard let nodeId = orderClient.nodeId() else {
            throw CustomServiceError.nodeNotStarted
        }

        let timestamp = Date().formatted(.iso8601)
        let signature = try await orderClient.sign("channelOpen-\(timestamp)")

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
            refundOnchainAddress: refundOnchainAddress,
            announceChannel: false
        )
    }

    /// Calculates default LSP balance for CJIT channels using bitkit-core
    private func getDefaultLspBalance(clientBalance: UInt64) async throws -> UInt64 {
        if info == nil {
            try await refreshInfo()
        }

        guard let rates = currencyService.loadCachedRates(),
              let eurRate = currencyService.getCurrentRate(for: "EUR", from: rates)
        else {
            Logger.error("Failed to get EUR rate for lspBalance calculation")
            throw CustomServiceError.currencyRateUnavailable
        }

        let satsPerEur = currencyService.convertFiatToSats(fiatValue: 1, rate: eurRate)
        let params = DefaultLspBalanceParams(
            clientBalanceSat: clientBalance,
            maxChannelSizeSat: info?.options.maxChannelSizeSat ?? 0,
            satsPerEur: satsPerEur
        )

        return BitkitCore.getDefaultLspBalance(params: params)
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
