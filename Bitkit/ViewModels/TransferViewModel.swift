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

@MainActor
class TransferViewModel: ObservableObject {
    static let shared = TransferViewModel()

    @Published var uiState = TransferUiState()
    @Published var lightningSetupStep: Int = 0

    private let coreService: CoreService
    private let lightningService: LightningService
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(coreService: CoreService = .shared,
         lightningService: LightningService = .shared)
    {
        self.coreService = coreService
        self.lightningService = lightningService
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
    }
}
