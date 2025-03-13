//
//  TransferViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/03/12.
//

import SwiftUI

struct TransferUiState {
    var order: IBtOrder? = nil
    var defaultOrder: IBtOrder? = nil
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
    static let shared = TransferViewModel()

    @Published var uiState = TransferUiState()
    @Published var lightningSetupStep: Int = 0
    @Published var transferValues = TransferValues()

    private let coreService: CoreService
    private let lightningService: LightningService
    private let currencyService: CurrencyService
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(coreService: CoreService = .shared,
         lightningService: LightningService = .shared,
         currencyService: CurrencyService = .shared)
    {
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
        guard let btNodeIds = blocktankInfo?.nodes.map({ $0.pubkey }) else { return 0 }

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

    func payOrder(order: IBtOrder) async throws {
        try await lightningService.send(address: order.payment.onchain.address, sats: order.feeSat)
        lightningSetupStep = 0
        watchOrder(orderId: order.id)
    }

    private func watchOrder(orderId: String, frequencyMs: Double = 2500) {
        stopPolling()

        let frequencySecs = frequencyMs / 1000.0
        Logger.debug("Starting to watch order \(orderId)")

        refreshTimer = Timer.scheduledTimer(withTimeInterval: frequencySecs, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshTask?.cancel()
            self.refreshTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                do {
                    Logger.debug("Refreshing order \(orderId)")
                    let orders = try await self.coreService.blocktank.orders(orderIds: [orderId], refresh: true)
                    guard let order = orders.first else {
                        Logger.error("Order not found \(orderId)", context: "TransferViewModel")
                        return
                    }

                    let step = try await self.updateOrder(order: order)
                    self.lightningSetupStep = step
                    Logger.debug("LN setup step: \(step)")

                    if order.state2 == .expired {
                        Logger.error("Order expired \(orderId)", context: "TransferViewModel")
                        self.stopPolling()
                        return
                    }

                    if step > 2 {
                        Logger.debug("Order settled, stopping polling")
                        self.stopPolling()
                        return
                    }
                } catch {
                    Logger.error(error, context: "Failed to watch order")
                    self.stopPolling()
                }
            }
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                let orders = try await self.coreService.blocktank.orders(orderIds: [orderId], refresh: true)
                guard let order = orders.first else {
                    Logger.error("Order not found \(orderId)", context: "TransferViewModel")
                    return
                }

                let step = try await self.updateOrder(order: order)
                self.lightningSetupStep = step
            } catch {
                Logger.error(error, context: "Failed in initial order check")
                self.stopPolling()
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
        let threshold1 = currencyService.convertFiatToSats(fiatValue: 225, rate: eurRate) ?? 0
        let threshold2 = currencyService.convertFiatToSats(fiatValue: 495, rate: eurRate) ?? 0
        let defaultLspBalanceSats = currencyService.convertFiatToSats(fiatValue: 450, rate: eurRate) ?? 0

        Logger.debug("getDefaultLspBalance - clientBalanceSat: \(clientBalanceSat)")
        Logger.debug("getDefaultLspBalance - maxLspBalance: \(maxLspBalance)")
        Logger.debug("getDefaultLspBalance - defaultLspBalanceSats: \(defaultLspBalanceSats)")

        // Safely calculate lspBalance to avoid arithmetic overflow
        var lspBalance: UInt64 = 0
        if defaultLspBalanceSats > clientBalanceSat {
            lspBalance = defaultLspBalanceSats - clientBalanceSat
        }

        if lspBalance > threshold1 {
            lspBalance = clientBalanceSat
        }
        if lspBalance > threshold2 {
            lspBalance = maxLspBalance
        }

        return min(lspBalance, maxLspBalance)
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
        return maxChannelSize > minRemoteBalance ? maxChannelSize - minRemoteBalance : 0
    }

    func updateTransferValues(clientBalanceSat: UInt64, blocktankInfo: IBtInfo?) {
        transferValues = calculateTransferValues(clientBalanceSat: clientBalanceSat, blocktankInfo: blocktankInfo)
    }

    private func calculateTransferValues(clientBalanceSat: UInt64, blocktankInfo: IBtInfo?) -> TransferValues {
        guard let blocktankInfo = blocktankInfo else {
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
}
