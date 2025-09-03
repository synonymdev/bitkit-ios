import Foundation
import SwiftUI

@MainActor
class AmountInputViewModel: ObservableObject {
    @Published var amountSats: UInt64 = 0
    @Published var displayText: String = ""
    @Published var errorKey: String?

    // MARK: - Constants

    private let maxAmount: UInt64 = 999_999_999
    private let maxModernBitcoinLength = 10
    private let maxDecimalInputLength = 20
    private let classicBitcoinDecimals = 8
    private let fiatDecimals = 2

    // MARK: - Private Properties

    private var rawInputText: String = ""

    init() {}

    // MARK: - Public Methods

    /// Handles number pad input and updates the amount state
    /// - Parameters:
    ///   - key: The key pressed on the number pad
    ///   - currency: The current currency settings
    func handleNumberPadInput(_ key: String, currency: CurrencyViewModel) {
        let maxLength = getMaxLength(currency: currency)
        let maxDecimals = getMaxDecimals(currency: currency)

        let newText = NumberPadInputHandler.handleInput(
            key: key,
            current: rawInputText,
            maxLength: maxLength,
            maxDecimals: maxDecimals
        )

        // For decimal input (classic Bitcoin and fiat), preserve the text as-is
        // For integer input (modern Bitcoin), format the final amount
        if currency.primaryDisplay == .bitcoin && currency.displayUnit == .modern {
            let newAmount = convertToSats(newText, currency: currency)

            if newAmount <= maxAmount {
                rawInputText = newText
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
            // For decimal input, check limits before updating state
            if !newText.isEmpty {
                let newAmount = convertToSats(newText, currency: currency)
                if newAmount <= maxAmount {
                    // Update both raw input and display text
                    rawInputText = newText
                    // Format with grouping separators but not decimal formatting
                    if currency.primaryDisplay == .fiat {
                        displayText = formatFiatGroupingOnly(newText)
                    } else {
                        displayText = newText
                    }
                    amountSats = newAmount
                    errorKey = nil
                } else {
                    // Block input when limit exceeded
                    Haptics.notify(.warning)
                    errorKey = key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.errorKey = nil
                    }
                }
            } else {
                // If input is empty, set sats to 0
                rawInputText = newText
                amountSats = 0
                displayText = ""
                errorKey = nil
            }
        }
    }

    /// Updates the amount from a given satoshi value
    /// - Parameters:
    ///   - newAmountSats: The new amount in satoshis
    ///   - currency: The current currency settings
    func updateFromSats(_ newAmountSats: UInt64, currency: CurrencyViewModel) {
        amountSats = newAmountSats
        displayText = formatDisplayTextFromAmount(newAmountSats, currency: currency)
        // Update raw input text based on the formatted display
        if currency.primaryDisplay == .fiat {
            rawInputText = displayText.replacingOccurrences(of: ",", with: "")
        } else {
            rawInputText = displayText
        }
    }

