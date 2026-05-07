import Foundation

/// Service for fetching and caching news articles
class NewsService {
    static let shared = NewsService()
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    private init() {
        NewsWidgetCache.legacyDropStandardSuiteCache()
    }

    /// Fetches articles from the news API
    /// - Returns: Array of articles
    /// - Throws: URLError or decoding error
    func fetchArticles() async throws -> [Article] {
        guard let url = URL(string: WidgetEnv.newsFeedArticlesUrl) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode([Article].self, from: data)
    }

    /// Retrieves a cached widget data view by selecting a random article from the App Group cache.
    func getCachedData() -> WidgetData? {
        guard let article = NewsWidgetCache.loadTop().randomElement() else { return nil }
        return WidgetData(
            title: article.title,
            timeAgo: timeAgo(from: article.publishedDate),
            link: article.link,
            publisher: article.publisher
        )
    }

    /// Converts a date string to a human-readable time ago format
    /// - Parameter dateString: Date string in format "EEE, dd MMM yyyy HH:mm:ss Z"
    /// - Returns: Human-readable time difference (e.g. "5 hours ago")
    func timeAgo(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        guard let date = formatter.date(from: dateString) else {
            return ""
        }

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = Locale.current
        relativeFormatter.dateTimeStyle = .named

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Fetches the top 10 most recent articles, persists them to the App Group cache,
    /// and triggers a home-screen widget reload.
    @discardableResult
    func fetchTopArticles() async throws -> [CachedNewsArticle] {
        let articles = try await fetchArticles()
        let top = articles
            .sorted { $0.published > $1.published }
            .prefix(10)
            .map { article in
                CachedNewsArticle(
                    title: article.title,
                    publisher: article.publisher.title,
                    link: article.comments ?? article.link,
                    publishedDate: article.publishedDate,
                    publishedEpoch: article.published
                )
            }

        NewsWidgetCache.saveTop(top)
        NewsHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()

        return top
    }

    /// Fetches widget data using stale-while-revalidate strategy
    /// - Parameter returnCachedImmediately: If true, returns cached data immediately if available
    /// - Returns: Widget data
    /// - Throws: URLError or decoding error
    @discardableResult
    func fetchWidgetData(returnCachedImmediately: Bool = true) async throws -> WidgetData {
        if returnCachedImmediately, let cachedData = getCachedData() {
            // Refresh in background; cache is updated automatically.
            Task {
                do {
                    try await fetchTopArticles()
                } catch {
                    print("Background news data update failed: \(error)")
                }
            }
            return cachedData
        }

        let top = try await fetchTopArticles()
        guard let article = top.randomElement() else {
            Logger.error("No articles available after filtering")
            throw URLError(.cannotParseResponse)
        }

        return WidgetData(
            title: article.title,
            timeAgo: timeAgo(from: article.publishedDate),
            link: article.link,
            publisher: article.publisher
        )
    }
}

/// Article model matching the React Native version
struct Article: Codable {
    let title: String
    let published: Int
    let publishedDate: String
    let link: String
    let comments: String?
    let author: String?
    let categories: [Category]?
    let thumbnail: String?
    let publisher: Publisher

    enum CodingKeys: String, CodingKey {
        case title
        case published
        case publishedDate
        case link
        case comments
        case author
        case categories
        case thumbnail
        case publisher
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        published = try container.decode(Int.self, forKey: .published)
        publishedDate = try container.decode(String.self, forKey: .publishedDate)
        link = try container.decode(String.self, forKey: .link)
        comments = try container.decodeIfPresent(String.self, forKey: .comments)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        categories = try container.decodeIfPresent([Category].self, forKey: .categories)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        publisher = try container.decode(Publisher.self, forKey: .publisher)
    }
}

struct Category: Codable {
    let value: String

    init(from decoder: Decoder) throws {
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            value = stringValue
        } else {
            let container = try decoder.container(keyedBy: CategoryCodingKeys.self)
            value = try container.decode(String.self, forKey: .underscore)
        }
    }

    private enum CategoryCodingKeys: String, CodingKey {
        case underscore = "_"
    }
}

struct Publisher: Codable {
    let title: String
    let link: String
    let image: String?
}

/// Widget data model used by the in-app news widget UI.
struct WidgetData: Codable {
    let title: String
    let timeAgo: String
    let link: String
    let publisher: String
}
