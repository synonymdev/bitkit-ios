import Foundation
import SwiftUI

/// Block fee rates structure from mempool.space API
struct BlockFeeRates: Codable {
    let avgHeight: Int
    let timestamp: Int
    let avgFee_0: Double
    let avgFee_10: Double
    let avgFee_25: Double
    let avgFee_50: Double
    let avgFee_75: Double
    let avgFee_90: Double
    let avgFee_100: Double
}

/// Weather widget view model for handling fee weather data
@MainActor
class WeatherViewModel: ObservableObject {
    static let shared = WeatherViewModel()

    @Published var weatherData: WeatherData?
    @Published var isLoading: Bool = false
    @Published var error: Error?

    private let weatherService = WeatherService.shared
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes
    private var hasStartedUpdates = false

    private let vbytesSize = 140 // average native segwit transaction size

    // Currency conversion dependency - will be set by views that need currency conversion
    weak var currencyViewModel: CurrencyViewModel?

    /// Private initializer for the singleton instance
    private init() {
        // No automatic loading - widgets will control when to load
    }

    /// Sets the currency view model for currency conversion
    func setCurrencyViewModel(_ currencyViewModel: CurrencyViewModel) {
        self.currencyViewModel = currencyViewModel
    }

    /// Start loading data and periodic updates (idempotent - only starts once)
    func startUpdates() {
        guard !hasStartedUpdates else { return }

        hasStartedUpdates = true

        // Load initial data
        Task {
            await fetchWeatherData()
        }

        // Start refresh timer
        startRefreshTimer()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.fetchWeatherData()
            }
        }
    }

    func fetchWeatherData() async {
        Logger.debug("Loading weather data")

        // Try to load cached data first and return immediately if available
        if let cached = weatherService.getCachedData() {
            weatherData = cached
            isLoading = false

            // Start fresh fetch in background to update cache (don't await)
            Task {
                do {
                    try await fetchFreshWeatherData()
                    // Cache will be updated automatically in fetchFreshWeatherData
                } catch {
                    // Silent failure for background updates
                    print("Background weather data update failed: \(error)")
                }
            }
            return
        }

        // No cache available - fetch fresh data with loading state
        isLoading = true
        error = nil

        do {
            try await fetchFreshWeatherData()
        } catch {
            Logger.error("Failed to load weather data: \(error.localizedDescription)")
            if let decodingError = error as? DecodingError {
                Logger.error("Decoding error details: \(decodingError)")
            }
            self.error = error
        }

        isLoading = false
    }

    /// Fetches fresh weather data from API (always hits the network)
    @discardableResult
    private func fetchFreshWeatherData() async throws -> WeatherData {
        let response = try await weatherService.fetchWeatherData()

        // Calculate condition using USD threshold logic
        let condition = calculateCondition(
            feeRate: Double(response.fees.mid),
            percentile: response.historicalPercentile
        )

        let avgFee = Int(response.fees.mid) * vbytesSize
        let formattedFee = try formatFeeAmount(avgFee)

        let data = WeatherData(
            condition: condition,
            currentFee: formattedFee,
            nextBlockFee: Int(response.fees.fast)
        )

        weatherService.cacheData(data)
        weatherData = data
        error = nil

        return data
    }

    /// Calculates fee condition using USD threshold and historical percentiles
    private func calculateCondition(
        feeRate: Double,
        percentile: FeePercentile
    ) -> FeeCondition {
        // Constants for condition calculation
        let usdGoodThreshold = Decimal(1.0) // $1 USD threshold for good condition

        // Check USD threshold first using currency conversion
        if let currencyViewModel,
           let converted = currencyViewModel.convert(sats: UInt64(feeRate), to: "USD")
        {
            if converted.value <= usdGoodThreshold {
                return .good
            }
        }

        // Determine status based on current fee relative to percentiles
        if feeRate <= percentile.lowThreshold {
            return .good
        } else if feeRate >= percentile.highThreshold {
            return .poor
        } else {
            return .average
        }
    }

    /// Formats fee amount using CurrencyViewModel - throws error if conversion fails
    private func formatFeeAmount(_ fee: Int) throws -> String {
        guard let currencyViewModel,
              let converted = currencyViewModel.convert(sats: UInt64(fee))
        else {
            throw AppError(message: "Currency conversion unavailable", debugMessage: "Failed to convert \(fee) satoshis to fiat currency")
        }

        return "\(converted.symbol) \(converted.formatted)"
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
