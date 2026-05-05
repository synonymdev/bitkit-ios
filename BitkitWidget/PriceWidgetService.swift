import Foundation

/// Slim price fetcher used inside the WidgetKit extension.
///
/// Reads cached `PriceData` from the App Group (written by the main app's `PriceService`)
/// and falls back to a direct network fetch when no cache is available or when explicitly
/// asked to refresh. The cache itself is owned by the main app — this service intentionally
/// does not write back to it, to keep the extension's footprint minimal.
enum PriceWidgetService {
    enum FetchError: Error {
        case invalidURL
        case invalidPair
        case noPriceDataAvailable
    }

    // MARK: - Cache

    static func cachedPrices(pairs: [String], period: GraphPeriod) -> [PriceData]? {
        PriceWidgetCache.loadAll(pairs: pairs, period: period)
    }

    // MARK: - Fresh Fetch

    static func fetchFreshPrices(pairs: [String], period: GraphPeriod) async throws -> [PriceData] {
        let results = await withTaskGroup(of: PriceData?.self) { group -> [PriceData] in
            for pair in pairs {
                group.addTask { try? await fetchPair(pairName: pair, period: period) }
            }

            var collected: [PriceData] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        guard !results.isEmpty else { throw FetchError.noPriceDataAvailable }
        return results
    }

    // MARK: - Per-pair pipeline

    private static func fetchPair(pairName: String, period: GraphPeriod) async throws -> PriceData {
        guard let pair = tradingPairs.first(where: { $0.name == pairName }) else {
            throw FetchError.invalidPair
        }

        let ticker = "\(pair.base)\(pair.quote)"
        let candles = try await fetchCandles(ticker: ticker, period: period)
        let pastValues = candles.sorted(by: { $0.timestamp < $1.timestamp }).map(\.close)

        let latest = try await fetchLatestPrice(ticker: ticker)
        let updated = Array(pastValues.dropLast()) + [latest]

        return PriceData(
            name: pairName,
            change: priceChange(from: updated),
            price: formatPrice(pair: pair, price: latest),
            pastValues: updated
        )
    }

    private static func fetchLatestPrice(ticker: String) async throws -> Double {
        guard let url = URL(string: "\(WidgetEnv.priceFeedBaseUrl)/price/\(ticker)/latest") else {
            throw FetchError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(LatestPriceResponse.self, from: data).price
    }

    private static func fetchCandles(ticker: String, period: GraphPeriod) async throws -> [Candle] {
        guard let url = URL(string: "\(WidgetEnv.priceFeedBaseUrl)/price/\(ticker)/history/\(period.rawValue)") else {
            throw FetchError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Candle].self, from: data)
    }

    private static func priceChange(from values: [Double]) -> PriceChange {
        guard let first = values.first, let last = values.last, first != 0, values.count >= 2 else {
            return PriceChange(isPositive: true, formatted: "+0%")
        }
        let change = last / first - 1
        let sign = change >= 0 ? "+" : ""
        return PriceChange(
            isPositive: change >= 0,
            formatted: "\(sign)\(String(format: "%.2f", change * 100))%"
        )
    }

    private static func formatPrice(pair: TradingPair, price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: NSNumber(value: price)) ?? String(format: "%.0f", price)
        return "\(pair.symbol) \(formatted)"
    }
}

// MARK: - Wire Models

private struct LatestPriceResponse: Codable {
    let price: Double
    let timestamp: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Double.self, forKey: .timestamp)

        // Server may serialize price as either string or number.
        if let priceString = try? container.decode(String.self, forKey: .price),
           let parsed = Double(priceString)
        {
            price = parsed
        } else {
            price = try container.decode(Double.self, forKey: .price)
        }
    }
}

private struct Candle: Codable {
    let timestamp: Double
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}
