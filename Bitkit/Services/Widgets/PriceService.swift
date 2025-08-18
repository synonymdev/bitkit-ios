import Foundation

// MARK: - Data Models

public struct TradingPair {
    public let name: String
    public let base: String
    public let quote: String
    public let symbol: String
}

struct PriceResponse: Codable {
    let price: Double
    let timestamp: Double
}

struct CandleResponse: Codable {
    let timestamp: Double
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

struct PriceChange {
    let isPositive: Bool
    let formatted: String
}

struct PriceData {
    let name: String
    let change: PriceChange
    let price: String
    let pastValues: [Double]
}

enum GraphPeriod: String, CaseIterable, Codable {
    case oneDay = "1D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case oneYear = "1Y"
}

enum PriceServiceError: Error {
    case invalidURL
    case invalidPair
    case networkError
    case decodingError
}

// MARK: - Trading Pairs Constants

public let tradingPairs: [TradingPair] = [
    TradingPair(name: "BTC/USD", base: "BTC", quote: "USD", symbol: "$"),
    TradingPair(name: "BTC/EUR", base: "BTC", quote: "EUR", symbol: "€"),
    TradingPair(name: "BTC/GBP", base: "BTC", quote: "GBP", symbol: "£"),
    TradingPair(name: "BTC/JPY", base: "BTC", quote: "JPY", symbol: "¥"),
]

// Convenience array for just the pair names
public let tradingPairNames: [String] = tradingPairs.map(\.name)

// MARK: - Helper Models

private struct CachedPriceData: Codable {
    let name: String
    let changeIsPositive: Bool
    let changeFormatted: String
    let price: String
    let pastValues: [Double]
}

// MARK: - Caching System

class PriceWidgetCache {
    static let shared = PriceWidgetCache()
    private let userDefaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func set(_ value: some Codable, forKey key: String) {
        do {
            let data = try encoder.encode(value)
            userDefaults.set(data, forKey: "price_widget_cache_\(key)")
        } catch {
            print("Failed to cache price data for key \(key): \(error)")
        }
    }

    func get<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = userDefaults.data(forKey: "price_widget_cache_\(key)") else {
            return nil
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            print("Failed to decode cached price data for key \(key): \(error)")
            return nil
        }
    }
}

// MARK: - Price Service

class PriceService {
    static let shared = PriceService()
    private let baseURL = "https://feeds.synonym.to/price-feed/api"

    private init() {}

    /// Fetches price data for given pairs and period using stale-while-revalidate strategy
    /// - Parameters:
    ///   - pairs: Array of trading pair names (e.g., ["BTC/USD"])
    ///   - period: Time period for historical data
    ///   - returnCachedImmediately: If true, returns cached data immediately if available
    /// - Returns: Array of PriceData
    /// - Throws: PriceServiceError
    func fetchPriceData(pairs: [String], period: GraphPeriod, returnCachedImmediately: Bool = true) async throws -> [PriceData] {
        // If we want cached data and it exists, return it immediately
        if returnCachedImmediately, let cachedData = getCachedData(pairs: pairs, period: period) {
            // Start fresh fetch in background to update cache (don't await)
            Task {
                do {
                    try await fetchFreshData(pairs: pairs, period: period)
                    // Cache will be updated automatically in fetchFreshData
                } catch {
                    // Silent failure for background updates
                    print("Background price data update failed: \(error)")
                }
            }
            return cachedData
        }

        // No cache available or cache not requested - fetch fresh data
        return try await fetchFreshData(pairs: pairs, period: period)
    }

    /// Fetches fresh data from API (always hits the network)
    @discardableResult
    private func fetchFreshData(pairs: [String], period: GraphPeriod) async throws -> [PriceData] {
        let priceDataArray = try await withThrowingTaskGroup(of: PriceData.self) { group in
            var results: [PriceData] = []

            for pairName in pairs {
                group.addTask {
                    try await self.fetchPairData(pairName: pairName, period: period)
                }
            }

            for try await priceData in group {
                results.append(priceData)
            }

            return results
        }

        return priceDataArray
    }

    private func getCachedData(pairs: [String], period: GraphPeriod) -> [PriceData]? {
        let cache = PriceWidgetCache.shared
        let cachedItems = pairs.compactMap { pairName in
            cache.get(CachedPriceData.self, forKey: "\(pairName)_\(period.rawValue)")
        }

        guard cachedItems.count == pairs.count else { return nil }

        return cachedItems.map { cached in
            PriceData(
                name: cached.name,
                change: PriceChange(isPositive: cached.changeIsPositive, formatted: cached.changeFormatted),
                price: cached.price,
                pastValues: cached.pastValues
            )
        }
    }

    private func fetchPairData(pairName: String, period: GraphPeriod) async throws -> PriceData {
        guard let pair = tradingPairs.first(where: { $0.name == pairName }) else {
            throw PriceServiceError.invalidPair
        }

        let ticker = "\(pair.base)\(pair.quote)"

        // Fetch historical data
        let candles = try await fetchCandles(ticker: ticker, period: period)
        let sortedCandles = candles.sorted { $0.timestamp < $1.timestamp }
        let pastValues = sortedCandles.map(\.close)

        // Fetch latest price
        let latestPrice = try await fetchLatestPrice(ticker: ticker)

        // Replace last historical value with latest price
        let updatedPastValues = Array(pastValues.dropLast()) + [latestPrice]

        // Calculate change
        let change = calculateChange(values: updatedPastValues)

        // Format price
        let formattedPrice = formatPrice(pair: pair, price: latestPrice)

        let priceData = PriceData(
            name: pairName,
            change: change,
            price: formattedPrice,
            pastValues: updatedPastValues
        )

        // Cache the data
        cacheData(pairName: pairName, period: period, data: priceData)

        return priceData
    }

    private func fetchLatestPrice(ticker: String) async throws -> Double {
        guard let url = URL(string: "\(baseURL)/price/\(ticker)/latest") else {
            throw PriceServiceError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(PriceResponse.self, from: data)
        return response.price
    }

    private func fetchCandles(ticker: String, period: GraphPeriod) async throws -> [CandleResponse] {
        guard let url = URL(string: "\(baseURL)/price/\(ticker)/history/\(period.rawValue)") else {
            throw PriceServiceError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([CandleResponse].self, from: data)
    }

    private func calculateChange(values: [Double]) -> PriceChange {
        guard values.count >= 2 else {
            return PriceChange(isPositive: true, formatted: "+0%")
        }

        let change = values.last! / values.first! - 1
        let sign = change >= 0 ? "+" : ""
        let percentage = change * 100

        return PriceChange(
            isPositive: change >= 0,
            formatted: "\(sign)\(String(format: "%.2f", percentage))%"
        )
    }

    private func formatPrice(pair: TradingPair, price: Double) -> String {
        // Format with localized thousands separator, no decimals
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0

        let formatted = formatter.string(from: NSNumber(value: price)) ?? String(format: "%.0f", price)
        return "\(pair.symbol) \(formatted)"
    }

    private func cacheData(pairName: String, period: GraphPeriod, data: PriceData) {
        let cacheKey = "\(pairName)_\(period.rawValue)"
        let cachedData = CachedPriceData(
            name: data.name,
            changeIsPositive: data.change.isPositive,
            changeFormatted: data.change.formatted,
            price: data.price,
            pastValues: data.pastValues
        )
        PriceWidgetCache.shared.set(cachedData, forKey: cacheKey)
    }
}
