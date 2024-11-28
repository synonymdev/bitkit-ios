import Foundation

struct ForexRateResponse: Codable {
    let tickers: [ForexRate]
}

struct ForexRate: Codable, Equatable {
    let symbol: String
    let lastPrice: String
    let base: String
    let baseName: String
    let quote: String
    let quoteName: String
    let currencySymbol: String
    let currencyFlag: String
    let lastUpdatedAt: TimeInterval
    
    var rate: Decimal {
        return Decimal(string: lastPrice) ?? 0
    }
    
    var timestamp: Date {
        return Date(timeIntervalSince1970: lastUpdatedAt / 1000)
    }
}

struct ConvertedAmount {
    let value: Decimal
    let formatted: String
    let symbol: String
    let currency: String
    let flag: String
} 