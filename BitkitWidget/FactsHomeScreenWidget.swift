import SwiftUI
import WidgetKit

// MARK: - Entry

struct FactsWidgetEntry: TimelineEntry {
    let date: Date
    let fact: String
}

// MARK: - Timeline Provider

struct FactsWidgetProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 2 * 60

    func placeholder(in _: Context) -> FactsWidgetEntry {
        FactsWidgetEntry(date: Date(), fact: BitcoinFacts.all[0])
    }

    func getSnapshot(in _: Context, completion: @escaping (FactsWidgetEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<FactsWidgetEntry>) -> Void) {
        let now = Date()
        let nextRefresh = now.addingTimeInterval(Self.refreshInterval)
        completion(Timeline(entries: [entry(at: now)], policy: .after(nextRefresh)))
    }

    private func entry(at date: Date) -> FactsWidgetEntry {
        let bucket = Int(date.timeIntervalSince1970 / Self.refreshInterval)
        let index = abs(bucket) % BitcoinFacts.all.count
        return FactsWidgetEntry(date: date, fact: BitcoinFacts.all[index])
    }
}

// MARK: - View

struct FactsHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: FactsWidgetProvider.Entry

    private var palette: WidgetPalette {
        WidgetPalette(renderingMode: widgetRenderingMode)
    }

    var body: some View {
        content
            .containerBackground(for: .widget) { palette.background }
    }

    @ViewBuilder
    private var content: some View {
        switch widgetFamily {
        case .systemSmall:
            FactsWidgetCompactContent(fact: entry.fact)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            FactsWidgetWideContent(fact: entry.fact)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Widget Configuration

struct BitkitFactsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "BitkitFactsWidget",
            provider: FactsWidgetProvider()
        ) { entry in
            FactsHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(t("widgets__facts__name"))
        .description(t("widgets__facts__description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
