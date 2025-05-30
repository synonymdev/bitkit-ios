import Foundation
import SwiftUI

/// ViewModel for handling Bitcoin block data fetching and caching
@MainActor
class BlocksViewModel: ObservableObject {
    static let shared = BlocksViewModel()

    @Published var blockData: BlockData?
    @Published var isLoading = true
    @Published var error: Error?

    private let blocksService = BlocksService.shared
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    /// Private initializer for the singleton instance
    private init() {
        // Load initial data
        Task {
            await loadBlockData()
        }

        startRefreshTimer()
    }

    /// Public initializer for previews and testing
    init(preview: Bool = true) {
        // Skip timer and initial load for previews
    }

    deinit {
        refreshTimer?.invalidate()
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

        // Try to load cached data first
        if let cached = blocksService.getCachedData() {
            blockData = cached
            isLoading = false
        }

        do {
            let data = try await blocksService.fetchBlockData()
            blocksService.cacheData(data)
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
}
