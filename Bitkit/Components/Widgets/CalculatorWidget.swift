import SwiftUI

private let MAX_BITCOIN: UInt64 = 2_100_000_000_000_000

/// A reusable input row component for currency conversion
struct CurrencyInputRow: View {
    let icon: CircularIcon
    let placeholder: String = "0"
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let label: String
    let isFocused: Bool
    let onTextChange: (String) -> Void

    @EnvironmentObject private var currency: CurrencyViewModel

    var body: some View {
        HStack(spacing: 0) {
            icon

            SwiftUI.TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .font(.custom(Fonts.semiBold, size: 15))
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.leading, 8)
                .onChange(of: text, perform: onTextChange)

            CaptionBText(label, textColor: .textSecondary)
                .textCase(.uppercase)
        }
        .padding(16)
        .background(Color.white06)
        .cornerRadius(8)
    }
}

/// A widget that provides Bitcoin to fiat currency conversion
struct CalculatorWidget: View {
    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// Currency view model for currency conversion
    @EnvironmentObject private var currency: CurrencyViewModel

    /// Bitcoin amount state (stored as string to preserve user input)
    @State private var bitcoinAmount: String = "10000"

    /// Fiat amount state (stored as string to preserve user input)
    @State private var fiatAmount: String = ""

    /// Focus state for text fields
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField {
        case bitcoin, fiat
    }

