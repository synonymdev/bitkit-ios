import BitkitCore
import Foundation

/// Response from WeatherService containing raw weather data
struct WeatherServiceResponse {
    let historicalPercentile: FeePercentile // percentile info for condition calculation
    let fees: FeeRates
}

/// Service for fetching and caching Bitcoin fee weather data.
class WeatherService {
    static let shared = WeatherService()
    private let baseUrl = "https://mempool.space/api/v1"
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    private let coreService: CoreService

    private init() {
        coreService = CoreService.shared
        WeatherWidgetCache.legacyDropStandardSuiteCache()
    }

    /// Fetches weather data from mempool.space API and fee estimates
    /// - Returns: Raw weather service response
    /// - Throws: URLError or decoding error
    func fetchWeatherData() async throws -> WeatherServiceResponse {
        // Fetch fee estimates and historical data concurrently
        async let feeEstimates = fetchFeeEstimates()
        async let historicalData = fetchHistoricalData()

        let (fees, history) = try await (feeEstimates, historicalData)

        guard let percentile = FeePercentile(history: history) else {
            throw URLError(
                .resourceUnavailable,
                userInfo: [NSLocalizedDescriptionKey: "Historical fee data is unavailable"]
            )
        }

        return WeatherServiceResponse(
            historicalPercentile: percentile,
            fees: fees
        )
    }

    /// Caches weather data to the App Group so the WidgetKit extension can read it.
    func cacheData(_ data: CachedWeather) {
        WeatherWidgetCache.saveLatest(data)
    }

    /// Retrieves cached weather data from the App Group.
    func getCachedData() -> CachedWeather? {
        WeatherWidgetCache.loadLatest()
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
}
