import Foundation

class ForexService {
    static let shared = ForexService()
    
    private init() {}
    
    func fetchLatestRates() async throws -> [ForexRate] {
        try await ServiceQueue.background(.forex) {
            guard let url = URL(string: Env.blocktankFxRateServer) else {
                throw URLError(.badURL)
            }
            
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ForexRateResponse.self, from: data)
            return response.tickers
        }
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