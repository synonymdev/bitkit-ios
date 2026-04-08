import WidgetKit
import SwiftUI

// MARK: - Widget Entry

struct FactsWidgetEntry: TimelineEntry {
    let date: Date
    let fact: String
}

// MARK: - Timeline Provider

struct FactsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FactsWidgetEntry {
        FactsWidgetEntry(
            date: Date(),
            fact: "Bitcoin operates without central authority."
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (FactsWidgetEntry) -> Void) {
        let entry = FactsWidgetEntry(
            date: Date(),
            fact: WidgetFactsService.shared.getRandomFact()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FactsWidgetEntry>) -> Void) {
        var entries: [FactsWidgetEntry] = []
        let currentDate = Date()
        
        // Create entries for the next 2 hours, one every 15 minutes
        for hourOffset in 0..<8 {
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

// MARK: - Widget View

struct BitkitWidgetEntryView: View {
    var entry: FactsWidgetProvider.Entry
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(iconColor)
                    .widgetAccentable()
                
                Text("Bitcoin Fact")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(headerColor)
                
                Spacer()
            }
            
            // Fact text
            Text(entry.fact)
                .font(fontForFamily())
                .foregroundColor(factColor)
                .lineLimit(lineLimit())
                .minimumScaleFactor(0.8)
            
            Spacer()
            
            // Source footer
            HStack {
                Spacer()
                Text("synonym.to")
                    .font(.system(size: 10))
                    .foregroundColor(footerColor)
            }
        }
        // .padding(16)
        .containerBackground(for: .widget) {
            backgroundView
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if widgetRenderingMode == .fullColor {
            // Keep custom styling only in full-color mode.
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.15),
                    Color(red: 0.15, green: 0.15, blue: 0.2)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            // Let the system provide tinted/Liquid Glass treatment.
            Color.clear
        }
    }

    private var iconColor: Color {
        widgetRenderingMode == .fullColor ? .orange : .primary
    }

    private var headerColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.9) : .primary
    }

    private var factColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private var footerColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.5) : .secondary
    }
    
    private func fontForFamily() -> Font {
        switch widgetFamily {
        case .systemSmall:
            return .system(size: 14, weight: .medium)
        case .systemMedium:
            return .system(size: 16, weight: .medium)
        case .systemLarge, .systemExtraLarge:
            return .system(size: 18, weight: .medium)
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return .system(size: 14, weight: .medium)
        @unknown default:
            return .system(size: 14, weight: .medium)
        }
    }
    
    private func lineLimit() -> Int {
        switch widgetFamily {
        case .systemSmall:
            return 4
        case .systemMedium:
            return 3
        case .systemLarge, .systemExtraLarge:
            return 8
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return 1
        @unknown default:
            return 4
        }
    }
}

// MARK: - Widget Configuration

struct BitkitWidget: Widget {
    let kind: String = "BitkitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FactsWidgetProvider()) { entry in
            BitkitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Bitcoin Facts")
        .description("Display interesting Bitcoin facts on your home screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget Bundle

@main
struct BitkitWidgetBundle: WidgetBundle {
    var body: some Widget {
        BitkitWidget()
    }
}

// MARK: - Preview

struct BitkitWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            BitkitWidgetEntryView(entry: FactsWidgetEntry(
                date: Date(),
                fact: "Satoshi Nakamoto mined more than 1M Bitcoin."
            ))
            .previewContext(WidgetPreviewContext(family: .systemSmall))
            .previewDisplayName("Small")
            
            BitkitWidgetEntryView(entry: FactsWidgetEntry(
                date: Date(),
                fact: "You don't need permission to use Bitcoin."
            ))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
            .previewDisplayName("Medium")
            
            BitkitWidgetEntryView(entry: FactsWidgetEntry(
                date: Date(),
                fact: "Bitcoin operates without central authority. No company controls Bitcoin."
            ))
            .previewContext(WidgetPreviewContext(family: .systemLarge))
            .previewDisplayName("Large")
        }
    }
}
