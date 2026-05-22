import Foundation
import SwiftUI

/// Weather widget view model for handling fee weather data
@MainActor
class WeatherViewModel: ObservableObject {
    static let shared = WeatherViewModel()

    @Published var weatherData: CachedWeather?
    @Published var isLoading: Bool = false
    @Published var error: Error?

    private let weatherService = WeatherService.shared
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes
    private var hasStartedUpdates = false

    private let vbytesSize = 140 // average native segwit transaction size

    /// Currency conversion dependency - will be set by views that need currency conversion
    weak var currencyViewModel: CurrencyViewModel?

    /// Private initializer for the singleton instance
    private init() {
        // No automatic loading - widgets will control when to load
    }

    /// Sets the currency view model for currency conversion
    func setCurrencyViewModel(_ currencyViewModel: CurrencyViewModel) {
        self.currencyViewModel = currencyViewModel
    }

    func handleCurrencyChange() {
        guard let cached = weatherData ?? weatherService.getCachedData() else { return }

        guard let reformatted = try? formatFeeAmount(cached.currentFeeSats) else {
            WeatherWidgetCache.invalidateFreshness()
            return
        }

        let updated = CachedWeather(
            condition: cached.condition,
            currentFeeFiat: reformatted,
            currentFeeSats: cached.currentFeeSats,
            nextBlockFee: cached.nextBlockFee
        )
        weatherData = updated
        weatherService.cacheData(updated)
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
    private func fetchFreshWeatherData() async throws -> CachedWeather {
        let response = try await weatherService.fetchWeatherData()

        let midSatsPerVbyte = Double(response.fees.mid)
        let medianFeeSats = Int(response.fees.mid) * vbytesSize

        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: midSatsPerVbyte,
            totalSats: medianFeeSats,
            usdPerBtc: usdPerBtcRate(),
            percentile: response.historicalPercentile
        )

        let formattedFiat = try formatFeeAmount(medianFeeSats)

        let data = CachedWeather(
            condition: condition,
            currentFeeFiat: formattedFiat,
            currentFeeSats: medianFeeSats,
            nextBlockFee: Int(response.fees.fast)
        )

        weatherService.cacheData(data)
        WeatherWidgetCache.savePercentile(response.historicalPercentile)
        WeatherHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
        weatherData = data
        error = nil

        return data
    }

    /// Derives BTC/USD spot price from the injected `CurrencyViewModel` by converting 1 BTC to
    /// USD. Returns `nil` if conversion is unavailable so callers can fall back to the
    /// percentile-only branch in `FeeCondition.evaluate`.
    private func usdPerBtcRate() -> Double? {
        guard let currencyViewModel,
              let converted = currencyViewModel.convert(sats: 100_000_000, to: "USD")
        else {
            return nil
        }
        return NSDecimalNumber(decimal: converted.value).doubleValue
    }

    /// Formats fee amount using CurrencyViewModel - throws error if conversion fails
    private func formatFeeAmount(_ fee: Int) throws -> String {
        guard let currencyViewModel,
              let converted = currencyViewModel.convert(sats: UInt64(fee))
        else {
            throw AppError(message: "Currency conversion unavailable", debugMessage: "Failed to convert \(fee) satoshis to fiat currency")
        }

        return converted.formattedWithSymbol(withSpace: true)
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
