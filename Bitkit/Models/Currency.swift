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

    var isSymbolSuffix: Bool {
        isSuffixSymbolCurrency(currency)
    }

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
        formatFiatWithSymbol(formatted: formatted, symbol: symbol, currencyCode: currency, withSpace: withSpace)
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

/// Formats a fiat amount the way the in-app currency display does: 2 fraction digits,
/// "." decimal / "," grouping. Single source of truth shared by the app and the widget
/// extension so both produce identical strings.
func formatFiatAmount(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale.current
    formatter.decimalSeparator = "."
    formatter.groupingSeparator = ","
    return formatter.string(from: value as NSDecimalNumber) ?? "0.00"
}

/// Composes a formatted number with its currency symbol, honoring suffix-symbol currencies.
/// Using the backend-provided symbol here (rather than a locale-derived one) keeps USD as
/// "$" instead of the disambiguated "US$".
func formatFiatWithSymbol(formatted: String, symbol: String, currencyCode: String, withSpace: Bool = false) -> String {
    let separator = withSpace ? " " : ""
    return isSuffixSymbolCurrency(currencyCode)
        ? "\(formatted)\(separator)\(symbol)"
        : "\(symbol)\(separator)\(formatted)"
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
