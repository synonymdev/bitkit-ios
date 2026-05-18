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

    var body: some View {
        content
            .containerBackground(for: .widget) { backgroundView }
    }

    @ViewBuilder
    private var content: some View {
        switch widgetFamily {
        case .systemSmall:
            compactLayout
        default:
            wideLayout
        }
    }

    private var compactLayout: some View {
        Text(entry.fact)
            .font(Fonts.semiBold(size: 17))
            .foregroundColor(textColor)
            .lineLimit(4)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                bitcoinLogo
            }
            .widgetAccentable()
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            Text(entry.fact)
                .font(Fonts.bold(size: 22))
                .foregroundColor(textColor)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .widgetAccentable()

            bitcoinLogo
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bitcoinLogo: some View {
        Group {
            if widgetRenderingMode == .fullColor {
                ZStack {
                    Circle()
                        .fill(Color.bitcoin)

                    bitcoinGlyph
                        .foregroundColor(.white)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white)

                    bitcoinGlyph
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
        }
        .frame(width: 32, height: 32)
    }

    private var bitcoinGlyph: some View {
        Image("bitcoin")
            .resizable()
            .renderingMode(.template)
    }

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    private var textColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
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
        .configurationDisplayName("widgets__facts__name")
        .description("widgets__facts__description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
