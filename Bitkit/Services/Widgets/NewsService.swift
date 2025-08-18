import Foundation

/// Service for fetching and caching news articles
class NewsService {
    static let shared = NewsService()
    private let cache = UserDefaults.standard
    private let cacheKey = "news_widget_cache"
    private let baseUrl = "https://feeds.synonym.to/news-feed/api"
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    private init() {}

    /// Fetches articles from the news API
    /// - Returns: Array of articles
    /// - Throws: URLError or decoding error
    func fetchArticles() async throws -> [Article] {
        guard let url = URL(string: "\(baseUrl)/articles") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        // Validate HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        do {
            let decoder = JSONDecoder()
            let articles = try decoder.decode([Article].self, from: data)
            return articles
        } catch {
            throw error
        }
    }

    /// Caches widget data to UserDefaults
    /// - Parameter data: Widget data to cache
    func cacheData(_ data: WidgetData) {
        do {
            let encoder = JSONEncoder()
            let encoded = try encoder.encode(data)
            cache.set(encoded, forKey: cacheKey)
        } catch {
            // Handle silently
        }
    }

    /// Retrieves cached widget data
    /// - Returns: Widget data if available
    func getCachedData() -> WidgetData? {
        guard let data = cache.data(forKey: cacheKey) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(WidgetData.self, from: data)
        } catch {
            return nil
        }
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

    /// Fetches widget data using stale-while-revalidate strategy
    /// - Parameter returnCachedImmediately: If true, returns cached data immediately if available
    /// - Returns: Widget data
    /// - Throws: URLError or decoding error
    @discardableResult
    func fetchWidgetData(returnCachedImmediately: Bool = true) async throws -> WidgetData {
        // If we want cached data and it exists, return it immediately
        if returnCachedImmediately, let cachedData = getCachedData() {
            // Start fresh fetch in background to update cache (don't await)
            Task {
                do {
                    try await fetchFreshData()
                    // Cache will be updated automatically in fetchFreshData
                } catch {
                    // Silent failure for background updates
                    print("Background news data update failed: \(error)")
                }
            }
            return cachedData
        }

        // No cache available or cache not requested - fetch fresh data
        return try await fetchFreshData()
    }

    /// Fetches fresh data from API (always hits the network)
    @discardableResult
    private func fetchFreshData() async throws -> WidgetData {
        let articles = try await fetchArticles()

        // Get a random article from the last 10
        let recentArticles =
            articles
                .sorted { $0.published > $1.published }
                .prefix(10)

        guard let article = recentArticles.randomElement() else {
            Logger.error("No articles available after filtering")
            throw URLError(.cannotParseResponse)
        }

        let timeAgoString = timeAgo(from: article.publishedDate)

        let widgetData = WidgetData(
            title: article.title,
            timeAgo: timeAgoString,
            link: article.comments ?? article.link,
            publisher: article.publisher.title
        )

        // Cache the data
        cacheData(widgetData)

        return widgetData
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

/// Widget data model for caching
struct WidgetData: Codable {
    let title: String
    let timeAgo: String
    let link: String
    let publisher: String
}
