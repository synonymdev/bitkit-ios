import Charts
import SwiftUI
import WidgetKit

// MARK: - Entry

struct PriceWidgetEntry: TimelineEntry {
    let date: Date
    let prices: [PriceData]
    let options: PriceWidgetOptions
    /// True when no fresh data could be fetched and there is nothing in cache to fall back to.
    let showsError: Bool
}

// MARK: - Timeline Provider

struct PriceWidgetProvider: TimelineProvider {
    /// Stable mock for widget gallery / placeholder snapshots — fast, deterministic, no network.
    private static let mockEntry: PriceWidgetEntry = {
        let mockSeries = stride(from: 0.0, to: 24.0, by: 1.0).map { 60000 + 1000 * sin($0 / 4) }
        return PriceWidgetEntry(
            date: Date(),
            prices: [
                PriceData(
                    name: "BTC/USD",
                    change: PriceChange(isPositive: true, formatted: "+1.23%"),
                    price: "$ 60,000",
                    pastValues: mockSeries
                ),
            ],
            options: PriceWidgetOptions(),
            showsError: false
        )
    }()

    func placeholder(in _: Context) -> PriceWidgetEntry {
        Self.mockEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceWidgetEntry) -> Void) {
        let options = PriceHomeScreenWidgetOptionsStore.load()

        if context.isPreview {
            completion(PriceWidgetEntry(
                date: Self.mockEntry.date,
                prices: Self.mockEntry.prices,
                options: options,
                showsError: false
            ))
            return
        }

        let cached = PriceWidgetService.cachedPrices(pairs: options.selectedPairs, period: options.selectedPeriod) ?? []
        completion(PriceWidgetEntry(date: Date(), prices: cached, options: options, showsError: false))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<PriceWidgetEntry>) -> Void) {
        let options = PriceHomeScreenWidgetOptionsStore.load()

        Task {
            let entry: PriceWidgetEntry
            do {
                let fresh = try await PriceWidgetService.fetchFreshPrices(
                    pairs: options.selectedPairs,
                    period: options.selectedPeriod
                )
                entry = PriceWidgetEntry(date: Date(), prices: fresh, options: options, showsError: false)
            } catch {
                let cached = PriceWidgetService.cachedPrices(pairs: options.selectedPairs, period: options.selectedPeriod) ?? []
                entry = PriceWidgetEntry(date: Date(), prices: cached, options: options, showsError: cached.isEmpty)
            }

            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
                ?? Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

// MARK: - View

struct PriceHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: PriceWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if entry.options.showSource, !entry.prices.isEmpty {
                HStack {
                    Spacer()
                    CaptionBText("Bitfinex.com", textColor: secondaryTextColor)
                }
            }
        }
        .containerBackground(for: .widget) { backgroundView }
    }

    @ViewBuilder
    private var content: some View {
        if entry.showsError {
            errorView
        } else if entry.prices.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            switch widgetFamily {
            case .systemSmall:
                smallContent
            default:
                rowsAndChart
            }
        }
    }

    // MARK: - Variants

    private var smallContent: some View {
        let primary = entry.prices.first
        return VStack(alignment: .leading, spacing: 4) {
            BodySSBText(primary?.name ?? "BTC/USD", textColor: secondaryTextColor)
                .lineLimit(1)

            Text(primary?.price ?? "—")
                .font(Fonts.bold(size: 22))
                .foregroundColor(valueTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let change = primary?.change {
                BodySSBText(change.formatted, textColor: changeColor(isPositive: change.isPositive))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowsAndChart: some View {
        VStack(spacing: 0) {
            ForEach(visibleRows, id: \.name) { data in
                priceRow(data: data)
            }

            if let firstPair = entry.prices.first {
                PriceWidgetChart(
                    values: firstPair.pastValues,
                    isPositive: firstPair.change.isPositive,
                    period: entry.options.selectedPeriod.rawValue,
                    renderingMode: widgetRenderingMode
                )
                .frame(height: chartHeight)
                .padding(.top, 8)
            }
        }
    }

    private var visibleRows: [PriceData] {
        switch widgetFamily {
        case .systemSmall: Array(entry.prices.prefix(1))
        case .systemMedium: Array(entry.prices.prefix(2))
        case .systemLarge, .systemExtraLarge: Array(entry.prices.prefix(4))
        default: Array(entry.prices.prefix(1))
        }
    }

    private var chartHeight: CGFloat {
        switch widgetFamily {
        case .systemMedium: 64
        case .systemLarge, .systemExtraLarge: 120
        default: 96
        }
    }

    private var errorView: some View {
        Text("Couldn’t load price.")
            .font(Fonts.medium(size: 14))
            .foregroundColor(secondaryTextColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Row

    private func priceRow(data: PriceData) -> some View {
        HStack(spacing: 0) {
            BodySSBText(data.name, textColor: secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            BodySSBText(data.change.formatted, textColor: changeColor(isPositive: data.change.isPositive))
                .padding(.trailing, 8)
                .lineLimit(1)

            BodySSBText(data.price, textColor: valueTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: 24)
    }

    // MARK: - Colors

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    private var secondaryTextColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.64) : .secondary
    }

    private var valueTextColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private func changeColor(isPositive: Bool) -> Color {
        guard widgetRenderingMode == .fullColor else { return .primary }
        return isPositive ? .greenAccent : .redAccent
    }
}

// MARK: - Chart

private struct PriceWidgetChart: View {
    let values: [Double]
    let isPositive: Bool
    let period: String
    let renderingMode: WidgetRenderingMode

    private var normalizedValues: [Double] {
        guard values.count > 1 else { return values }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = maxValue - minValue
        guard range > 0 else { return values.map { _ in 0.5 } }
        return values.map { 0.15 + (($0 - minValue) / range) * 0.7 }
    }

    private var lineColor: Color {
        guard renderingMode == .fullColor else { return .primary }
        return isPositive ? .greenAccent : .redAccent
    }

    private var gradientColors: [Color] {
        guard renderingMode == .fullColor else { return [.primary.opacity(0.3), .clear] }
        let base: Color = isPositive ? .greenAccent : .redAccent
        return [base.opacity(0.64), base.opacity(0.08)]
    }

    private var labelColor: Color {
        guard renderingMode == .fullColor else { return .secondary }
        return isPositive ? .green50 : .red50
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Chart {
                ForEach(Array(normalizedValues.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Index", index),
                        y: .value("Price", value)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Index", index),
                        y: .value("Price", value)
                    )
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.3))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0.1 ... 0.9)
            .clipShape(
                .rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 8,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 0
                )
            )

            CaptionBText(period, textColor: labelColor)
                .padding(7)
        }
    }
}

// MARK: - Widget Configuration

struct BitkitPriceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PriceHomeScreenWidgetOptionsStore.priceHomeScreenWidgetKind,
            provider: PriceWidgetProvider()
        ) { entry in
            PriceHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Bitcoin Price")
        .description("Latest Bitcoin price and chart, mirroring the in-app price widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
