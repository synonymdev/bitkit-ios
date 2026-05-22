import Foundation

/// Pure HTTP layer for the mempool.space endpoints consumed by both the main app
/// (`WeatherService`) and the WidgetKit extension (`WeatherWidgetService`). Keeping the URL
/// strings, wire models, and decoding in one place avoids drift between the two targets.
enum MempoolWeatherAPI {
    enum APIError: Error {
        case invalidURL
        case unexpectedResponse
    }

    private static let baseUrl = "https://mempool.space/api/v1"

    // MARK: - Endpoints

    /// `/v1/fees/recommended` — current recommended fee rates in sats/vByte.
    static func fetchRecommendedFees() async throws -> RecommendedFees {
        try await get(path: "fees/recommended")
    }

    /// `/v1/prices` — BTC spot price map (currency code → unit price for 1 BTC). Mempool also
    /// returns a `time` field which is filtered out here so the returned dictionary only
    /// contains fiat amounts.
    static func fetchPrices() async throws -> [String: Double] {
        let raw: [String: Double] = try await get(path: "prices")
        return raw.filter { $0.key != "time" }
    }

    /// `/v1/mining/blocks/fee-rates/3m` — last 3 months of per-block fee summaries used to
    /// derive the percentile thresholds in `FeePercentile`.
    static func fetchHistoricalFees() async throws -> [BlockFeeRates] {
        try await get(path: "mining/blocks/fee-rates/3m")
    }

    // MARK: - HTTP helper

    private static func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: "\(baseUrl)/\(path)") else {
            throw APIError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.unexpectedResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Wire models

/// Decoded shape of `/v1/fees/recommended`. All values are sats/vByte.
struct RecommendedFees: Codable {
    let fastestFee: Int
    let halfHourFee: Int
    let hourFee: Int
    let economyFee: Int
    let minimumFee: Int
}
