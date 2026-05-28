import Foundation

// MARK: - Public Models

public struct TradingPair {
    public let name: String
    public let base: String
    public let quote: String
    public let symbol: String
}

public let tradingPairs: [TradingPair] = [
    TradingPair(name: "BTC/USD", base: "BTC", quote: "USD", symbol: "$"),
    TradingPair(name: "BTC/EUR", base: "BTC", quote: "EUR", symbol: "€"),
    TradingPair(name: "BTC/GBP", base: "BTC", quote: "GBP", symbol: "£"),
    TradingPair(name: "BTC/JPY", base: "BTC", quote: "JPY", symbol: "¥"),
]

/// Convenience array for just the pair names.
public let tradingPairNames: [String] = tradingPairs.map(\.name)

enum GraphPeriod: String, CaseIterable, Codable {
    case oneDay = "1D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case oneYear = "1Y"
}

struct PriceChange: Equatable {
    let isPositive: Bool
    let formatted: String
}

struct PriceData: Equatable {
    let name: String
    let change: PriceChange
    let price: String
    let pastValues: [Double]
}

// MARK: - Cache Representation

/// Persistable representation of `PriceData` shared between the main app and the widget extension via App Group.
struct CachedPriceData: Codable, Equatable {
    let name: String
    let changeIsPositive: Bool
    let changeFormatted: String
    let price: String
    let pastValues: [Double]

    init(from data: PriceData) {
        name = data.name
        changeIsPositive = data.change.isPositive
        changeFormatted = data.change.formatted
        price = data.price
        pastValues = data.pastValues
    }

    func toPriceData() -> PriceData {
        PriceData(
            name: name,
            change: PriceChange(isPositive: changeIsPositive, formatted: changeFormatted),
            price: price,
            pastValues: pastValues
        )
    }
}

// MARK: - Cache Helpers (App Group)

/// Cache reader/writer used by both the main app and the widget extension.
enum PriceWidgetCache {
    static let appGroupSuiteName = "group.bitkit"
    private static let keyPrefix = "price_widget_cache_"

    private static func cacheKey(pair: String, period: GraphPeriod) -> String {
        "\(keyPrefix)\(pair)_\(period.rawValue)"
    }

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    static func save(_ data: PriceData, period: GraphPeriod) {
        guard let encoded = try? JSONEncoder().encode(CachedPriceData(from: data)) else { return }
        defaults().set(encoded, forKey: cacheKey(pair: data.name, period: period))
    }

    static func load(pair: String, period: GraphPeriod) -> PriceData? {
        let key = cacheKey(pair: pair, period: period)
        let group = defaults()

        if let data = group.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CachedPriceData.self, from: data)
        {
            return decoded.toPriceData()
        }

        // One-time migration from the pre-App-Group standard suite.
        if group !== UserDefaults.standard,
           let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CachedPriceData.self, from: data)
        {
            group.set(data, forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            return decoded.toPriceData()
        }

        return nil
    }

    static func loadAll(pairs: [String], period: GraphPeriod) -> [PriceData]? {
        let items = pairs.compactMap { load(pair: $0, period: period) }
        return items.count == pairs.count ? items : nil
    }
}
