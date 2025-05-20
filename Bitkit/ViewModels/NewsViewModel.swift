import SwiftUI

/// ViewModel for handling news article fetching and caching
@MainActor
class NewsViewModel: ObservableObject {
    static let shared = NewsViewModel()

    @Published var widgetData: WidgetData?
    @Published var isLoading = true
    @Published var error: Error?

    private let newsService = NewsService.shared
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    /// Private initializer for the singleton instance
    private init() {
        // Load initial data
        Task {
            await loadArticle()
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
                await self?.loadArticle()
            }
        }
    }

    func loadArticle() async {
        Logger.debug("Loading article")

        // Try to load cached data first
        if let cached = newsService.getCachedData() {
            widgetData = cached
            isLoading = false
        }

        do {
            let articles = try await newsService.fetchArticles()

            // Get a random article from the last 10
            let recentArticles =
                articles
                .sorted { $0.published > $1.published }
                .prefix(10)

            guard let article = recentArticles.randomElement() else {
                Logger.error("No articles available after filtering")
                throw URLError(.cannotParseResponse)
            }

            let data = WidgetData(
                title: article.title,
                timeAgo: newsService.timeAgo(from: article.publishedDate),
                link: article.comments ?? article.link,
                publisher: article.publisher.title
            )

            newsService.cacheData(data)
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
}
