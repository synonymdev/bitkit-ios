import Foundation

struct CalculatorWidgetValues: Codable, Equatable {
    var bitcoinValue: String
    var fiatValue: String
    var displayUnit: BitcoinDisplayUnit
    var currencySymbol: String
    var selectedCurrency: String

    init(
        bitcoinValue: String = "10000",
        fiatValue: String = "",
        displayUnit: BitcoinDisplayUnit = .modern,
        currencySymbol: String = "$",
        selectedCurrency: String = "USD"
    ) {
        self.bitcoinValue = bitcoinValue
        self.fiatValue = fiatValue
        self.displayUnit = displayUnit
        self.currencySymbol = currencySymbol
        self.selectedCurrency = selectedCurrency
    }

    var shouldRefreshBitcoinFromFiat: Bool {
        bitcoinValue.isEmpty && !fiatValue.isEmpty
    }

    func refreshSource(activeInput: CalculatorMoneyType?) -> CalculatorMoneyType? {
        if activeInput == .fiat, fiatValue.isEmpty { return nil }
        if let activeInput { return activeInput }
        return shouldRefreshBitcoinFromFiat ? .fiat : .bitcoin
    }
}

enum CalculatorMoneyType: Equatable {
    case bitcoin
    case fiat
}

enum CalculatorWidgetFormatter {
    static let fiatDecimalPlaces = 2
    static let classicBitcoinDecimalPlaces = 8
    static let maxBitcoinSats: UInt64 = 2_100_000_000_000_000

    private static let groupSize = 3
    private static let commaSeparator: Character = ","
    private static let periodSeparator: Character = "."
    private static let satsGroupingSeparator: Character = " "
    private static let fiatGroupingSeparator: Character = ","
    private static let displayDecimalSeparator: Character = "."
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func displaySymbol(_ symbol: String) -> String {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 ? String(trimmed.prefix(1)) : trimmed
    }

    static func decimalSeparator(locale: Locale = .current) -> String {
        DecimalFormatSymbols.decimalSeparator(locale: locale)
    }

    static func numberPadDecimalSeparator() -> String {
        String(displayDecimalSeparator)
    }

    static func formatBitcoinValue(_ rawValue: String, displayUnit: BitcoinDisplayUnit, locale: Locale = .current) -> String {
        if rawValue.isEmpty { return "" }

        switch displayUnit {
        case .modern:
            return formatGroupedInteger(
                value: rawValue.filter(\.isNumber),
                groupingSeparator: satsGroupingSeparator
            )
        case .classic:
            return formatGroupedDecimal(
                value: sanitizeDecimalInput(raw: rawValue, locale: locale, maxDecimalPlaces: classicBitcoinDecimalPlaces),
                groupingSeparator: satsGroupingSeparator,
                decimalSeparator: displayDecimalSeparator
            )
        }
    }

