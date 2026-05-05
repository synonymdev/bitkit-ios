import Foundation

// MARK: - Data Models

struct PriceResponse: Codable {
    let price: Double
    let timestamp: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Double.self, forKey: .timestamp)

        // Handle price as either String or Double
        if let priceString = try? container.decode(String.self, forKey: .price) {
            guard let priceValue = Double(priceString) else {
                throw DecodingError.dataCorruptedError(forKey: .price, in: container, debugDescription: "Price string is not a valid number")
            }
            price = priceValue
        } else {
            price = try container.decode(Double.self, forKey: .price)
        }
    }
}

struct CandleResponse: Codable {
    let timestamp: Double
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

enum PriceServiceError: Error {
    case invalidURL
    case invalidPair
    case networkError
    case decodingError
    case noPriceDataAvailable
}

// MARK: - Price Service

class PriceService {
    static let shared = PriceService()
    private let baseURL = WidgetEnv.priceFeedBaseUrl

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
    /// Individual pair failures are logged but don't fail the entire request - only fails if ALL pairs fail
    @discardableResult
    private func fetchFreshData(pairs: [String], period: GraphPeriod) async throws -> [PriceData] {
        let priceDataArray = await withTaskGroup(of: PriceData?.self) { group in
            var results: [PriceData] = []

            for pairName in pairs {
                group.addTask {
                    do {
                        return try await self.fetchPairData(pairName: pairName, period: period)
                    } catch {
                        Logger.warn("Failed to fetch price data for \(pairName): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            for await priceData in group {
                if let data = priceData {
                    results.append(data)
                }
            }

            return results
        }

        guard !priceDataArray.isEmpty else {
            throw PriceServiceError.noPriceDataAvailable
        }

        return priceDataArray
    }

    private func getCachedData(pairs: [String], period: GraphPeriod) -> [PriceData]? {
        PriceWidgetCache.loadAll(pairs: pairs, period: period)
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

    private func cacheData(pairName _: String, period: GraphPeriod, data: PriceData) {
        PriceWidgetCache.save(data, period: period)
        PriceHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
    }
}
