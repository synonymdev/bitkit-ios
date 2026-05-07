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
    static func relativeTime(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard let date = formatter.date(from: dateString) else { return "" }

        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale.current
        relative.dateTimeStyle = .named
        return relative.localizedString(for: date, relativeTo: Date())
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
        let pick = cached.randomElement()
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
                if let pick = fresh.randomElement() {
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
                if let pick = cached.randomElement() {
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

            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
                ?? Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

// MARK: - View

struct NewsHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: NewsWidgetProvider.Entry

    var body: some View {
        Group {
            if let url = articleURL {
                Link(destination: url) { content }
            } else {
                content
            }
        }
        .containerBackground(for: .widget) { backgroundView }
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
                compactLayout(article: article)
            default:
                wideLayout(article: article)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Compact (small widget — 163×192)

    private func compactLayout(article: CachedNewsArticle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleText(article.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            if entry.options.showDate {
                HStack {
                    Spacer(minLength: 0)
                    Text(entry.timeAgo)
                        .font(Fonts.semiBold(size: 13))
                        .tracking(0.4)
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Wide (medium widget — 343×118)

    private func wideLayout(article: CachedNewsArticle) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            titleText(article.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.options.showSource || entry.options.showDate {
                HStack(alignment: .center, spacing: 8) {
                    if entry.options.showSource {
                        Text(article.publisher)
                            .font(Fonts.semiBold(size: 13))
                            .tracking(0.4)
                            .foregroundColor(sourceTextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if entry.options.showDate {
                        Text(entry.timeAgo)
                            .font(Fonts.semiBold(size: 13))
                            .tracking(0.4)
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sub-views

    private func titleText(_ value: String) -> some View {
        Text(value)
            .font(Fonts.bold(size: 22))
            .foregroundColor(titleTextColor)
            .lineLimit(4)
            .minimumScaleFactor(0.85)
            .widgetAccentable()
    }

    private var errorView: some View {
        Text("Couldn’t load headlines.")
            .font(Fonts.regular(size: 13))
            .foregroundColor(secondaryTextColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Colors

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    private var titleTextColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private var sourceTextColor: Color {
        guard widgetRenderingMode == .fullColor else { return .primary }
        return .brandAccent
    }

    private var secondaryTextColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.64) : .secondary
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
        .configurationDisplayName("Bitcoin Headlines")
        .description("Latest Bitcoin news headlines, mirroring the in-app headlines widget.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