    static func formatBitcoinPlaceholder(_ rawValue: String, displayUnit: BitcoinDisplayUnit, locale: Locale = .current) -> String {
        guard displayUnit == .classic else { return "" }

        let normalized = sanitizeDecimalInput(raw: rawValue, locale: locale, maxDecimalPlaces: classicBitcoinDecimalPlaces)
        let zeroes = String(repeating: "0", count: classicBitcoinDecimalPlaces)

        guard normalized.contains(periodSeparator) else {
            return String(displayDecimalSeparator) + zeroes
        }

        let decimalLength = normalized.split(separator: periodSeparator, maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let remainingDecimals = classicBitcoinDecimalPlaces - decimalLength
        return remainingDecimals > 0 ? String(repeating: "0", count: remainingDecimals) : ""
    }

    static func formatFiatValue(_ rawValue: String, locale: Locale = .current) -> String {
        if rawValue.isEmpty { return "" }

        let normalized = sanitizeDecimalInput(
            raw: normalizeDecimalInput(rawValue, locale: locale, maxDecimalPlaces: fiatDecimalPlaces),
            locale: locale,
            maxDecimalPlaces: fiatDecimalPlaces
        )

        return formatGroupedDecimal(
            value: normalized,
            groupingSeparator: fiatGroupingSeparator,
            decimalSeparator: displayDecimalSeparator
        )
    }

    static func formatFiatPlaceholder(_ rawValue: String, locale: Locale = .current) -> String {
        if rawValue.isEmpty { return "" }

        let normalized = sanitizeDecimalInput(
            raw: normalizeDecimalInput(rawValue, locale: locale, maxDecimalPlaces: fiatDecimalPlaces),
            locale: locale,
            maxDecimalPlaces: fiatDecimalPlaces
        )

        guard normalized.contains(periodSeparator) else { return "" }

        let decimalLength = normalized.split(separator: periodSeparator, maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let remainingDecimals = fiatDecimalPlaces - decimalLength
        return remainingDecimals > 0 ? String(repeating: "0", count: remainingDecimals) : ""
    }

    static func applyNumberPadInput(
        rawValue: String,
        key: String,
        maxDecimalPlaces: Int?,
        locale: Locale = .current
    ) -> String {
        let normalizedRawValue: String = if let maxDecimalPlaces {
            normalizeDecimalInput(rawValue, locale: locale, maxDecimalPlaces: maxDecimalPlaces)
        } else {
            rawValue
        }

        let decimalKey = maxDecimalPlaces == nil ? "." : DecimalFormatSymbols.decimalSeparator(locale: locale)
        let normalizedKey = key == decimalKey ? "." : key

        let nextValue: String = switch normalizedKey {
        case "clear":
            ""
        case "delete":
            String(normalizedRawValue.dropLast())
        case ".":
            appendDecimalSeparator(normalizedRawValue, maxDecimalPlaces: maxDecimalPlaces)
        case "000":
            appendDigits("000", to: normalizedRawValue)
        default:
            if key.count == 1, key.first?.isNumber == true {
                appendDigits(key, to: normalizedRawValue)
            } else {
                normalizedRawValue
            }
        }

        if maxDecimalPlaces == nil {
            return sanitizeIntegerInput(nextValue)
        }

        return sanitizeDecimalInput(
            raw: nextValue,
            locale: locale,
            maxDecimalPlaces: maxDecimalPlaces
        )
    }

    static func sanitizeIntegerInput(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    static func sanitizeDecimalInput(raw: String, locale: Locale = .current, maxDecimalPlaces: Int? = nil) -> String {
        let localDecimal = DecimalFormatSymbols.decimalSeparator(locale: locale)
        let normalized = localDecimal == "," ? raw.replacingOccurrences(of: ",", with: ".") : raw
        let filtered = normalized.filter { $0.isNumber || $0 == "." }

        guard let dotIndex = filtered.firstIndex(of: ".") else {
            return filtered
        }

        let prefix = filtered[...dotIndex]
        let suffix = filtered[filtered.index(after: dotIndex)...].filter { $0 != "." }
        let singleDot = String(prefix) + String(suffix)

        guard let maxDecimalPlaces else { return singleDot }

        let fraction = String(singleDot[singleDot.index(after: dotIndex)...])
        guard fraction.count > maxDecimalPlaces else { return singleDot }

        return String(singleDot[...dotIndex]) + String(fraction.prefix(maxDecimalPlaces))
    }

    static func bitcoinValueToSats(_ rawValue: String, displayUnit: BitcoinDisplayUnit) -> UInt64 {
        let normalized = rawValue.replacingOccurrences(of: " ", with: "")

        switch displayUnit {
        case .modern:
            return min(UInt64(sanitizeIntegerInput(normalized)) ?? 0, maxBitcoinSats)
        case .classic:
            let decimal = decimalValue(sanitizeDecimalInput(raw: normalized, maxDecimalPlaces: classicBitcoinDecimalPlaces))
            let sats = decimal * Decimal(100_000_000)
            return min(roundedUInt64(sats), maxBitcoinSats)
        }
    }

    static func satsToBitcoinValue(_ sats: UInt64, displayUnit: BitcoinDisplayUnit) -> String {
        switch displayUnit {
        case .modern:
            return sats == 0 ? "" : String(sats)
        case .classic:
            guard sats > 0 else { return "" }
            let btc = Decimal(sats) / Decimal(100_000_000)
            return trimTrailingZeros(formatDecimal(btc, maximumFractionDigits: classicBitcoinDecimalPlaces))
        }
    }

    static func fiatConversionBitcoinValue(_ sats: UInt64, displayUnit: BitcoinDisplayUnit) -> String {
        sats == 0 ? "0" : satsToBitcoinValue(sats, displayUnit: displayUnit)
    }

    static func convertedSatsFromFiat(_ rawValue: String, convert: (Double) -> UInt64?) -> UInt64? {
        let fiatValue = fiatDecimalValue(rawValue)
        if NSDecimalNumber(decimal: fiatValue).compare(NSDecimalNumber.zero) == .orderedSame {
            return 0
        }

        return convert(NSDecimalNumber(decimal: fiatValue).doubleValue)
    }

    static func fiatDecimalValue(_ rawValue: String) -> Decimal {
        decimalValue(sanitizeDecimalInput(raw: rawValue, maxDecimalPlaces: fiatDecimalPlaces))
    }

    static func fiatRawValue(from value: Decimal) -> String {
        formatDecimal(value, minimumFractionDigits: fiatDecimalPlaces, maximumFractionDigits: fiatDecimalPlaces)
    }

    static func exceedsMaxBitcoin(_ rawValue: String, displayUnit: BitcoinDisplayUnit) -> Bool {
        let normalized = rawValue.replacingOccurrences(of: " ", with: "")

        switch displayUnit {
        case .modern:
            guard let sats = UInt64(sanitizeIntegerInput(normalized)) else {
                return !normalized.isEmpty
            }
            return sats > maxBitcoinSats
        case .classic:
            let btc = decimalValue(sanitizeDecimalInput(raw: normalized, maxDecimalPlaces: classicBitcoinDecimalPlaces))
            return NSDecimalNumber(decimal: btc).compare(NSDecimalNumber(value: 21_000_000)) == .orderedDescending
        }
    }

    private static func normalizeDecimalInput(_ rawValue: String, locale: Locale, maxDecimalPlaces: Int?) -> String {
        let value = rawValue.replacingOccurrences(of: " ", with: "")
        let hasComma = value.contains(commaSeparator)
        let hasPeriod = value.contains(periodSeparator)

        if hasComma, hasPeriod {
            return normalizeMixedDecimalSeparators(value)
        }

        guard hasComma else { return value }

        if shouldTreatCommaAsGrouping(value, locale: locale, maxDecimalPlaces: maxDecimalPlaces) {
            return value.replacingOccurrences(of: ",", with: "")
        }

        return value.replacingOccurrences(of: ",", with: ".")
    }

    private static func normalizeMixedDecimalSeparators(_ value: String) -> String {
        let decimalSeparator: Character = (value.lastIndex(of: commaSeparator) ?? value.startIndex) >
            (value.lastIndex(of: periodSeparator) ?? value.startIndex)
            ? commaSeparator
            : periodSeparator
        let groupingSeparator = decimalSeparator == commaSeparator ? periodSeparator : commaSeparator

        return value
            .replacingOccurrences(of: String(groupingSeparator), with: "")
            .replacingOccurrences(of: String(decimalSeparator), with: ".")
    }

    private static func shouldTreatCommaAsGrouping(_ value: String, locale: Locale, maxDecimalPlaces: Int?) -> Bool {
        if value.filter({ $0 == commaSeparator }).count > 1 { return true }

        let separator = DecimalFormatSymbols.decimalSeparator(locale: locale)
        if separator != "," { return true }

        let fractionLength = value.split(separator: commaSeparator, maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        return maxDecimalPlaces != nil && fractionLength > maxDecimalPlaces!
    }

    private static func formatGroupedInteger(value: String, groupingSeparator: Character) -> String {
        guard !value.isEmpty else { return "" }
        let normalized = value.drop { $0 == "0" }
        let integer = normalized.isEmpty ? "0" : String(normalized)
        return formatGroupedDigits(integer, groupingSeparator: groupingSeparator)
    }

    private static func formatGroupedIntegerPreservingZeros(value: String, groupingSeparator: Character) -> String {
        guard !value.isEmpty else { return "" }
        return formatGroupedDigits(value, groupingSeparator: groupingSeparator)
    }

    private static func formatGroupedDecimal(value: String, groupingSeparator: Character, decimalSeparator: Character) -> String {
        guard !value.isEmpty else { return "" }
        if value == "." { return String(decimalSeparator) }

        guard let decimalIndex = value.firstIndex(of: ".") else {
            return formatGroupedIntegerPreservingZeros(value: value, groupingSeparator: groupingSeparator)
        }

        let integerPart = String(value[..<decimalIndex])
        let decimalPart = String(value[value.index(after: decimalIndex)...])

        return formatGroupedIntegerPreservingZeros(
            value: integerPart,
            groupingSeparator: groupingSeparator
        ) + String(decimalSeparator) + decimalPart
    }

    private static func appendDecimalSeparator(_ rawValue: String, maxDecimalPlaces: Int?) -> String {
        guard maxDecimalPlaces != nil, !rawValue.contains(".") else { return rawValue }
        return rawValue.isEmpty ? "0." : "\(rawValue)."
    }

    private static func appendDigits(_ digits: String, to rawValue: String) -> String {
        guard rawValue == "0" else { return rawValue + digits }
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func formatGroupedDigits(_ value: String, groupingSeparator: Character) -> String {
        guard value.count > groupSize else { return value }

        var result = ""
        let digits = Array(value)

        for index in digits.indices {
            if index > 0, (digits.count - index).isMultiple(of: groupSize) {
                result.append(groupingSeparator)
            }

            result.append(digits[index])
        }

        return result
    }

    private static func decimalValue(_ rawValue: String) -> Decimal {
        Decimal(string: rawValue, locale: posixLocale) ?? .zero
    }

    private static func roundedUInt64(_ value: Decimal) -> UInt64 {
        let number = NSDecimalNumber(decimal: value)
        let maxNumber = NSDecimalNumber(value: UInt64.max)
        guard number.compare(maxNumber) != .orderedDescending else { return UInt64.max }

        let rounded = number.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        return rounded.uint64Value
    }

    private static func formatDecimal(
        _ value: Decimal,
        minimumFractionDigits: Int = 0,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = posixLocale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.decimalSeparator = "."
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    private static func trimTrailingZeros(_ value: String) -> String {
        value.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

private enum DecimalFormatSymbols {
    static func decimalSeparator(locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        return formatter.decimalSeparator ?? "."
    }
}
