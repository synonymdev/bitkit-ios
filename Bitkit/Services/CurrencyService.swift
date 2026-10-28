import Foundation

class CurrencyService {
    static let shared = CurrencyService()
    private let maxRetries = 3

    private let cache = UserDefaults.standard
    private let cacheKey = "cached_fx_rates"

    /// Internal rather than private so tests can substitute a service that does not reach the
    /// network. `CurrencyViewModel.refresh()` writes the rate cache and mirrors the display
    /// currency into the app group on success, from a task that can outlive a test.
    init() {}

    func fetchLatestRates() async throws -> [FxRate] {
        var lastError: Error?

        for attempt in 0 ..< maxRetries {
            do {
                let rates = try await ServiceQueue.background(.forex) {
                    guard let url = URL(string: Env.btcRatesServer) else {
                        throw URLError(.badURL)
                    }

                    let (data, _) = try await URLSession.shared.data(from: url)
                    let response = try JSONDecoder().decode(FxRateResponse.self, from: data)
                    return response.tickers
                }

                // Cache the successful response
                if let encoded = try? JSONEncoder().encode(rates) {
                    cache.set(encoded, forKey: cacheKey)
                }

                return rates
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    func loadCachedRates() -> [FxRate]? {
        guard let data = cache.data(forKey: cacheKey),
              let rates = try? JSONDecoder().decode([FxRate].self, from: data)
        else {
            return nil
        }
        return rates
    }
}

// MARK: UI Helpers (Published via CurrencyViewModel)

extension CurrencyService {
    func convert(sats: UInt64, rate: FxRate) -> ConvertedAmount? {
        let btcAmount = Decimal(sats) / 100_000_000
        let value = btcAmount * rate.rate

        return ConvertedAmount(
            value: value,
            formatted: formatFiatAmount(value),
            symbol: rate.currencySymbol,
            currency: rate.quote,
            flag: rate.currencyFlag,
            sats: sats
        )
    }

    func getAvailableCurrencies(from rates: [FxRate]) -> [String] {
        rates.map(\.quote)
    }

    func getCurrentRate(for currency: String, from rates: [FxRate]) -> FxRate? {
        rates.first { $0.quote == currency }
    }
}
