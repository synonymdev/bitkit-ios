import BitkitCore
import Foundation

/// Response from WeatherService containing raw weather data
struct WeatherServiceResponse {
    let historicalPercentile: FeePercentile // percentile info for condition calculation
    let fees: FeeRates
}

/// Historical fee percentile information
struct FeePercentile {
    let lowThreshold: Double // 33rd percentile
    let highThreshold: Double // 66th percentile
}

/// Service for fetching and caching Bitcoin fee weather data
class WeatherService {
    static let shared = WeatherService()
    private let cache = UserDefaults.standard
    private let cacheKey = "weather_widget_cache"
    private let baseUrl = "https://mempool.space/api/v1"
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    private let percentileLow = 0.33
    private let percentileHigh = 0.66

    private let coreService: CoreService

    private init() {
        coreService = CoreService.shared
    }

    /// Fetches weather data from mempool.space API and fee estimates
    /// - Returns: Raw weather service response
    /// - Throws: URLError or decoding error
    func fetchWeatherData() async throws -> WeatherServiceResponse {
        // Fetch fee estimates and historical data concurrently
        async let feeEstimates = fetchFeeEstimates()
        async let historicalData = fetchHistoricalData()

        let (fees, history) = try await (feeEstimates, historicalData)

        let percentile = try calculatePercentileThresholds(history: history)

        return WeatherServiceResponse(
            historicalPercentile: percentile,
            fees: fees
        )
    }

    /// Caches weather data to UserDefaults
    /// - Parameter data: Weather data to cache
    func cacheData(_ data: WeatherData) {
        do {
            let encoder = JSONEncoder()
            let encoded = try encoder.encode(data)
            cache.set(encoded, forKey: cacheKey)
        } catch {
            // Handle silently
        }
    }

    /// Retrieves cached weather data
    /// - Returns: Weather data if available
    func getCachedData() -> WeatherData? {
        guard let data = cache.data(forKey: cacheKey) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(WeatherData.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Private Methods

    /// Fetches fee estimates
    private func fetchFeeEstimates() async throws -> FeeRates {
        var fees = try await coreService.blocktank.fees(refresh: true)
        if fees == nil {
            Logger.warn("Failed to fetch fresh fee rate, using cached rate.")
            fees = try await coreService.blocktank.fees(refresh: false)
        }

        guard let fees else {
            throw AppError(message: "Fees unavailable from bitkit-core", debugMessage: nil)
        }

        return fees
    }

    /// Fetches historical fee data from mempool.space
    private func fetchHistoricalData() async throws -> [BlockFeeRates] {
        guard let url = URL(string: "\(baseUrl)/mining/blocks/fee-rates/3m") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode([BlockFeeRates].self, from: data)
    }

    /// Calculates percentile thresholds from historical data
    private func calculatePercentileThresholds(history: [BlockFeeRates]) throws -> FeePercentile {
        guard !history.isEmpty else {
            throw URLError(
                .resourceUnavailable,
                userInfo: [
                    NSLocalizedDescriptionKey: "Historical fee data is unavailable",
                ]
            )
        }

        let historical = history.map(\.avgFee_50)
        let sorted = historical.sorted()

        let lowThreshold = sorted[Int(Double(sorted.count) * percentileLow)]
        let highThreshold = sorted[Int(Double(sorted.count) * percentileHigh)]

        return FeePercentile(lowThreshold: lowThreshold, highThreshold: highThreshold)
    }
}
