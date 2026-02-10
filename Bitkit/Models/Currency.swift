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

    var isSymbolSuffix: Bool { isSuffixSymbolCurrency(currency) }

    init(value: Decimal, formatted: String, symbol: String, currency: String, flag: String, sats: UInt64) {
        self.value = value
        self.formatted = formatted
        self.symbol = symbol
        self.currency = currency
        self.flag = flag
        self.sats = sats
        btcValue = Decimal(sats) / 100_000_000
    }

    func formattedWithSymbol(withSpace: Bool = false) -> String {
        let separator = withSpace ? " " : ""
        return isSymbolSuffix ? "\(formatted)\(separator)\(symbol)" : "\(symbol)\(separator)\(formatted)"
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

func isSuffixSymbolCurrency(_ currencyCode: String) -> Bool {
    suffixSymbolCurrencies.contains(currencyCode)
}

private let suffixSymbolCurrencies: Set<String> = [
    "BGN", // Bulgarian Lev (10,00 лв)
    "CHF", // Swiss Franc (10.00 CHF)
    "CZK", // Czech Koruna (10,00 Kč)
    "DKK", // Danish Krone (10,00 kr)
    "HRK", // Croatian Kuna (10,00 kn)
    "HUF", // Hungarian Forint (10 000 Ft)
    "ISK", // Icelandic Króna (10.000 kr)
    "NOK", // Norwegian Krone (10,00 kr)
    "PLN", // Polish Złoty (0,35 zł)
    "RON", // Romanian Leu (10,00 lei)
    "RUB", // Russian Ruble (10,00 ₽)
    "SEK", // Swedish Krona (10,00 kr)
    "TRY", // Turkish Lira (10,00 ₺)
]
