import Foundation

enum CurrencyFormatter {
    static func format(_ amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2

        return formatter.string(from: amount as NSDecimalNumber) ?? ""
    }

    /// Format satoshis with space as grouping separator (e.g., 10000 -> "10 000")
    static func formatSats(_ sats: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: sats)) ?? String(sats)
    }
}
