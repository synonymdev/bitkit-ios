import SwiftUI

/// ViewModel for handling news article fetching and caching
@MainActor
class NewsViewModel: ObservableObject {
    static let shared = NewsViewModel()

    @Published var widgetData: WidgetData?
    @Published var isLoading = false
    @Published var error: Error?

    private let newsService = NewsService.shared
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
            await loadArticle()
        }

        // Start refresh timer
        startRefreshTimer()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.loadArticle()
            }
        }
    }

    func loadArticle() async {
        Logger.debug("Loading article")

        // Try to load cached data first and return immediately if available
        if let cached = newsService.getCachedData() {
            widgetData = cached
            isLoading = false

            // Start fresh fetch in background to update cache (don't await)
            Task {
                do {
                    try await newsService.fetchWidgetData(returnCachedImmediately: false)
                    // Cache will be updated automatically in fetchWidgetData
                } catch {
                    // Silent failure for background updates
                    print("Background news data update failed: \(error)")
                }
            }
            return
        }

        // No cache available - fetch fresh data with loading state
        isLoading = true
        error = nil

        do {
            let data = try await newsService.fetchWidgetData(returnCachedImmediately: false)
            widgetData = data
            error = nil
        } catch {
            Logger.error("Failed to load article: \(error.localizedDescription)")
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
