import SwiftUI
import WidgetKit

// MARK: - Entry

struct CalculatorWidgetEntry: TimelineEntry {
    let date: Date
    let values: CalculatorWidgetValues
}

// MARK: - Timeline Provider

struct CalculatorWidgetProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in _: Context) -> CalculatorWidgetEntry {
        CalculatorWidgetEntry(date: Date(), values: CalculatorWidgetValues(bitcoinValue: "10000", fiatValue: "6.25"))
    }

    func getSnapshot(in _: Context, completion: @escaping (CalculatorWidgetEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<CalculatorWidgetEntry>) -> Void) {
        let now = Date()
        let nextRefresh = now.addingTimeInterval(Self.refreshInterval)
        completion(Timeline(entries: [entry(at: now)], policy: .after(nextRefresh)))
    }

    private func entry(at date: Date) -> CalculatorWidgetEntry {
        CalculatorWidgetEntry(
            date: date,
            values: CalculatorHomeScreenWidgetOptionsStore.load()
        )
    }
}

// MARK: - View

struct CalculatorHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: CalculatorWidgetProvider.Entry

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
        VStack(spacing: 16) {
            row(
                symbol: "₿",
                value: CalculatorWidgetFormatter.formatBitcoinValue(entry.values.bitcoinValue, displayUnit: entry.values.displayUnit),
                iconSize: 24,
                rowPadding: 12
            )

            row(
                symbol: entry.values.currencySymbol,
                value: CalculatorWidgetFormatter.formatFiatValue(entry.values.fiatValue),
                iconSize: 24,
                rowPadding: 12
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wideLayout: some View {
        VStack(spacing: 16) {
            row(
                symbol: "₿",
                value: CalculatorWidgetFormatter.formatBitcoinValue(entry.values.bitcoinValue, displayUnit: entry.values.displayUnit),
                label: "BITCOIN",
                iconSize: 32,
                rowPadding: 16
            )

            row(
                symbol: entry.values.currencySymbol,
                value: CalculatorWidgetFormatter.formatFiatValue(entry.values.fiatValue),
                label: entry.values.selectedCurrency.uppercased(),
                iconSize: 32,
                rowPadding: 16
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(symbol: String, value: String, label: String? = nil, iconSize: CGFloat, rowPadding: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill(iconBackgroundColor)

                Text(CalculatorWidgetFormatter.displaySymbol(symbol))
                    .font(Fonts.semiBold(size: iconSize >= 32 ? 17 : 15))
                    .foregroundColor(iconTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: iconSize, height: iconSize)

            Text(value.isEmpty ? "0" : value)
                .font(Fonts.semiBold(size: 17))
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetAccentable()

            if let label {
                Text(label)
                    .font(Fonts.bold(size: 13))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(1)
            }
        }
        .padding(rowPadding)
        .frame(maxWidth: .infinity)
        .background(rowBackgroundColor)
        .cornerRadius(8)
    }

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    private var rowBackgroundColor: Color {
        widgetRenderingMode == .fullColor ? .black : .clear
    }

    private var iconBackgroundColor: Color {
        widgetRenderingMode == .fullColor ? .gray6 : .primary.opacity(0.12)
    }

    private var iconTextColor: Color {
        widgetRenderingMode == .fullColor ? .brandAccent : .primary
    }

    private var textColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private var secondaryTextColor: Color {
        widgetRenderingMode == .fullColor ? .white64 : .secondary
    }
}

// MARK: - Widget Configuration

struct BitkitCalculatorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: CalculatorHomeScreenWidgetOptionsStore.calculatorHomeScreenWidgetKind,
            provider: CalculatorWidgetProvider()
        ) { entry in
            CalculatorHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widgets__calculator__name")
        .description("widgets__calculator__gallery_description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
