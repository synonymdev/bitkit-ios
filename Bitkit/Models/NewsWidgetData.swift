import Foundation

/// Persistable representation of a news article shared between the main app and the widget extension via App Group.
struct CachedNewsArticle: Codable, Equatable {
    let title: String
    let publisher: String
    let link: String
    let publishedDate: String
    let publishedEpoch: Int
}

/// Cache reader/writer used by both the main app and the widget extension.
enum NewsWidgetCache {
    static let appGroupSuiteName = "group.bitkit"
    private static let topArticlesKey = "news_widget_top_articles_v1"
    private static let legacyStandardKey = "news_widget_cache"

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    static func saveTop(_ articles: [CachedNewsArticle]) {
        guard let encoded = try? JSONEncoder().encode(articles) else { return }
        defaults().set(encoded, forKey: topArticlesKey)
    }

    static func loadTop() -> [CachedNewsArticle] {
        guard let data = defaults().data(forKey: topArticlesKey),
              let decoded = try? JSONDecoder().decode([CachedNewsArticle].self, from: data)
        else {
            return []
        }
        return decoded
    }

    /// One-time cleanup of the pre-App-Group single-`WidgetData` cache.
    static func legacyDropStandardSuiteCache() {
        UserDefaults.standard.removeObject(forKey: legacyStandardKey)
    }
}
