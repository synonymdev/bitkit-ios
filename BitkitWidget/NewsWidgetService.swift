import Foundation

/// Slim news fetcher used inside the WidgetKit extension.
///
/// Reads cached `[CachedNewsArticle]` from the App Group (written by the main app's `NewsService`)
/// and falls back to a direct network fetch when the cache is empty or stale. The cache itself
/// is owned by the main app; this service intentionally does not write back to it.
enum NewsWidgetService {
    enum FetchError: Error {
        case invalidURL
        case noArticlesAvailable
    }

    static func cachedTopArticles() -> [CachedNewsArticle] {
        NewsWidgetCache.loadTop()
    }

    static func fetchFreshTopArticles() async throws -> [CachedNewsArticle] {
        guard let url = URL(string: WidgetEnv.newsFeedArticlesUrl) else { throw FetchError.invalidURL }

        let (data, _) = try await URLSession.shared.data(from: url)
        let articles = try JSONDecoder().decode([WireArticle].self, from: data)

        let top = articles
            .sorted { $0.published > $1.published }
            .prefix(10)
            .map { wire in
                CachedNewsArticle(
                    title: wire.title,
                    publisher: wire.publisher.title,
                    link: wire.comments ?? wire.link,
                    publishedDate: wire.publishedDate,
                    publishedEpoch: wire.published
                )
            }

        guard !top.isEmpty else { throw FetchError.noArticlesAvailable }
        return top
    }
}

// MARK: - Wire Models

/// Local copy to keep the widget extension's footprint small (mirrors `Article` in main app).
private struct WireArticle: Codable {
    let title: String
    let published: Int
    let publishedDate: String
    let link: String
    let comments: String?
    let publisher: WirePublisher
}

private struct WirePublisher: Codable {
    let title: String
    let link: String
    let image: String?
}
