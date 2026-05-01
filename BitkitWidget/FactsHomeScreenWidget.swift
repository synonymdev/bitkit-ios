import SwiftUI
import WidgetKit

// MARK: - Entry

struct FactsWidgetEntry: TimelineEntry {
    let date: Date
    let fact: String
}

// MARK: - Timeline Provider

struct FactsWidgetProvider: TimelineProvider {
    /// Stable copy for the widget gallery / `isPreview` snapshots (fast, deterministic).
    private static let galleryPreviewFact = "Bitcoin operates without central authority."

    func placeholder(in _: Context) -> FactsWidgetEntry {
        FactsWidgetEntry(
            date: Date(),
            fact: Self.galleryPreviewFact
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (FactsWidgetEntry) -> Void) {
        if context.isPreview {
            completion(FactsWidgetEntry(date: Date(), fact: Self.galleryPreviewFact))
            return
        }
        let entry = FactsWidgetEntry(
            date: Date(),
            fact: WidgetFactsService.shared.getRandomFact()
        )
        completion(entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<FactsWidgetEntry>) -> Void) {
        var entries: [FactsWidgetEntry] = []
        let currentDate = Date()

        for hourOffset in 0 ..< 8 {
            let entryDate = Calendar.current.date(byAdding: .minute, value: hourOffset * 15, to: currentDate)!
            let entry = FactsWidgetEntry(
                date: entryDate,
                fact: WidgetFactsService.shared.getRandomFact()
            )
            entries.append(entry)
        }

        let timeline = Timeline(entries: entries, policy: .atEnd)
        completion(timeline)
    }
}

// MARK: - View

struct FactsHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: FactsWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // HStack {
            //     Image("facts-widget")
            //         .resizable()
            //         .frame(width: 32, height: 32)

            //     BodyMSBText("Bitcoin Fact", textColor: titleColor)
            //         .lineLimit(1)

            //     Spacer()
            // }

            Text(entry.fact)
                .font(fontForFamily())
                .foregroundColor(factColor)
                .lineLimit(lineLimit())
                .minimumScaleFactor(0.8)

            Spacer()

            HStack {
                Image("btc")
                    .resizable()
                    .frame(width: 32, height: 32)

                Spacer()

                CaptionBText("synonym.to", textColor: secondaryTextColor)
            }
        }
        .containerBackground(for: .widget) {
            backgroundView
        }
    }

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    private var titleColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.9) : .primary
    }

    private var factColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private var secondaryTextColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.64) : .secondary
    }

    private func fontForFamily() -> Font {
        switch widgetFamily {
        case .systemSmall: Fonts.semiBold(size: 17)
        case .systemMedium, .systemLarge, .systemExtraLarge: Fonts.bold(size: 22)
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: Fonts.medium(size: 14)
        @unknown default: Fonts.medium(size: 14)
        }
    }

    private func lineLimit() -> Int {
        switch widgetFamily {
        case .systemSmall:
            return 4
        case .systemMedium, .systemLarge, .systemExtraLarge:
            // Large matches medium: we only list `.systemLarge` in `supportedFamilies` so the add-widget gallery can render a real preview (omitting
            // it often shows skeletons).
            return 3
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return 1
        @unknown default:
            return 4
        }
    }
}

// MARK: - Widget Configuration

/// Home screen “Bitcoin Facts” widget. `kind` must stay `BitkitWidget` so existing placements keep working.
struct BitkitFactsWidget: Widget {
    let kind: String = "BitkitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FactsWidgetProvider()) { entry in
            FactsHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Bitcoin Facts")
        .description("Display interesting Bitcoin facts on your home screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
