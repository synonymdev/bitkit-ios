import Foundation
import SwiftUI

@MainActor
class AmountInputViewModel: ObservableObject {
    @Published var amountSats: UInt64 = 0
    @Published var displayText: String = ""
    @Published var errorKey: String?

    private let maxAmount: UInt64 = 999_999_999

    init() {}

    // MARK: - Public Methods

    func handleNumberPadInput(_ key: String, currency: CurrencyViewModel) {
        let numberPadType = getNumberPadType(currency: currency)
        let maxLength = getMaxLength(currency: currency)
        let maxDecimals = getMaxDecimals(currency: currency)

        let newText = NumberPadInputHandler.handleInput(
            key: key,
            current: displayText,
            maxLength: maxLength,
            maxDecimals: maxDecimals
        )

        // For decimal input (classic Bitcoin and fiat), preserve the text as-is
        // For integer input (modern Bitcoin), format the final amount
        if currency.primaryDisplay == .bitcoin && currency.displayUnit == .modern {
            let newAmount = convertToSats(newText, currency: currency)

            if newAmount <= maxAmount {
                displayText = formatDisplayTextFromAmount(newAmount, currency: currency)
                amountSats = newAmount
                errorKey = nil
            } else {
                Haptics.notify(.warning)
                errorKey = key
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.errorKey = nil
                }
            }
        } else {
            // For decimal input, preserve the text and update sats when possible
            displayText = newText

            // Only update sats if we have a complete number
            if !newText.isEmpty && !newText.hasSuffix(".") {
                let newAmount = convertToSats(newText, currency: currency)
                if newAmount <= maxAmount {
                    amountSats = newAmount
                    errorKey = nil
                } else {
                    Haptics.notify(.warning)
                    errorKey = key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.errorKey = nil
                    }
                }
            } else {
                // For incomplete input (like "1."), keep current sats
                errorKey = nil
            }
        }
    }

    func updateFromSats(_ newAmountSats: UInt64, currency: CurrencyViewModel) {
        amountSats = newAmountSats
        displayText = formatDisplayTextFromAmount(newAmountSats, currency: currency)
    }

    func togglePrimaryDisplay(currency: CurrencyViewModel) {
        currency.togglePrimaryDisplay()
        // Update display text when currency changes
        if amountSats > 0 {
            displayText = formatDisplayTextFromAmount(amountSats, currency: currency)
        }
    }

    // MARK: - Helper Methods

    func getNumberPadType(currency: CurrencyViewModel) -> NumberPadType {
        let isBtc = currency.primaryDisplay == .bitcoin
        let isModern = currency.displayUnit == .modern
        return isModern && isBtc ? .integer : .decimal
    }

    func getMaxLength(currency: CurrencyViewModel) -> Int {
        let isBtc = currency.primaryDisplay == .bitcoin
        let isModern = currency.displayUnit == .modern
        return isModern && isBtc ? 10 : 20
    }

    func getMaxDecimals(currency: CurrencyViewModel) -> Int {
        let isBtc = currency.primaryDisplay == .bitcoin
        let isClassic = currency.displayUnit == .classic
        return isClassic && isBtc ? 8 : 2
    }

    func getPlaceholder(currency: CurrencyViewModel) -> String {
        if displayText.isEmpty {
            // When nothing is typed, show simple placeholder
            if currency.primaryDisplay == .bitcoin {
                return currency.displayUnit == .modern ? "0" : "0.00000000"
            } else {
                // TODO: some currencies have no decimals
                return "0.00"
            }
        } else {
            // When typing, show remaining digits/decimals
            if currency.primaryDisplay == .bitcoin {
                if currency.displayUnit == .modern {
                    // Modern: no additional placeholder digits
                    return ""
                } else {
                    // Classic: show decimal places
                    if displayText.contains(".") {
                        let parts = displayText.split(separator: ".", maxSplits: 1)
                        let decimalPart = parts.count > 1 ? String(parts[1]) : ""
                        let remainingDecimals = 8 - decimalPart.count
                        return remainingDecimals > 0 ? String(repeating: "0", count: remainingDecimals) : ""
                    } else {
                        return ".00000000"
                    }
                }
            } else {
                // Fiat: show decimal places
                if displayText.contains(".") {
                    let parts = displayText.split(separator: ".", maxSplits: 1)
                    let decimalPart = parts.count > 1 ? String(parts[1]) : ""
                    let remainingDecimals = 2 - decimalPart.count
                    return remainingDecimals > 0 ? String(repeating: "0", count: remainingDecimals) : ""
                } else {
                    return ".00"
                }
            }
        }
    }

    // MARK: - Private Methods

    private func formatDisplayTextFromAmount(_ amountSats: UInt64, currency: CurrencyViewModel) -> String {
        if amountSats == 0 {
            return ""
        }

        if currency.primaryDisplay == .bitcoin {
            if currency.displayUnit == .modern {
                // Format with grouping separators for modern Bitcoin
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.groupingSeparator = " "
                return formatter.string(from: NSNumber(value: amountSats)) ?? String(amountSats)
            } else {
                // Classic Bitcoin - convert to BTC with proper formatting
                let btcValue = Double(amountSats) / 100_000_000.0
                return String(format: "%.8f", btcValue).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            }
        } else {
            // Fiat - convert using currency service
            if let converted = currency.convert(sats: amountSats) {
                return converted.formatted
            }
            return ""
        }
    }

    private func convertToSats(_ text: String, currency: CurrencyViewModel) -> UInt64 {
        guard !text.isEmpty else { return 0 }

        if currency.primaryDisplay == .bitcoin {
            if currency.displayUnit == .modern {
                // Remove grouping separators (spaces) before parsing
                let cleanText = text.replacingOccurrences(of: " ", with: "")
                return UInt64(cleanText) ?? 0
            } else {
                guard let btcValue = Double(text) else { return 0 }
                return UInt64(btcValue * 100_000_000)
            }
        } else {
            guard let fiatValue = Double(text) else { return 0 }
            return currency.convert(fiatAmount: fiatValue) ?? 0
        }
    }
}

// MARK: - NumberPad Input Handler

enum NumberPadInputHandler {
    static func handleInput(key: String, current: String, maxLength: Int, maxDecimals: Int) -> String {
        let parts = current.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = String(parts.first ?? "")
        let decimalPart = parts.count > 1 ? String(parts[1]) : ""

        if key == "delete" {
            if current.hasSuffix("0.") {
                return ""
            }

            if decimalPart.count >= maxDecimals {
                return "\(integerPart).\(String(decimalPart.prefix(maxDecimals - 1)))"
            }

            return String(current.dropLast())
        }

        if current == "0" {
            // no leading zeros
            if key != "." && key != "delete" {
                return key
            }
        }

        // limit to maxLength
        if current.count == maxLength {
            return current
        }

        // limit to maxDecimals
        if decimalPart.count >= maxDecimals {
            return current
        }

        if key == "." {
            // no multiple decimal symbol
            if current.contains(".") {
                return current
            }

            // add leading zero
            if current.isEmpty {
                return "0\(key)"
            }
        }

        return "\(current)\(key)"
    }
}