    /// Toggles between Bitcoin and Fiat display modes while preserving input
    /// - Parameter currency: The current currency settings
    func togglePrimaryDisplay(currency: CurrencyViewModel) {
        // Store the current raw input before toggling
        let currentRawInput = rawInputText

        currency.togglePrimaryDisplay()

        // Update display text when currency changes
        if amountSats > 0 {
            displayText = formatDisplayTextFromAmount(amountSats, currency: currency)
            // Update raw input text based on the formatted display
            if currency.primaryDisplay == .fiat {
                rawInputText = displayText.replacingOccurrences(of: ",", with: "")
            } else {
                rawInputText = displayText
            }
        } else if !currentRawInput.isEmpty {
            // Convert the raw input from the old currency to the new currency
            if currency.primaryDisplay == .fiat {
                // Converting from Bitcoin to Fiat
                // First convert the Bitcoin input to sats, then to fiat
                let sats = convertBitcoinToSats(currentRawInput, isModern: currency.displayUnit == .modern)
                if let converted = currency.convert(sats: sats) {
                    rawInputText = converted.formatted.replacingOccurrences(of: ",", with: "")
                    displayText = formatFiatGroupingOnly(rawInputText)
                }
            } else {
                // Converting from Fiat to Bitcoin
                // First convert fiat to sats, then format for Bitcoin display
                let cleanFiat = currentRawInput.replacingOccurrences(of: ",", with: "")
                if let fiatValue = Double(cleanFiat), let sats = currency.convert(fiatAmount: fiatValue) {
                    rawInputText = formatBitcoinFromSats(sats, isModern: currency.displayUnit == .modern)
                    displayText = rawInputText
                }
            }
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
        return isModern && isBtc ? maxModernBitcoinLength : maxDecimalInputLength
    }

    func getMaxDecimals(currency: CurrencyViewModel) -> Int {
        let isBtc = currency.primaryDisplay == .bitcoin
        let isModern = currency.displayUnit == .modern
        return isModern && isBtc ? 0 : (isBtc ? classicBitcoinDecimals : fiatDecimals)
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
                        let remainingDecimals = classicBitcoinDecimals - decimalPart.count
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
                    let remainingDecimals = fiatDecimals - decimalPart.count
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

    private func formatFiatGroupingOnly(_ text: String) -> String {
        // Remove any existing grouping separators for parsing
        let cleanText = text.replacingOccurrences(of: ",", with: "")

        // If the text ends with a decimal point, don't format it (preserve the decimal point)
        if text.hasSuffix(".") {
            // Only add grouping separators to the integer part
            let integerPart = String(cleanText.dropLast()) // Remove the decimal point
            if let intValue = Int(integerPart) {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.groupingSeparator = ","
                let formattedInteger = formatter.string(from: NSNumber(value: intValue)) ?? integerPart
                return formattedInteger + "."
            }
            return text
        }

        // If the text contains a decimal point, preserve the decimal structure
        if text.contains(".") {
            let parts = cleanText.split(separator: ".", maxSplits: 1)
            let integerPart = String(parts[0])
            let decimalPart = parts.count > 1 ? String(parts[1]) : ""

            // Format only the integer part with grouping separators
            if let intValue = Int(integerPart) {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.groupingSeparator = ","
                let formattedInteger = formatter.string(from: NSNumber(value: intValue)) ?? integerPart
                return formattedInteger + "." + decimalPart
            }
            return text
        }

        // For integer-only input, add grouping separators
        if let intValue = Int(cleanText) {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            return formatter.string(from: NSNumber(value: intValue)) ?? text
        }

        return text
    }

    private func convertBitcoinToSats(_ text: String, isModern: Bool) -> UInt64 {
        guard !text.isEmpty else { return 0 }

        if isModern {
            // Remove grouping separators (spaces) before parsing
            let cleanText = text.replacingOccurrences(of: " ", with: "")
            return UInt64(cleanText) ?? 0
        } else {
            guard let btcValue = Double(text) else { return 0 }
            return UInt64(btcValue * 100_000_000)
        }
    }

    private func formatBitcoinFromSats(_ sats: UInt64, isModern: Bool) -> String {
        if isModern {
            // Format with grouping separators for modern Bitcoin
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = " "
            return formatter.string(from: NSNumber(value: sats)) ?? String(sats)
        } else {
            // Classic Bitcoin - convert to BTC with proper formatting
            let btcValue = Double(sats) / 100_000_000.0
            return String(format: "%.8f", btcValue).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
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
            // Remove grouping separators (commas) before parsing fiat
            let cleanText = text.replacingOccurrences(of: ",", with: "")
            guard let fiatValue = Double(cleanText) else { return 0 }
            return currency.convert(fiatAmount: fiatValue) ?? 0
        }
    }
}

// MARK: - NumberPad Input Handler

/// Handles raw number pad input logic for different input types
enum NumberPadInputHandler {
    static func handleInput(key: String, current: String, maxLength: Int, maxDecimals: Int) -> String {
        // For integer-only input (maxDecimals = 0), treat as simple number input
        if maxDecimals == 0 {
            return handleIntegerInput(key: key, current: current, maxLength: maxLength)
        }

        // For decimal input, use the existing logic
        return handleDecimalInput(key: key, current: current, maxLength: maxLength, maxDecimals: maxDecimals)
    }

    private static func handleIntegerInput(key: String, current: String, maxLength: Int) -> String {
        if key == "delete" {
            return String(current.dropLast())
        }

        if current == "0" {
            // no leading zeros
            if key != "delete" {
                return key
            }
        }

        // limit to maxLength
        if current.count == maxLength {
            return current
        }

        return "\(current)\(key)"
    }

    private static func handleDecimalInput(key: String, current: String, maxLength: Int, maxDecimals: Int) -> String {
        let parts = current.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let decimalPart = parts.count > 1 ? String(parts[1]) : ""

        if key == "delete" {
            if current == "0." {
                return ""
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
