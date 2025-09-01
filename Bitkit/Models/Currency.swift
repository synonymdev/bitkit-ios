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
    case modern
    case classic

    // TODO: get translations here
    var display: String {
        switch self {
        case .modern:
            return "Modern"
        case .classic:
            return "Classic"
        }
    }
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
        btcValue = Decimal(sats) / 100_000_000
    }

    struct BitcoinDisplayComponents {
        let symbol: String
        let value: String
    }

    func bitcoinDisplay(unit: BitcoinDisplayUnit) -> BitcoinDisplayComponents {
        switch unit {
        case .modern:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = " "
            let formattedValue = formatter.string(from: NSNumber(value: sats)) ?? String(sats)
            return BitcoinDisplayComponents(symbol: "₿", value: formattedValue)

        case .classic:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 8
            formatter.maximumFractionDigits = 8
            formatter.decimalSeparator = "."
            let formattedValue = formatter.string(from: btcValue as NSDecimalNumber) ?? "0"
            return BitcoinDisplayComponents(symbol: "₿", value: formattedValue)
        }
    }
}
