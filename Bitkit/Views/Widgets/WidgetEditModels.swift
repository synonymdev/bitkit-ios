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
                if field == .showSource { return "mempool.space" }
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
                    BodySSBText(field.inAppLabel, textColor: .textSecondary)
                }
            )
            items.append(
                WidgetEditItem(
                    key: field.rawValue,
                    type: .toggleItem,
                    titleView: titleView,
                    valueView: AnyView(BodySSBText(value, textColor: .textSecondary)),
                    isChecked: field.isEnabled(in: blocksOptions)
                )
            )
        }

        return items
    }

    @MainActor
    static func getFactsItems(factsViewModel: FactsViewModel, factsOptions: FactsWidgetOptions) -> [WidgetEditItem] {
        var items: [WidgetEditItem] = []

        items.append(
            WidgetEditItem(
                key: "showTitle",
                type: .staticItem,
                titleView: AnyView(TitleText(factsViewModel.fact)),
                isChecked: true
            )
        )

        items.append(
            WidgetEditItem(
                key: "showSource",
                type: .toggleItem,
                title: t("widgets__widget__source"),
                valueView: AnyView(BodySSBText("mempool.space", textColor: .textSecondary)),
                isChecked: factsOptions.showSource
            )
        )

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
                    type: .toggleItem,
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
                    type: .toggleItem,
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

        if let data = weatherViewModel.weatherData {
            items.append(
                WidgetEditItem(
                    key: "showStatus",
                    type: .toggleItem,
                    titleView: AnyView(TitleText(data.condition.title)),
                    valueView: AnyView(Text(data.condition.icon).font(.system(size: 52))),
                    isChecked: weatherOptions.showStatus
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showText",
                    type: .toggleItem,
                    titleView: AnyView(BodyMText(data.condition.description, textColor: .textPrimary)),
                    valueView: nil,
                    isChecked: weatherOptions.showText
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showMedian",
                    type: .toggleItem,
                    title: t("widgets__weather__current_fee"),
                    value: data.currentFee,
                    isChecked: weatherOptions.showMedian
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showNextBlockFee",
                    type: .toggleItem,
                    title: t("widgets__weather__next_block"),
                    value: "\(data.nextBlockFee) ₿/vByte",
                    isChecked: weatherOptions.showNextBlockFee
                )
            )
        } else {
            // Fallback when no data is available
            items.append(
                WidgetEditItem(
                    key: "showStatus",
                    type: .toggleItem,
                    titleView: AnyView(TitleText("Good")),
                    valueView: AnyView(Text("☀️").font(.system(size: 30))),
                    isChecked: weatherOptions.showStatus
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showText",
                    type: .toggleItem,
                    titleView: AnyView(BodyMText("Fees are low and transactions are fast", textColor: .textPrimary)),
                    valueView: nil,
                    isChecked: weatherOptions.showText
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showMedian",
                    type: .toggleItem,
                    title: t("widgets__weather__current_fee"),
                    value: "$0.50",
                    isChecked: weatherOptions.showMedian
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showNextBlockFee",
                    type: .toggleItem,
                    title: t("widgets__weather__next_block"),
                    value: "15 ₿/vByte",
                    isChecked: weatherOptions.showNextBlockFee
                )
            )
        }

        return items
    }

    @MainActor
    static func getItems(
        for widgetType: WidgetType,
        blocksViewModel: BlocksViewModel,
        factsViewModel: FactsViewModel,
        newsViewModel: NewsViewModel,
        priceDataByPeriod: [GraphPeriod: [PriceData]] = [:],
        weatherViewModel: WeatherViewModel,
        blocksOptions: BlocksWidgetOptions,
        factsOptions: FactsWidgetOptions,
        newsOptions: NewsWidgetOptions,
        priceOptions: PriceWidgetOptions,
        weatherOptions: WeatherWidgetOptions
    ) -> [WidgetEditItem] {
        switch widgetType {
        case .blocks:
            return getBlocksItems(blocksViewModel: blocksViewModel, blocksOptions: blocksOptions)
        case .facts:
            return getFactsItems(factsViewModel: factsViewModel, factsOptions: factsOptions)
        case .news:
            return getNewsItems(newsViewModel: newsViewModel, newsOptions: newsOptions)
        case .price:
            return getPriceItems(priceOptions: priceOptions, priceDataByPeriod: priceDataByPeriod)
        case .weather:
            return getWeatherItems(weatherViewModel: weatherViewModel, weatherOptions: weatherOptions)
        case .calculator, .suggestions:
            return []
        }
    }
}
