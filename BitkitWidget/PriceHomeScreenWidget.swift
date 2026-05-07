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
        let options = PriceHomeScreenWidgetOptionsStore.load()
        if let cached = PriceWidgetService.cachedPrices(pairs: [options.selectedPair], period: options.selectedPeriod),
           !cached.isEmpty
        {
            return PriceWidgetEntry(date: Date(), prices: cached, options: options, showsError: false)
        }
        return Self.mockEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceWidgetEntry) -> Void) {
        let options = PriceHomeScreenWidgetOptionsStore.load()
        let cached = PriceWidgetService.cachedPrices(pairs: [options.selectedPair], period: options.selectedPeriod) ?? []

        if !cached.isEmpty {
            completion(PriceWidgetEntry(date: Date(), prices: cached, options: options, showsError: false))
            return
        }

        if context.isPreview {
            Task {
                if let fresh = try? await PriceWidgetService.fetchFreshPrices(
                    pairs: [options.selectedPair],
                    period: options.selectedPeriod
                ), !fresh.isEmpty {
                    completion(PriceWidgetEntry(date: Date(), prices: fresh, options: options, showsError: false))
                } else {
                    completion(PriceWidgetEntry(
                        date: Self.mockEntry.date,
                        prices: Self.mockEntry.prices,
                        options: options,
                        showsError: false
                    ))
                }
            }
            return
        }

        completion(PriceWidgetEntry(date: Date(), prices: cached, options: options, showsError: false))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<PriceWidgetEntry>) -> Void) {
        let options = PriceHomeScreenWidgetOptionsStore.load()

        Task {
            let entry: PriceWidgetEntry
            do {
                let fresh = try await PriceWidgetService.fetchFreshPrices(
                    pairs: [options.selectedPair],
                    period: options.selectedPeriod
                )
                entry = PriceWidgetEntry(date: Date(), prices: fresh, options: options, showsError: false)
            } catch {
                let cached = PriceWidgetService.cachedPrices(pairs: [options.selectedPair], period: options.selectedPeriod) ?? []
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
        content
            .containerBackground(for: .widget) { backgroundView }
    }

    @ViewBuilder
    private var content: some View {
        if entry.showsError {
            errorView
        } else if let primary = primaryPrice {
            switch widgetFamily {
            case .systemSmall:
                compactLayout(data: primary)
            default:
                wideLayout(data: primary)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var primaryPrice: PriceData? {
        if let match = entry.prices.first(where: { $0.name == entry.options.selectedPair }) {
            return match
        }
        return entry.prices.first
    }

    // MARK: - Compact (small widget — 163×192)

    private func compactLayout(data: PriceData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    CaptionMText(data.name, textColor: secondaryTextColor)
                    Spacer(minLength: 0)
                    CaptionMText(entry.options.selectedPeriod.rawValue, textColor: secondaryTextColor)
                }

                priceText(data.price, size: 22)

                Text(data.change.formatted)
                    .font(Fonts.semiBold(size: 15))
                    .foregroundColor(changeColor(isPositive: data.change.isPositive))
                    .lineLimit(1)
                    .widgetAccentable()
            }

            Spacer(minLength: 8)

            chart(values: data.pastValues, isPositive: data.change.isPositive, idealHeight: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Wide (medium widget — 343×152)

    private func wideLayout(data: PriceData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 16) {
                    CaptionMText("\(data.name)  \(entry.options.selectedPeriod.rawValue)", textColor: secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(data.change.formatted)
                        .font(Fonts.bold(size: 22))
                        .foregroundColor(changeColor(isPositive: data.change.isPositive))
                        .lineLimit(1)
                        .widgetAccentable()
                }

                priceText(data.price, size: 34)
            }

            Spacer(minLength: 4)

            chart(values: data.pastValues, isPositive: data.change.isPositive, idealHeight: 48, minHeight: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sub-views

    private func priceText(_ value: String, size: CGFloat) -> some View {
        Text(value)
            .font(Fonts.bold(size: size))
            .foregroundColor(valueTextColor)
            .lineLimit(1)
            .widgetAccentable()
    }

    private func chart(values: [Double], isPositive: Bool, idealHeight: CGFloat, minHeight: CGFloat = 32) -> some View {
        PriceWidgetChart(
            values: values,
            isPositive: isPositive,
            renderingMode: widgetRenderingMode
        )
        .frame(minHeight: minHeight, maxHeight: idealHeight)
        .widgetAccentable()
    }

    private var errorView: some View {
        BodySText("Couldn’t load price.", textColor: secondaryTextColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    var body: some View {
        Chart {
            ForEach(Array(normalizedValues.enumerated()), id: \.offset) { index, value in
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
