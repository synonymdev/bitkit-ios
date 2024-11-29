import Foundation

struct CurrencyFormatter {
    static func format(_ amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        
        return formatter.string(from: amount as NSDecimalNumber) ?? ""
    }
} 