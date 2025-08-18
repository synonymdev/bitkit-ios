import SwiftUI

// MARK: - Widget Edit Item Models

enum WidgetItemType {
    case toggleItem
    case staticItem
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

    // Convenience initializer for string titles and values
    init(key: String, type: WidgetItemType, title: String, value: String? = nil, isChecked: Bool) {
        self.key = key
        self.type = type
        titleView = AnyView(BodySSBText(title, textColor: .textSecondary))
        valueView = value.map { AnyView(BodySSBText($0)) }
        self.isChecked = isChecked
    }

    // Convenience initializer for string titles and view values
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

        if let data = blocksViewModel.blockData {
            items.append(
                WidgetEditItem(
                    key: "height",
                    type: .toggleItem,
                    title: "Block",
                    value: data.height,
                    isChecked: blocksOptions.height
                )
            )

            items.append(
                WidgetEditItem(
                    key: "time",
                    type: .toggleItem,
                    title: "Time",
                    value: data.time,
                    isChecked: blocksOptions.time
                )
            )

            items.append(
                WidgetEditItem(
                    key: "date",
                    type: .toggleItem,
                    title: "Date",
                    value: data.date,
                    isChecked: blocksOptions.date
                )
            )

            items.append(
                WidgetEditItem(
                    key: "transactionCount",
                    type: .toggleItem,
                    title: "Transactions",
                    value: data.transactionCount,
                    isChecked: blocksOptions.transactionCount
                )
            )

            items.append(
                WidgetEditItem(
                    key: "size",
                    type: .toggleItem,
                    title: "Size",
                    value: data.size,
                    isChecked: blocksOptions.size
                )
            )

            items.append(
                WidgetEditItem(
                    key: "weight",
                    type: .toggleItem,
                    title: "Weight",
                    value: data.weight,
                    isChecked: blocksOptions.weight
                )
            )

            items.append(
                WidgetEditItem(
                    key: "difficulty",
                    type: .toggleItem,
                    title: "Difficulty",
                    value: data.difficulty,
                    isChecked: blocksOptions.difficulty
                )
            )

            items.append(
                WidgetEditItem(
                    key: "hash",
                    type: .toggleItem,
                    title: "Hash",
                    value: data.hash,
                    isChecked: blocksOptions.hash
                )
            )

            items.append(
                WidgetEditItem(
                    key: "merkleRoot",
                    type: .toggleItem,
                    title: "Merkle Root",
                    value: data.merkleRoot,
                    isChecked: blocksOptions.merkleRoot
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showSource",
                    type: .toggleItem,
                    title: localizedString("widgets__widget__source"),
                    valueView: AnyView(BodySSBText("mempool.space", textColor: .textSecondary)),
                    isChecked: blocksOptions.showSource
                )
            )
        } else {
            // Fallback when no data is available
            items.append(
                WidgetEditItem(
                    key: "height",
                    type: .toggleItem,
                    title: "Block",
                    value: "870,123",
                    isChecked: blocksOptions.height
                )
            )

            items.append(
                WidgetEditItem(
                    key: "time",
                    type: .toggleItem,
                    title: "Time",
                    value: "2:45:30 PM",
                    isChecked: blocksOptions.time
                )
            )

            items.append(
                WidgetEditItem(
                    key: "date",
                    type: .toggleItem,
                    title: "Date",
                    value: "Dec 15, 2024",
                    isChecked: blocksOptions.date
                )
            )

            items.append(
                WidgetEditItem(
                    key: "transactionCount",
                    type: .toggleItem,
                    title: "Transactions",
                    value: "3,456",
                    isChecked: blocksOptions.transactionCount
                )
            )

            items.append(
                WidgetEditItem(
                    key: "size",
                    type: .toggleItem,
                    title: "Size",
                    value: "1,234 KB",
                    isChecked: blocksOptions.size
                )
            )

            items.append(
                WidgetEditItem(
                    key: "weight",
                    type: .toggleItem,
                    title: "Weight",
                    value: "3.45 MWU",
                    isChecked: blocksOptions.weight
                )
            )

            items.append(
                WidgetEditItem(
                    key: "difficulty",
                    type: .toggleItem,
                    title: "Difficulty",
                    value: "102.45 T",
                    isChecked: blocksOptions.difficulty
                )
            )

            items.append(
                WidgetEditItem(
                    key: "hash",
                    type: .toggleItem,
                    title: "Hash",
                    value: "00000000000000000002a7c4c1e48d76c5a37902165a270156b7a8d72728a054",
                    isChecked: blocksOptions.hash
                )
            )

            items.append(
                WidgetEditItem(
                    key: "merkleRoot",
                    type: .toggleItem,
                    title: "Merkle Root",
                    value: "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
                    isChecked: blocksOptions.merkleRoot
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showSource",
                    type: .toggleItem,
                    title: localizedString("widgets__widget__source"),
                    valueView: AnyView(BodySSBText("mempool.space", textColor: .textSecondary)),
                    isChecked: blocksOptions.showSource
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
                title: localizedString("widgets__widget__source"),
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

        if let data = newsViewModel.widgetData {
            items.append(
                WidgetEditItem(
                    key: "showDate",
                    type: .toggleItem,
                    titleView: AnyView(BodyMText(data.timeAgo, textColor: .textPrimary)),
                    valueView: nil,
                    isChecked: newsOptions.showDate
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showTitle",
                    type: .staticItem,
                    titleView: AnyView(TitleText(data.title)),
                    valueView: nil,
                    isChecked: true // Static items are always shown
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showSource",
                    type: .toggleItem,
                    title: localizedString("widgets__widget__source"),
                    valueView: AnyView(BodySSBText(data.publisher, textColor: .textSecondary)),
                    isChecked: newsOptions.showSource
                )
            )
        } else {
            // Fallback when no data is available
            items.append(
                WidgetEditItem(
                    key: "showDate",
                    type: .toggleItem,
                    titleView: AnyView(BodyMText("13 hours ago", textColor: .textPrimary)),
                    valueView: nil,
                    isChecked: newsOptions.showDate
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showTitle",
                    type: .staticItem,
                    titleView: AnyView(TitleText("Exodus Launches XO Pay, An In-App Bitcoin And Crypto Purchase Solution")),
                    valueView: nil,
                    isChecked: true // Static items are always shown
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showSource",
                    type: .toggleItem,
                    title: localizedString("widgets__widget__source"),
                    valueView: AnyView(BodySSBText("Bitcoin Magazine", textColor: .textSecondary)),
                    isChecked: newsOptions.showSource
                )
            )
        }

        return items
    }

    @MainActor
    static func getPriceItems(priceOptions: PriceWidgetOptions, priceDataByPeriod: [GraphPeriod: [PriceData]] = [:]) -> [WidgetEditItem] {
        var items: [WidgetEditItem] = []

        // Trading pair options with live or fallback prices
        let fallbackPrices = ["$ 43,250", "€ 39,850", "£ 34,120", "¥ 6,245,000"]

        // Use current period data for trading pair prices
        let currentPeriodData = priceDataByPeriod[priceOptions.selectedPeriod] ?? []

        for (index, pair) in tradingPairNames.enumerated() {
            // Try to find live data for this pair
            let livePrice = currentPeriodData.first { $0.name == pair }?.price ?? fallbackPrices[index]

            items.append(
                WidgetEditItem(
                    key: pair,
                    type: .toggleItem,
                    title: pair,
                    value: livePrice,
                    isChecked: priceOptions.selectedPairs.contains(pair)
                )
            )
        }

        // Period selection (radio group) with charts
        let periods: [GraphPeriod] = [.oneDay, .oneWeek, .oneMonth, .oneYear]

        for period in periods {
            // Get data for this specific period
            let periodData = priceDataByPeriod[period] ?? []
            let firstPairData = periodData.first

            items.append(
                WidgetEditItem(
                    key: "period_\(period.rawValue)",
                    type: .toggleItem,
                    titleView: AnyView(
                        PriceChart(
                            values: firstPairData?.pastValues ?? [],
                            isPositive: firstPairData?.change.isPositive ?? true,
                            period: period.rawValue
                        )
                    ),
                    valueView: nil,
                    isChecked: priceOptions.selectedPeriod == period
                )
            )
        }

        items.append(
            WidgetEditItem(
                key: "showSource",
                type: .toggleItem,
                title: localizedString("widgets__widget__source"),
                valueView: AnyView(BodySSBText("Bitfinex.com", textColor: .textSecondary)),
                isChecked: priceOptions.showSource
            )
        )

        return items
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
                    valueView: AnyView(Text(data.condition.icon).font(.system(size: 30))),
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
                    title: localizedString("widgets__weather__current_fee"),
                    value: data.currentFee,
                    isChecked: weatherOptions.showMedian
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showNextBlockFee",
                    type: .toggleItem,
                    title: localizedString("widgets__weather__next_block"),
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
                    title: localizedString("widgets__weather__current_fee"),
                    value: "$0.50",
                    isChecked: weatherOptions.showMedian
                )
            )

            items.append(
                WidgetEditItem(
                    key: "showNextBlockFee",
                    type: .toggleItem,
                    title: localizedString("widgets__weather__next_block"),
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
        case .calculator:
            return []
        }
    }
}
