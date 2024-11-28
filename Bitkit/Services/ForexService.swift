import Foundation

class ForexService {
    static let shared = ForexService()
    private let maxRetries = 3
    
    private init() {}
    
    func fetchLatestRates() async throws -> [ForexRate] {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await ServiceQueue.background(.forex) {
                    guard let url = URL(string: Env.blocktankFxRateServer) else {
                        throw URLError(.badURL)
                    }
                    
                    let (data, _) = try await URLSession.shared.data(from: url)
                    let response = try JSONDecoder().decode(ForexRateResponse.self, from: data)
                    return response.tickers
                }
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    // Wait a bit before retrying, with exponential backoff
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
        
        throw lastError ?? URLError(.unknown)
    }
}

// MARK: UI Helpers (Published via ForexViewModel)

extension ForexService {
    func convert(sats: UInt64, rate: ForexRate) -> ConvertedAmount? {
        let btcAmount = Decimal(sats) / 100_000_000
        let value = btcAmount * rate.rate
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rate.quote
        formatter.locale = Locale.current
        
        guard let formatted = formatter.string(from: value as NSDecimalNumber) else {
            return nil
        }
        
        return ConvertedAmount(
            value: value,
            formatted: formatted,
            symbol: rate.currencySymbol,
            currency: rate.quote,
            flag: rate.currencyFlag
        )
    }
    
    func getAvailableCurrencies(from rates: [ForexRate]) -> [String] {
        rates.map { $0.quote }
    }
    
    func getCurrentRate(for currency: String, from rates: [ForexRate]) -> ForexRate? {
        rates.first { $0.quote == currency }
    }
} 