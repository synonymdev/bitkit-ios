import SwiftUI
import WidgetKit

// MARK: - Entry

struct WeatherWidgetEntry: TimelineEntry {
    let date: Date
    let data: CachedWeather?
    let options: WeatherWidgetOptions
}

// MARK: - Timeline Provider

struct WeatherWidgetProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 2 * 60

    /// Stable mock for widget gallery / placeholder snapshots.
    private static let mockData = CachedWeather(
        condition: .good,
        currentFeeFiat: "$ 0.52",
        currentFeeSats: 520,
        nextBlockFee: 6
    )

    private static let mockEntry = WeatherWidgetEntry(
        date: Date(),
        data: mockData,
        options: WeatherWidgetOptions()
    )

    func placeholder(in _: Context) -> WeatherWidgetEntry {
        Self.mockEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (WeatherWidgetEntry) -> Void) {
        let options = WeatherHomeScreenWidgetOptionsStore.load()

        if context.isPreview {
            completion(WeatherWidgetEntry(date: Self.mockEntry.date, data: Self.mockData, options: options))
            return
        }

        if let cached = WeatherWidgetService.cachedLatest() {
            completion(WeatherWidgetEntry(date: Date(), data: cached, options: options))
            return
        }

        Task {
            let fresh = try? await WeatherWidgetService.fetchFreshLatest()
            completion(WeatherWidgetEntry(date: Date(), data: fresh, options: options))
        }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WeatherWidgetEntry>) -> Void) {
        let options = WeatherHomeScreenWidgetOptionsStore.load()

        Task {
            let entry: WeatherWidgetEntry
            do {
                let fresh = try await WeatherWidgetService.fetchFreshLatest()
                entry = WeatherWidgetEntry(date: Date(), data: fresh, options: options)
            } catch {
                let cached = WeatherWidgetService.cachedLatest()
                entry = WeatherWidgetEntry(date: Date(), data: cached, options: options)
            }

            let nextRefresh = Date().addingTimeInterval(Self.refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

// MARK: - View

struct WeatherHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: WeatherWidgetProvider.Entry

    var body: some View {
        content
            .containerBackground(for: .widget) { backgroundView }
    }

    @ViewBuilder
    private var content: some View {
        if let data = entry.data {
            let metric = entry.options.selectedMetric
            switch widgetFamily {
            case .systemSmall:
                WeatherWidgetCompactContent(
                    data: data,
                    metric: metric,
                    conditionTitle: conditionEnglishShortTitle(data.condition),
                    metricLabel: metric.englishLabel
                )
            default:
                WeatherWidgetWideContent(
                    data: data,
                    metric: metric,
                    conditionTitle: conditionEnglishTitle(data.condition),
                    conditionDescription: conditionEnglishDescription(data.condition),
                    metricLabel: metric.englishLabel
                )
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func conditionEnglishTitle(_ condition: FeeCondition) -> String {
        switch condition {
        case .good: return "Favorable Conditions"
        case .average: return "Average Conditions"
        case .poor: return "Poor Conditions"
        }
    }

    private func conditionEnglishShortTitle(_ condition: FeeCondition) -> String {
        switch condition {
        case .good: return "Favorable"
        case .average: return "Average"
        case .poor: return "Poor"
        }
    }

    private func conditionEnglishDescription(_ condition: FeeCondition) -> String {
        switch condition {
        case .good: return "All clear. Now would be a good time to transact on the blockchain."
        case .average: return "The next block rate is close to the monthly averages."
        case .poor: return "If you are not in a hurry to transact, it may be better to wait a bit."
        }
    }

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }
}

// MARK: - Widget Configuration

struct BitkitWeatherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WeatherHomeScreenWidgetOptionsStore.weatherHomeScreenWidgetKind,
            provider: WeatherWidgetProvider()
        ) { entry in
            WeatherHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Bitcoin Weather")
        .description("Find out when it's a good time to transact on the Bitcoin blockchain.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
