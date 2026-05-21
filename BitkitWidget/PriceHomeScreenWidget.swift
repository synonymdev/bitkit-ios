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

    private var palette: WidgetPalette {
        WidgetPalette(renderingMode: widgetRenderingMode)
    }

    var body: some View {
        content
            .containerBackground(for: .widget) { palette.background }
    }

    @ViewBuilder
    private var content: some View {
        if entry.showsError {
            errorView
        } else if let primary = primaryPrice {
            switch widgetFamily {
            case .systemSmall:
                PriceWidgetCompactContent(data: primary, period: entry.options.selectedPeriod)
            default:
                PriceWidgetWideContent(data: primary, period: entry.options.selectedPeriod)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var errorView: some View {
        BodySText(t("widgets__price__error"), textColor: palette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .configurationDisplayName(t("widgets__price__name"))
        .description(t("widgets__price__description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
