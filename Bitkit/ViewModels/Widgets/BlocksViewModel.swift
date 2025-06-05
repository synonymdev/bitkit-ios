import Foundation
import SwiftUI

/// ViewModel for handling Bitcoin block data fetching and caching
@MainActor
class BlocksViewModel: ObservableObject {
    static let shared = BlocksViewModel()

    @Published var blockData: BlockData?
    @Published var isLoading = false
    @Published var error: Error?

    private let blocksService = BlocksService.shared
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes
    private var hasStartedUpdates = false

    /// Private initializer for the singleton instance
    private init() {
        // No automatic loading - widgets will control when to load
    }

    /// Start loading data and periodic updates (idempotent - only starts once)
    func startUpdates() {
        guard !hasStartedUpdates else { return }

        hasStartedUpdates = true

        // Load initial data
        Task {
            await loadBlockData()
        }

        startRefreshTimer()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.loadBlockData()
            }
        }
    }

    func loadBlockData() async {
        Logger.debug("Loading block data")

        // Try to load cached data first and return immediately if available
        if let cached = blocksService.getCachedData() {
            blockData = cached
            isLoading = false

            // Start fresh fetch in background to update cache (don't await)
            Task {
                do {
                    try await blocksService.fetchBlockData(returnCachedImmediately: false)
                    // Cache will be updated automatically in fetchBlockData
                } catch {
                    // Silent failure for background updates
                    print("Background block data update failed: \(error)")
                }
            }
            return
        }

        // No cache available - fetch fresh data with loading state
        isLoading = true
        error = nil

        do {
            let data = try await blocksService.fetchBlockData(returnCachedImmediately: false)
            blockData = data
            error = nil
        } catch {
            Logger.error("Failed to load block data: \(error.localizedDescription)")
            if let decodingError = error as? DecodingError {
                Logger.error("Decoding error details: \(decodingError)")
            }
            self.error = error
        }

        isLoading = false
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
