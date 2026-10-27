import BitkitCore
import SwiftUI

@MainActor
class BlocktankViewModel: ObservableObject {
    @Published var orders: [IBtOrder]? = nil
    @Published var cJitEntries: [IcJitEntry]? = nil
    @Published var info: IBtInfo? = nil

    @Published private(set) var isRefreshing = false

    private let coreService: CoreService
    private let lightningService: LightningService
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        startPolling: Bool = true
    ) {
        self.coreService = coreService
        self.lightningService = lightningService

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
}
