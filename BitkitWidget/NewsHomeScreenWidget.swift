import SwiftUI
import WidgetKit

// MARK: - Entry

struct NewsWidgetEntry: TimelineEntry {
    let date: Date
    let article: CachedNewsArticle?
    let timeAgo: String
    let options: NewsWidgetOptions
    /// True when no fresh data could be fetched and there is nothing in cache to fall back to.
    let showsError: Bool
}

// MARK: - Helpers

private enum NewsWidgetEntryBuilder {
    static let refreshInterval: TimeInterval = 15 * 60

    static func relativeTime(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard let date = formatter.date(from: dateString) else { return "" }

        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale.current
        relative.dateTimeStyle = .named
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func currentArticle(from articles: [CachedNewsArticle], at date: Date = Date()) -> CachedNewsArticle? {
        guard !articles.isEmpty else { return nil }
        let bucket = Int(date.timeIntervalSince1970 / refreshInterval)
        let index = abs(bucket) % articles.count
        return articles[index]
    }
}

// MARK: - Timeline Provider

struct NewsWidgetProvider: TimelineProvider {
    /// Stable mock for widget gallery / placeholder snapshots.
    private static let mockArticle = CachedNewsArticle(
        title: "How Bitcoin changed El Salvador in more ways than one",
        publisher: "bitcoinmagazine.com",
        link: "https://bitcoinmagazine.com",
        publishedDate: "Mon, 01 Jan 2024 12:00:00 +0000",
        publishedEpoch: 1_704_110_400
    )

    private static let mockEntry = NewsWidgetEntry(
        date: Date(),
        article: mockArticle,
        timeAgo: "21 min ago",
        options: NewsWidgetOptions(),
        showsError: false
    )

    func placeholder(in _: Context) -> NewsWidgetEntry {
        Self.mockEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (NewsWidgetEntry) -> Void) {
        let options = NewsHomeScreenWidgetOptionsStore.load()

        if context.isPreview {
            completion(NewsWidgetEntry(
                date: Self.mockEntry.date,
                article: Self.mockArticle,
                timeAgo: Self.mockEntry.timeAgo,
                options: options,
                showsError: false
            ))
            return
        }

        let cached = NewsWidgetService.cachedTopArticles()
        let pick = NewsWidgetEntryBuilder.currentArticle(from: cached)
        completion(NewsWidgetEntry(
            date: Date(),
            article: pick,
            timeAgo: pick.map { NewsWidgetEntryBuilder.relativeTime(from: $0.publishedDate) } ?? "",
            options: options,
            showsError: false
        ))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<NewsWidgetEntry>) -> Void) {
        let options = NewsHomeScreenWidgetOptionsStore.load()

        Task {
            let entry: NewsWidgetEntry
            do {
                let fresh = try await NewsWidgetService.fetchFreshTopArticles()
                if let pick = NewsWidgetEntryBuilder.currentArticle(from: fresh) {
                    entry = NewsWidgetEntry(
                        date: Date(),
                        article: pick,
                        timeAgo: NewsWidgetEntryBuilder.relativeTime(from: pick.publishedDate),
                        options: options,
                        showsError: false
                    )
                } else {
                    entry = NewsWidgetEntry(date: Date(), article: nil, timeAgo: "", options: options, showsError: true)
                }
            } catch {
                let cached = NewsWidgetService.cachedTopArticles()
                if let pick = NewsWidgetEntryBuilder.currentArticle(from: cached) {
                    entry = NewsWidgetEntry(
                        date: Date(),
                        article: pick,
                        timeAgo: NewsWidgetEntryBuilder.relativeTime(from: pick.publishedDate),
                        options: options,
                        showsError: false
                    )
                } else {
                    entry = NewsWidgetEntry(date: Date(), article: nil, timeAgo: "", options: options, showsError: true)
                }
            }

            let nextRefresh = Date().addingTimeInterval(NewsWidgetEntryBuilder.refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

// MARK: - View

struct NewsHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: NewsWidgetProvider.Entry

    private var palette: WidgetPalette {
        WidgetPalette(renderingMode: widgetRenderingMode)
    }

    var body: some View {
        Group {
            if let url = articleURL {
                Link(destination: url) { content }
            } else {
                content
            }
        }
        .widgetURL(articleURL)
        .containerBackground(for: .widget) { palette.background }
    }

    private var articleURL: URL? {
        guard let link = entry.article?.link else { return nil }
        return URL(string: link)
    }

    @ViewBuilder
    private var content: some View {
        if entry.showsError {
            errorView
        } else if let article = entry.article {
            switch widgetFamily {
            case .systemSmall:
                NewsWidgetCompactContent(
                    title: article.title,
                    timeAgo: entry.timeAgo,
                    options: entry.options
                )
            default:
                NewsWidgetWideContent(
                    title: article.title,
                    publisher: article.publisher,
                    timeAgo: entry.timeAgo,
                    options: entry.options,
                    titleLineLimit: 3
                )
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var errorView: some View {
        BodySText(t("widgets__news__error"), textColor: palette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Widget Configuration

struct BitkitNewsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: NewsHomeScreenWidgetOptionsStore.newsHomeScreenWidgetKind,
            provider: NewsWidgetProvider()
        ) { entry in
            NewsHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(t("widgets__news__name"))
        .description(t("widgets__news__description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
