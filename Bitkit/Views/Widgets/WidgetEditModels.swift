import SwiftUI

// MARK: - GraphPeriod display

extension GraphPeriod {
    /// Full-word label shown in the Price edit screen (Day / Week / Month / Year).
    /// The widget itself uses `rawValue` ("1D"/...) per Figma v61.
    var editScreenLabel: String {
        switch self {
        case .oneDay: return t("widgets__price__period_day")
        case .oneWeek: return t("widgets__price__period_week")
        case .oneMonth: return t("widgets__price__period_month")
        case .oneYear: return t("widgets__price__period_year")
        }
    }
}

// MARK: - Widget Edit Item Models

enum WidgetItemType {
    case toggleItem
    case radioItem
    case staticItem
    /// Non-tappable section header (uppercase caption above a group of items).
    case sectionHeader
}

struct WidgetEditItem {
    let key: String
    let type: WidgetItemType
    let titleView: AnyView
    let valueView: AnyView?
    let isChecked: Bool

    init(key: String, type: WidgetItemType, titleView: AnyView, valueView: AnyView? = nil, isChecked: Bool) {
        self.key = key
        self.type = type
        self.titleView = titleView
        self.valueView = valueView
        self.isChecked = isChecked
    }

    /// Convenience initializer for string titles and values
    init(key: String, type: WidgetItemType, title: String, value: String? = nil, isChecked: Bool) {
        self.key = key
        self.type = type
        titleView = AnyView(BodySSBText(title, textColor: .textSecondary))
        valueView = value.map { AnyView(BodySSBText($0)) }
        self.isChecked = isChecked
    }

    /// Convenience initializer for string titles and view values
    init(key: String, type: WidgetItemType, title: String, valueView: AnyView? = nil, isChecked: Bool) {
        self.key = key
        self.type = type
        titleView = AnyView(BodySSBText(title, textColor: .textSecondary))
        self.valueView = valueView
        self.isChecked = isChecked
    }
}

// MARK: - Widget Edit Item Factory

enum WidgetEditItemFactory {
    @MainActor
    static func getBlocksItems(
        blocksViewModel: BlocksViewModel,
        blocksOptions: BlocksWidgetOptions
    ) -> [WidgetEditItem] {
        var items: [WidgetEditItem] = []

        items.append(sectionHeaderItem(key: "blocks_data_header", title: t("widgets__blocks__data_header")))

        let fallback: [BlocksWidgetField: String] = [
            .height: "870,123",
            .time: "2:45:30 PM",
            .date: "Dec 15, 2024",
            .transactionCount: "3,456",
            .size: "1,234 KB",
            .fees: "25,059,357",
        ]

        for field in BlocksWidgetField.allCases {
            let value: String = {
                if let data = blocksViewModel.blockData { return field.value(from: data) }
                return fallback[field] ?? ""
            }()

            let titleView = AnyView(
                HStack(spacing: 8) {
                    Image(field.iconName)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(.brandAccent)
                        .frame(width: 20, height: 20)
                    BodyMText(field.label, textColor: .white80)
                }
            )
            items.append(
                WidgetEditItem(
                    key: field.rawValue,
                    type: .toggleItem,
                    titleView: titleView,
                    valueView: AnyView(BodyMSBText(value)),
                    isChecked: field.isEnabled(in: blocksOptions)
                )
            )
        }

        return items
    }

    @MainActor
    static func getNewsItems(
        newsViewModel: NewsViewModel,
        newsOptions: NewsWidgetOptions
    ) -> [WidgetEditItem] {
        var items: [WidgetEditItem] = []

        items.append(sectionHeaderItem(key: "news_content_header", title: t("widgets__news__content_header")))

        if let data = newsViewModel.widgetData {
            items.append(
                WidgetEditItem(
                    key: "showTitle",
                    type: .toggleItem,
                    titleView: AnyView(TitleText(data.title)),
                    valueView: nil,
                    isChecked: newsOptions.showTitle
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showSource",
                    type: .toggleItem,
                    titleView: AnyView(BodySSBText(data.publisher, textColor: .brandAccent)),
                    valueView: nil,
                    isChecked: newsOptions.showSource
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showDate",
                    type: .toggleItem,
                    titleView: AnyView(BodySSBText(data.timeAgo, textColor: .textSecondary)),
                    valueView: nil,
                    isChecked: newsOptions.showDate
                )
            )
        } else {
            // Fallback when no data is available
            items.append(
                WidgetEditItem(
                    key: "showTitle",
                    type: .toggleItem,
                    titleView: AnyView(TitleText("How Bitcoin changed El Salvador in more ways...")),
                    valueView: nil,
                    isChecked: newsOptions.showTitle
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showSource",
                    type: .toggleItem,
                    titleView: AnyView(BodySSBText("bitcoinmagazine.com", textColor: .brandAccent)),
                    valueView: nil,
                    isChecked: newsOptions.showSource
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showDate",
                    type: .toggleItem,
                    titleView: AnyView(BodySSBText("1 min ago", textColor: .textSecondary)),
                    valueView: nil,
                    isChecked: newsOptions.showDate
                )
            )
        }

        return items
    }

