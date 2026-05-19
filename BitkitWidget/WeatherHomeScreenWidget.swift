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
        let nextRefresh = Date().addingTimeInterval(Self.refreshInterval)

        Task {
            let data = await WeatherWidgetService.latestWeather()
            let entry = WeatherWidgetEntry(date: Date(), data: data, options: options)
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
                    conditionTitle: t(data.condition.shortTitleKey),
                    metricLabel: t(metric.labelKey)
                )
            default:
                WeatherWidgetWideContent(
                    data: data,
                    metric: metric,
                    conditionTitle: t(data.condition.titleKey),
                    conditionDescription: t(data.condition.descriptionKey),
                    metricLabel: t(metric.labelKey)
                )
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        .configurationDisplayName(t("widgets__weather__name"))
        .description(t("widgets__weather__description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
