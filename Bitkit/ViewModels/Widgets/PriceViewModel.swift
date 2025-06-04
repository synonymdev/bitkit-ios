import Foundation
import SwiftUI

@MainActor
class PriceViewModel: ObservableObject {
    static let shared = PriceViewModel()

    @Published var dataByPeriod: [GraphPeriod: [PriceData]] = [:]
    @Published var isLoading = false
    @Published var error: String?

    private let priceService = PriceService.shared
    private var activeTasks: [GraphPeriod: Task<Void, Never>] = [:]
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 60 // 1 minute
    private var hasStartedTimer = false

    /// Private initializer for the singleton instance
    private init() {
        // No automatic loading - widgets will control when to load
    }

    func fetchPriceData(pairs: [String], period: GraphPeriod) {
        // Cancel existing task for this period
        activeTasks[period]?.cancel()

        // Clear previous error
        error = nil

        activeTasks[period] = Task {
            do {
                // First, try to get cached data immediately (no loading state)
                if let cachedData = try? await priceService.fetchPriceData(pairs: pairs, period: period, returnCachedImmediately: true),
                    !cachedData.isEmpty
                {

                    if !Task.isCancelled {
                        dataByPeriod[period] = cachedData
                        error = nil
                        // Don't set isLoading = false yet, fresh data might be coming
                    }
                } else {
                    // No cache available, show loading state
                    if !Task.isCancelled {
                        isLoading = true
                    }
                }

                // Always fetch fresh data (this will update cache in background if cached data was returned above)
                let freshData = try await priceService.fetchPriceData(pairs: pairs, period: period, returnCachedImmediately: false)

                if !Task.isCancelled {
                    dataByPeriod[period] = freshData
                    error = nil
                    isLoading = false

                    // Start periodic updates (idempotent)
                    startPeriodicUpdates(pairs: pairs, period: period)
                }
            } catch {
                if !Task.isCancelled {
                    self.error = "Unable to load prices"
                    Logger.error("Failed to fetch price data: \(error.localizedDescription)")
                    isLoading = false
                }
            }
        }
    }

    func fetchAllPeriods(pairs: [String]) {
        let allPeriods: [GraphPeriod] = [.oneDay, .oneWeek, .oneMonth, .oneYear]
        for period in allPeriods {
            fetchPriceData(pairs: pairs, period: period)
        }
    }

    /// Optimized fetch for edit view: latest prices for all pairs + all periods for BTC/USD
    func fetchForEditView() {
        // Fetch latest prices (1D) for all pairs
        fetchPriceData(pairs: tradingPairNames, period: .oneDay)

        // Fetch all periods for BTC/USD only (for period chart previews)
        let allPeriods: [GraphPeriod] = [.oneWeek, .oneMonth, .oneYear] // Skip .oneDay as already fetched above
        for period in allPeriods {
            fetchPriceData(pairs: ["BTC/USD"], period: period)
        }
    }

    func getCurrentData(for period: GraphPeriod) -> [PriceData] {
        return dataByPeriod[period] ?? []
    }

    private func startPeriodicUpdates(pairs: [String], period: GraphPeriod) {
        // Only start timer once across all periods
        guard !hasStartedTimer else { return }

        hasStartedTimer = true

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshAllActivePeriods()
            }
        }
    }

    private func refreshAllActivePeriods() async {
        // Refresh all periods that have data
        for (period, data) in dataByPeriod {
            guard !data.isEmpty else { continue }

            // Extract pairs from current data
            let pairs = data.map { $0.name }

            do {
                // Always fetch fresh data for background updates (no cache)
                let refreshedData = try await priceService.fetchPriceData(pairs: pairs, period: period, returnCachedImmediately: false)
                dataByPeriod[period] = refreshedData
            } catch {
                Logger.error("Failed to refresh price data for period \(period): \(error.localizedDescription)")
                // Don't update error state during background refresh
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        activeTasks.values.forEach { $0.cancel() }
    }
}