    @MainActor
    static func getPriceItems(priceOptions: PriceWidgetOptions, priceDataByPeriod _: [GraphPeriod: [PriceData]] = [:]) -> [WidgetEditItem] {
        var items: [WidgetEditItem] = []

        // CURRENCY section (single-select)
        items.append(sectionHeaderItem(key: "currency_header", title: t("widgets__price__currency")))

        let selectedPair = priceOptions.selectedPair
        for pair in tradingPairNames {
            let isSelected = selectedPair == pair
            items.append(
                WidgetEditItem(
                    key: pair,
                    type: .radioItem,
                    titleView: AnyView(
                        BodySSBText(pair, textColor: isSelected ? .textPrimary : .textSecondary)
                    ),
                    valueView: nil,
                    isChecked: isSelected
                )
            )
        }

        items.append(sectionHeaderItem(key: "timeframe_header", title: t("widgets__price__timeframe"), topInset: 16))

        for period in GraphPeriod.allCases {
            let isSelected = priceOptions.selectedPeriod == period
            items.append(
                WidgetEditItem(
                    key: period.rawValue,
                    type: .radioItem,
                    titleView: AnyView(
                        BodySSBText(period.editScreenLabel, textColor: isSelected ? .textPrimary : .textSecondary)
                    ),
                    valueView: nil,
                    isChecked: isSelected
                )
            )
        }

        return items
    }

    private static func sectionHeaderItem(key: String, title: String, topInset: CGFloat = 0) -> WidgetEditItem {
        WidgetEditItem(
            key: key,
            type: .sectionHeader,
            titleView: AnyView(
                CaptionMText(title, textColor: .textSecondary)
                    .textCase(.uppercase)
                    .padding(.top, topInset)
            ),
            valueView: nil,
            isChecked: false
        )
    }

    @MainActor
    static func getWeatherItems(
        weatherViewModel: WeatherViewModel,
        weatherOptions: WeatherWidgetOptions
    ) -> [WidgetEditItem] {
        var items: [WidgetEditItem] = []

        items.append(sectionHeaderItem(key: "weather_display_header", title: t("widgets__widget__display")))

        let data = weatherViewModel.weatherData

        for metric in WeatherDisplayMetric.allCases {
            let isSelected = weatherOptions.selectedMetric == metric
            let value = data.map { metric.value(from: $0) } ?? metric.fallbackPreviewValue
            let labelText = t(metric.labelKey)

            let titleView = AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    CaptionMText(labelText, textColor: .textSecondary)
                        .textCase(.uppercase)
                    Text(value)
                        .font(Fonts.bold(size: 30))
                        .foregroundColor(.greenAccent)
                        .kerning(-1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            )

            items.append(
                WidgetEditItem(
                    key: metric.rawValue,
                    type: .radioItem,
                    titleView: titleView,
                    valueView: nil,
                    isChecked: isSelected
                )
            )
        }

        return items
    }

    @MainActor
    static func getItems(
        for widgetType: WidgetType,
        blocksViewModel: BlocksViewModel,
        newsViewModel: NewsViewModel,
        priceDataByPeriod: [GraphPeriod: [PriceData]] = [:],
        weatherViewModel: WeatherViewModel,
        blocksOptions: BlocksWidgetOptions,
        newsOptions: NewsWidgetOptions,
        priceOptions: PriceWidgetOptions,
        weatherOptions: WeatherWidgetOptions
    ) -> [WidgetEditItem] {
        switch widgetType {
        case .blocks:
            return getBlocksItems(blocksViewModel: blocksViewModel, blocksOptions: blocksOptions)
        case .news:
            return getNewsItems(newsViewModel: newsViewModel, newsOptions: newsOptions)
        case .price:
            return getPriceItems(priceOptions: priceOptions, priceDataByPeriod: priceDataByPeriod)
        case .weather:
            return getWeatherItems(weatherViewModel: weatherViewModel, weatherOptions: weatherOptions)
        case .calculator, .suggestions, .facts:
            return []
        }
    }
}