    /// Initialize the widget
    init(
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .calculator,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            VStack(spacing: 16) {
                CurrencyInputRow(
                    icon: CircularIcon(
                        icon: "b-unit",
                        iconColor: .brandAccent,
                        backgroundColor: .white10,
                        size: 32
                    ),
                    text: $bitcoinAmount,
                    keyboardType: .numberPad,
                    label: "Bitcoin",
                    isFocused: focusedField == .bitcoin,
                    onTextChange: { newValue in
                        // Validate and filter input in real-time
                        let validatedValue = validateBitcoinInput(newValue)
                        if validatedValue != newValue {
                            bitcoinAmount = validatedValue
                        }

                        if focusedField == .bitcoin {
                            updateFiatAmount(from: validatedValue)
                        }
                    }
                )
                .focused($focusedField, equals: .bitcoin)

                CurrencyInputRow(
                    icon: CircularIcon(
                        icon: BodyMSBText(currency.symbol, textColor: .brandAccent),
                        backgroundColor: .white10,
                        size: 32
                    ),
                    text: $fiatAmount,
                    keyboardType: .decimalPad,
                    label: currency.selectedCurrency,
                    isFocused: focusedField == .fiat,
                    onTextChange: { newValue in
                        // Validate and filter input in real-time
                        let validatedValue = validateFiatInput(newValue)
                        if validatedValue != newValue {
                            fiatAmount = validatedValue
                        }

                        if focusedField == .fiat {
                            updateBitcoinAmount(from: validatedValue)
                        }
                    }
                )
                .focused($focusedField, equals: .fiat)
                .onSubmit {
                    // Format with trailing zeros when user finishes editing
                    fiatAmount = formatFiatInput(fiatAmount)
                }
                .onChange(of: focusedField) { newFocus in
                    // Format fiat amount when focus leaves the field
                    if newFocus != .fiat && !fiatAmount.isEmpty {
                        fiatAmount = formatFiatInput(fiatAmount)
                    }
                }
            }
        }
        .onAppear {
            // Initialize fiat amount on first load
            if fiatAmount.isEmpty {
                updateFiatAmount(from: bitcoinAmount)
            }
        }
        .onChange(
            of: currency.selectedCurrency,
            perform: { _ in
                // Update fiat amount when currency changes
                updateFiatAmount(from: bitcoinAmount)
            }
        )
    }

    /// Updates fiat amount based on bitcoin input
    private func updateFiatAmount(from bitcoin: String) {
        // Sanitize bitcoin input
        let sanitizedBitcoin = sanitizeBitcoinInput(bitcoin)

        guard let amount = UInt64(sanitizedBitcoin), amount > 0 else {
            fiatAmount = ""
            return
        }

        // Cap the amount at maximum bitcoin
        let cappedAmount = min(amount, MAX_BITCOIN)

        // Convert to fiat
        if let converted = currency.convert(sats: cappedAmount) {
            fiatAmount = formatFiatAmount(converted.value)
        } else {
            fiatAmount = ""
        }

        // Update bitcoin amount if it was capped or needs formatting
        let formattedBitcoin = formatNumberWithSeparators(String(cappedAmount))
        if formattedBitcoin != bitcoin {
            bitcoinAmount = formattedBitcoin
        }
    }

    /// Updates bitcoin amount based on fiat input
    private func updateBitcoinAmount(from fiat: String) {
        // Sanitize fiat input
        let sanitizedFiat = sanitizeFiatInput(fiat)

        guard let amount = Double(sanitizedFiat), amount > 0 else {
            bitcoinAmount = ""
            return
        }

        // Convert to sats
        if let convertedSats = currency.convert(fiatAmount: amount) {
            // Cap the amount at maximum bitcoin
            let cappedSats = min(convertedSats, MAX_BITCOIN)

            bitcoinAmount = formatNumberWithSeparators(String(cappedSats))

            // Update fiat amount if bitcoin was capped
            if cappedSats != convertedSats {
                if let converted = currency.convert(sats: cappedSats) {
                    fiatAmount = formatFiatAmount(converted.value)
                }
            }
        } else {
            bitcoinAmount = ""
        }
    }

    /// Sanitizes bitcoin input by removing non-numeric characters and leading zeros
    private func sanitizeBitcoinInput(_ input: String) -> String {
        let cleaned = input.replacingOccurrences(of: " ", with: "")
        return cleaned.replacingOccurrences(of: "^0+(?=\\d)", with: "", options: .regularExpression)
    }

    /// Sanitizes fiat input by handling decimal points and limiting decimal places
    private func sanitizeFiatInput(_ input: String) -> String {
        let processed =
            input
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: " ", with: "")

        let components = processed.components(separatedBy: ".")
        if components.count > 2 {
            // Only keep first decimal point
            return components[0] + "." + components[1]
        }

        if components.count == 2 {
            let integer = components[0].replacingOccurrences(of: "^0+(?=\\d)", with: "", options: .regularExpression)
            let decimal = String(components[1].prefix(2)) // Limit to 2 decimal places
            return (integer.isEmpty ? "0" : integer) + "." + decimal
        }

        return processed.replacingOccurrences(of: "^0+(?=\\d)", with: "", options: .regularExpression)
    }

    /// Formats a number with space separators for thousands
    private func formatNumberWithSeparators(_ value: String) -> String {
        let endsWithDecimal = value.hasSuffix(".")
        let cleanNumber = value.replacingOccurrences(of: "[^\\d.]", with: "", options: .regularExpression)
        let components = cleanNumber.components(separatedBy: ".")

        let integer = components[0]
        let formattedInteger = integer.replacingOccurrences(of: "\\B(?=(\\d{3})+(?!\\d))", with: " ", options: .regularExpression)

        if components.count > 1 {
            return formattedInteger + "." + components[1]
        }

        return endsWithDecimal ? formattedInteger + "." : formattedInteger
    }

    /// Formats fiat amount to string with proper decimal handling
    private func formatFiatAmount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2 // Always show 2 decimal places
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = " "

        return formatter.string(from: value as NSDecimalNumber) ?? "0.00"
    }

    /// Formats user input to always show 2 decimal places when it contains a decimal
    private func formatFiatInput(_ input: String) -> String {
        // Don't format if empty or just a dot
        if input.isEmpty || input == "." {
            return input
        }

        // If it contains a decimal point, ensure 2 decimal places
        if input.contains(".") {
            let components = input.components(separatedBy: ".")
            if components.count == 2 {
                let integer = components[0]
                let decimal = components[1]

                // Pad decimal part to 2 digits
                let paddedDecimal = decimal.padding(toLength: 2, withPad: "0", startingAt: 0)
                return integer + "." + paddedDecimal
            }
        }

        return input
    }

    /// Validates fiat input to ensure only numbers and up to 2 decimal places
    private func validateFiatInput(_ input: String) -> String {
        // Convert comma to dot and remove spaces
        let processed =
            input
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: " ", with: "")

        // Check if input matches valid pattern: digits, optional dot, up to 2 decimal digits
        let validPattern = "^\\d*\\.?\\d{0,2}$"

        // Allow empty string, single dot, or "0."
        if processed.isEmpty || processed == "." || processed == "0." {
            return processed
        }

        // Test against the pattern
        if processed.range(of: validPattern, options: .regularExpression) != nil {
            // Remove leading zeros except before decimal or if it's just "0"
            if processed.hasPrefix("0") && processed.count > 1 && !processed.hasPrefix("0.") {
                let withoutLeadingZeros = processed.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
                return withoutLeadingZeros.isEmpty ? "0" : withoutLeadingZeros
            }
            return processed
        }

        // If invalid, return the previous valid value by removing the last character
        return String(processed.dropLast())
    }

    /// Validates bitcoin input to ensure only numbers and spaces
    private func validateBitcoinInput(_ input: String) -> String {
        // Allow empty input
        if input.isEmpty {
            return input
        }

        // Only allow digits and spaces
        let validPattern = "^[\\d\\s]+$"

        if input.range(of: validPattern, options: .regularExpression) != nil {
            return input
        }

        // If invalid, return the previous valid value by removing the last character
        return String(input.dropLast())
    }
}

#Preview("Default") {
    CalculatorWidget()
        .padding()
        .background(Color.black)
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
}

#Preview("Editing") {
    CalculatorWidget(isEditing: true)
        .padding()
        .background(Color.black)
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
}
