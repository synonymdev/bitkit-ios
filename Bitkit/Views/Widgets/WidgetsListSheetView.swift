import SwiftUI

struct WidgetsListSheetView: View {
    @Binding var navigationPath: [WidgetsRoute]

    /// Widget types shown in the add-list, in display order. `suggestions` is system-managed and excluded.
    private static let listedTypes: [WidgetType] = [.price, .weather, .news, .blocks, .facts, .calculator]

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
        }
        .navigationBarHidden(true)
    }

    private func tappableTile(_ type: WidgetType) -> some View {
        tile(for: type)
            .onTapGesture { navigationPath.append(.preview(type)) }
            .accessibilityIdentifier("WidgetListItem-\(type.rawValue)")
    }

    /// Display size each widget uses in the list grid (purely visual — not the saved size).
    private func displaySize(for type: WidgetType) -> WidgetSize {
        switch type {
        case .news, .blocks: return .wide
        default: return .small
        }
    }

    private func tile(for type: WidgetType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BodySSBText(t("widgets__\(type.rawValue)__name"), textColor: .textPrimary)

            tileCard(for: type)
        }
    }

    private func tileCard(for type: WidgetType) -> some View {
        Group {
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: displaySize(for: type) == .small ? 160 : nil, alignment: .topLeading)
        .background(Color.gray6)
        .cornerRadius(16)
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

private struct CalculatorTile: View {
    /// Calculator has no compact content form. Show a static representation
    /// so the tile reads as a calculator at a glance.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BodyMSBText("$0.00", textColor: .textPrimary)
            BodySText("0", textColor: .textSecondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(0 ..< 3) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white10)
                        .frame(height: 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
