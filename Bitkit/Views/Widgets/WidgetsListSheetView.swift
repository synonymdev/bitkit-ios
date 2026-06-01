import SwiftUI

struct WidgetsListSheetView: View {
    @Binding var navigationPath: [WidgetsRoute]

    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    /// Widget types shown in the add-list, in display order.
    private static let listedTypes: [WidgetType] = [.price, .weather, .news, .blocks, .facts, .calculator, .suggestions]

    private static let disabledTileAlpha: CGFloat = 0.42

    private enum TileRow: Identifiable {
        case wide(WidgetType)
        case pair(WidgetType, WidgetType?)

        var id: String {
            switch self {
            case let .wide(t): return "wide-\(t.rawValue)"
            case let .pair(a, b): return "pair-\(a.rawValue)-\(b?.rawValue ?? "_")"
            }
        }
    }

    private var rows: [TileRow] {
        var result: [TileRow] = []
        var pending: WidgetType?
        for type in Self.listedTypes {
            if displaySize(for: type) == .wide {
                if let p = pending {
                    result.append(.pair(p, nil))
                    pending = nil
                }
                result.append(.wide(type))
            } else if let p = pending {
                result.append(.pair(p, type))
                pending = nil
            } else {
                pending = type
            }
        }
        if let p = pending { result.append(.pair(p, nil)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("widgets__add"))

            ScrollView(showsIndicators: false) {
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    ForEach(rows) { row in
                        GridRow {
                            switch row {
                            case let .wide(type):
                                tappableTile(type)
                                    .gridCellColumns(2)
                            case let .pair(first, second):
                                tappableTile(first)
                                if let second {
                                    tappableTile(second)
                                } else {
                                    Color.clear
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            // When widgets are disabled, tiles are dimmed/non-tappable and this CTA routes to settings.
            if !settings.showWidgets {
                CustomButton(
                    title: t("widgets__list__button"),
                    variant: .primary,
                    size: .large,
                    shouldExpand: true,
                    action: enableInSettings
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .accessibilityIdentifier("WidgetEnableInSettings")
            }
        }
        .navigationBarHidden(true)
        .bottomSafeAreaPadding()
    }

    @ViewBuilder
    private func tappableTile(_ type: WidgetType) -> some View {
        let enabled = settings.showWidgets
        tile(for: type)
            .opacity(enabled ? 1 : Self.disabledTileAlpha)
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                navigationPath.append(.preview(type))
            }
            .accessibilityIdentifier("WidgetListItem-\(type.rawValue)")
    }

    private func enableInSettings() {
        sheets.hideSheet()
        navigation.navigate(.widgetsSettings)
    }

    /// Display size each widget uses in the list grid (purely visual — not the saved size).
    private func displaySize(for type: WidgetType) -> WidgetSize {
        switch type {
        case .news, .blocks, .suggestions: return .wide
        default: return .small
        }
    }

    private func tile(for type: WidgetType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BodySText(t("widgets__\(type.rawValue)__name"))

            tileCard(for: type)
        }
    }

    @ViewBuilder
    private func tileCard(for type: WidgetType) -> some View {
        // Suggestions cards carry their own backgrounds — no gray6 chrome (matches Android).
        if type == .suggestions {
            SuggestionsTile()
        } else {
            chromedTile(for: type)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: displaySize(for: type) == .small ? 192 : nil, alignment: .topLeading)
                .background(Color.gray6)
                .cornerRadius(16)
        }
    }

    @ViewBuilder
    private func chromedTile(for type: WidgetType) -> some View {
        switch type {
        case .price: PriceTile()
        case .weather: WeatherTile()
        case .news: NewsTile()
        case .blocks: BlocksTile()
        case .facts: FactsTile()
        case .calculator: CalculatorTile()
        case .suggestions: EmptyView()
        }
    }
}

// MARK: - Per-type tiles

private struct PriceTile: View {
    @StateObject private var viewModel = PriceViewModel.shared

    private let options = PriceWidgetOptions()

    var body: some View {
        Group {
            if let data = primaryPrice {
                PriceWidgetCompactContent(data: data, period: options.selectedPeriod)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            viewModel.fetchPriceData(pairs: [options.selectedPair], period: options.selectedPeriod)
        }
    }

    private var primaryPrice: PriceData? {
        let data = viewModel.getCurrentData(for: options.selectedPeriod)
        return data.first(where: { $0.name == options.selectedPair }) ?? data.first
    }
}

private struct WeatherTile: View {
    @StateObject private var viewModel = WeatherViewModel.shared
    @EnvironmentObject private var currency: CurrencyViewModel

    private let options = WeatherWidgetOptions()

    var body: some View {
        Group {
            if let data = viewModel.weatherData {
                WeatherWidgetCompactContent(
                    data: data,
                    metric: options.selectedMetric,
                    conditionTitle: t(data.condition.titleKey),
                    metricLabel: t(options.selectedMetric.labelKey)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            viewModel.setCurrencyViewModel(currency)
            viewModel.startUpdates()
        }
    }
}

private struct NewsTile: View {
    @StateObject private var viewModel = NewsViewModel.shared

    private let options = NewsWidgetOptions()

    var body: some View {
        Group {
            if let data = viewModel.widgetData {
                NewsWidgetWideContent(
                    title: data.title,
                    publisher: data.publisher,
                    timeAgo: data.timeAgo,
                    options: options
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task {
            viewModel.startUpdates()
        }
    }
}

private struct BlocksTile: View {
    @StateObject private var viewModel = BlocksViewModel.shared

    private let options = BlocksWidgetOptions()

    var body: some View {
        Group {
            if let data = viewModel.blockData {
                BlocksWidgetWideContent(data: data, options: options)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task {
            viewModel.startUpdates()
        }
    }
}

private struct FactsTile: View {
    @StateObject private var viewModel = FactsViewModel.shared

    var body: some View {
        FactsWidgetCompactContent(fact: viewModel.fact)
    }
}

private struct SuggestionsTile: View {
    var body: some View {
        // Non-interactive preview grid; the suggestion cards supply their own backgrounds.
        Suggestions(isPreview: true, previewCardIds: Suggestions.previewSheetCardIds)
            .frame(maxWidth: .infinity)
    }
}

private struct CalculatorTile: View {
    @EnvironmentObject private var currency: CurrencyViewModel
    @State private var values = CalculatorWidgetValues()

    var body: some View {
        // Display-only compact calculator (no `onSelectInput`) for the add-list preview.
        CalculatorWidgetCompactContent(values: values)
            .task { hydrate() }
            .onChange(of: currency.selectedCurrency) { hydrate() }
            .onChange(of: currency.displayUnit) { hydrate() }
            .onChange(of: currency.rates) { hydrate() }
    }

    private func hydrate() {
        let saved = CalculatorWidgetOptionsStore.load()
        let bitcoinValue = CalculatorWidgetPreviewLogic.previewBitcoinValue(saved: saved, displayUnit: currency.displayUnit)

        values = CalculatorWidgetValues(
            bitcoinValue: bitcoinValue,
            fiatValue: CalculatorWidgetPreviewLogic.previewFiatValue(saved: saved, recalculatedFiatValue: fiatValue(for: bitcoinValue)),
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
    }

    private func fiatValue(for bitcoinValue: String) -> String {
        guard !bitcoinValue.isEmpty else { return "" }
        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(bitcoinValue, displayUnit: currency.displayUnit)
        if sats == 0 { return "0.00" }
        guard let converted = currency.convert(sats: sats) else { return "" }
        return CalculatorWidgetFormatter.fiatRawValue(from: converted.value)
    }
}
