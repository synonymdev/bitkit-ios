import Foundation

struct FxRateResponse: Codable {
    let tickers: [FxRate]
}

struct FxRate: Codable, Equatable {
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

enum BitcoinDisplayUnit: String, CaseIterable {
    case modern = "Modern" // Display in sats
    case classic = "Classic" // Display in BTC
}

struct ConvertedAmount {
    let value: Decimal
    let formatted: String
    let symbol: String
    let currency: String
    let flag: String

    // Bitcoin values
    let sats: UInt64
    let btcValue: Decimal

    init(value: Decimal, formatted: String, symbol: String, currency: String, flag: String, sats: UInt64) {
        self.value = value
        self.formatted = formatted
        self.symbol = symbol
        self.currency = currency
        self.flag = flag
        self.sats = sats
        self.btcValue = Decimal(sats) / 100_000_000
    }

    func bitcoinDisplay(unit: BitcoinDisplayUnit) -> String {
        switch unit {
        case .modern:
            return "\(sats) sats"
        case .classic:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 8
            formatter.maximumFractionDigits = 8
            return "\(formatter.string(from: btcValue as NSDecimalNumber) ?? "0") BTC"
        }
    }
}
