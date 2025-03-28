import Foundation

class CurrencyService {
    static let shared = CurrencyService()
    private let maxRetries = 3

    private let cache = UserDefaults.standard
    private let cacheKey = "cached_fx_rates"

    private init() {}

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

    func convertFiatToSats(fiatValue: Decimal, rate: FxRate) -> UInt64 {
        let btcAmount = fiatValue / rate.rate
        let satsDecimal = btcAmount * 100_000_000

        // Use NSDecimalNumber for rounding
        let decimalNumber = NSDecimalNumber(decimal: satsDecimal)
        let roundingBehavior = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        let roundedNumber = decimalNumber.rounding(accordingToBehavior: roundingBehavior)
        let result = roundedNumber.uint64Value

        return result
    }
}

// MARK: UI Helpers (Published via CurrencyViewModel)

extension CurrencyService {
    func convert(sats: UInt64, rate: FxRate) -> ConvertedAmount? {
        let btcAmount = Decimal(sats) / 100_000_000
        let value = btcAmount * rate.rate

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale.current

        guard let formatted = formatter.string(from: value as NSDecimalNumber) else {
            return nil
        }

        return ConvertedAmount(
            value: value,
            formatted: formatted,
            symbol: rate.currencySymbol,
            currency: rate.quote,
            flag: rate.currencyFlag,
            sats: sats
        )
    }

    func getAvailableCurrencies(from rates: [FxRate]) -> [String] {
        rates.map { $0.quote }
    }

    func getCurrentRate(for currency: String, from rates: [FxRate]) -> FxRate? {
        rates.first { $0.quote == currency }
    }
}
