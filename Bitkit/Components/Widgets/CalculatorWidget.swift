import SwiftUI

/// A widget that provides Bitcoin to fiat currency conversion.
struct CalculatorWidget: View {
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @Environment(CalculatorInputManager.self) private var calculatorInput
    @EnvironmentObject private var currency: CurrencyViewModel

    @State private var values = CalculatorWidgetValues()
    @State private var hasHydrated = false
    @State private var previousDisplayUnit: BitcoinDisplayUnit = .modern

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
            VStack(spacing: 0) {
                CalculatorWidgetWideContent(
                    values: currentValues,
                    activeInput: calculatorInput.activeInput,
                    onSelectInput: selectInput
                )
            }
            .animation(.easeInOut(duration: 0.2), value: calculatorInput.activeInput)
        }
        .task {
            hydrateValuesIfNeeded()
        }
        .onChange(of: currency.selectedCurrency) {
            refreshCurrencyFields()
            refreshFiatFromBitcoin()
            refreshNumberPadConfiguration()
            persistValues()
        }
        .onChange(of: currency.displayUnit) { _, newUnit in
            convertBitcoinValue(to: newUnit)
            refreshCurrencyFields()
            refreshFiatFromBitcoin()
            refreshNumberPadConfiguration()
            persistValues()
        }
        .onChange(of: currency.rates) {
            refreshCurrencyFields()
            refreshFiatFromBitcoin()
            persistValues()
        }
        .onChange(of: calculatorInput.submittedKey?.id) {
            guard let key = calculatorInput.submittedKey?.value else { return }
            handleNumberPadInput(key)
        }
        .onDisappear {
            calculatorInput.dismiss()
        }
    }

    private var currentValues: CalculatorWidgetValues {
        CalculatorWidgetValues(
            bitcoinValue: values.bitcoinValue,
            fiatValue: values.fiatValue,
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
    }

    private func hydrateValuesIfNeeded() {
        guard !hasHydrated else { return }
        hasHydrated = true

        let saved = CalculatorHomeScreenWidgetOptionsStore.load()
        let savedSats = CalculatorWidgetFormatter.bitcoinValueToSats(saved.bitcoinValue, displayUnit: saved.displayUnit)

        values = CalculatorWidgetValues(
            bitcoinValue: saved.bitcoinValue.isEmpty
                ? ""
                : CalculatorWidgetFormatter.satsToBitcoinValue(savedSats, displayUnit: currency.displayUnit),
            fiatValue: saved.fiatValue,
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
        previousDisplayUnit = currency.displayUnit

        refreshFiatFromBitcoin()
        persistValues()
    }

    private func selectInput(_ input: CalculatorMoneyType) {
        calculatorInput.activate(
            input,
            numberPadType: numberPadType(for: input),
            decimalSeparator: CalculatorWidgetFormatter.decimalSeparator()
        )
    }

    private func handleNumberPadInput(_ key: String) {
        guard let activeInput = calculatorInput.activeInput else { return }

        let currentValue = rawValue(for: activeInput)
        let nextValue = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: currentValue,
            key: key,
            maxDecimalPlaces: maxDecimalPlaces(for: activeInput)
        )

        guard nextValue != currentValue || key == "delete" else {
            showInputError(for: key)
            return
        }

        if activeInput == .bitcoin,
           CalculatorWidgetFormatter.exceedsMaxBitcoin(nextValue, displayUnit: currency.displayUnit)
        {
            showInputError(for: key)
            return
        }

        calculatorInput.errorKey = nil

        switch activeInput {
        case .bitcoin:
            values.bitcoinValue = nextValue
            refreshFiatFromBitcoin()
        case .fiat:
            values.fiatValue = nextValue
            refreshBitcoinFromFiat()
        }

        persistValues()
    }

    private func rawValue(for input: CalculatorMoneyType) -> String {
        switch input {
        case .bitcoin:
            return values.bitcoinValue
        case .fiat:
            return values.fiatValue
        }
    }

    private func numberPadType(for input: CalculatorMoneyType) -> NumberPadType {
        switch input {
        case .bitcoin where currency.displayUnit == .modern:
            return .integer
        default:
            return .decimal
        }
    }

    private func maxDecimalPlaces(for input: CalculatorMoneyType) -> Int? {
        switch input {
        case .bitcoin where currency.displayUnit == .modern:
            return nil
        case .bitcoin:
            return CalculatorWidgetFormatter.classicBitcoinDecimalPlaces
        case .fiat:
            return CalculatorWidgetFormatter.fiatDecimalPlaces
        }
    }

    private func refreshNumberPadConfiguration() {
        guard let activeInput = calculatorInput.activeInput else { return }
        calculatorInput.updateConfiguration(
            numberPadType: numberPadType(for: activeInput),
            decimalSeparator: CalculatorWidgetFormatter.decimalSeparator()
        )
    }

    private func refreshCurrencyFields() {
        values.displayUnit = currency.displayUnit
        values.currencySymbol = currency.symbol
        values.selectedCurrency = currency.selectedCurrency
    }

    private func convertBitcoinValue(to newUnit: BitcoinDisplayUnit) {
        guard previousDisplayUnit != newUnit else { return }

        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(values.bitcoinValue, displayUnit: previousDisplayUnit)
        values.bitcoinValue = CalculatorWidgetFormatter.satsToBitcoinValue(sats, displayUnit: newUnit)
        previousDisplayUnit = newUnit
    }

    private func refreshFiatFromBitcoin() {
        guard !values.bitcoinValue.isEmpty else {
            values.fiatValue = ""
            return
        }

        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(values.bitcoinValue, displayUnit: currency.displayUnit)
        if sats == 0 {
            values.fiatValue = "0.00"
            return
        }

        if let converted = currency.convert(sats: sats) {
            values.fiatValue = CalculatorWidgetFormatter.fiatRawValue(from: converted.value)
        } else {
            values.fiatValue = ""
        }
    }

    private func refreshBitcoinFromFiat() {
        guard !values.fiatValue.isEmpty else {
            values.bitcoinValue = ""
            return
        }

        let fiatValue = CalculatorWidgetFormatter.fiatDecimalValue(values.fiatValue)
        if NSDecimalNumber(decimal: fiatValue).compare(NSDecimalNumber.zero) == .orderedSame {
            values.bitcoinValue = currency.displayUnit == .modern ? "0" : "0"
            return
        }

        let fiatDouble = NSDecimalNumber(decimal: fiatValue).doubleValue
        if let sats = currency.convert(fiatAmount: fiatDouble) {
            let cappedSats = min(sats, CalculatorWidgetFormatter.maxBitcoinSats)
            values.bitcoinValue = CalculatorWidgetFormatter.satsToBitcoinValue(cappedSats, displayUnit: currency.displayUnit)
        } else {
            values.bitcoinValue = ""
        }
    }

    private func persistValues() {
        CalculatorHomeScreenWidgetOptionsStore.save(currentValues)
        CalculatorHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
    }

    private func showInputError(for key: String) {
        Haptics.notify(.warning)
        calculatorInput.errorKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if calculatorInput.errorKey == key {
                calculatorInput.errorKey = nil
            }
        }
    }
}

// MARK: - Wide layout (in-app + carousel page + .systemMedium OS widget)

struct CalculatorWidgetWideContent: View {
    let values: CalculatorWidgetValues
    var activeInput: CalculatorMoneyType?
    var onSelectInput: ((CalculatorMoneyType) -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            CalculatorWidgetRow(
                currencySymbol: "₿",
                value: CalculatorWidgetFormatter.formatBitcoinValue(values.bitcoinValue, displayUnit: values.displayUnit),
                label: t("settings__general__unit_bitcoin"),
                iconSize: 32,
                rowPadding: 16,
                showsLabel: true,
                isActive: activeInput == .bitcoin
            ) {
                onSelectInput?(.bitcoin)
            }
            .accessibilityIdentifier("CalculatorBtcInput")

            CalculatorWidgetRow(
                currencySymbol: values.currencySymbol,
                value: CalculatorWidgetFormatter.formatFiatValue(values.fiatValue),
                placeholder: CalculatorWidgetFormatter.formatFiatPlaceholder(values.fiatValue),
                label: values.selectedCurrency,
                iconSize: 32,
                rowPadding: 16,
                showsLabel: true,
                isActive: activeInput == .fiat
            ) {
                onSelectInput?(.fiat)
            }
            .accessibilityIdentifier("CalculatorFiatInput")
        }
    }
}

// MARK: - Compact layout (small carousel page + .systemSmall OS widget)

struct CalculatorWidgetCompactContent: View {
    let values: CalculatorWidgetValues

    var body: some View {
        VStack(spacing: 16) {
            CalculatorWidgetRow(
                currencySymbol: "₿",
                value: CalculatorWidgetFormatter.formatBitcoinValue(values.bitcoinValue, displayUnit: values.displayUnit),
                iconSize: 24,
                rowPadding: 12,
                showsLabel: false,
                isActive: false
            )

            CalculatorWidgetRow(
                currencySymbol: values.currencySymbol,
                value: CalculatorWidgetFormatter.formatFiatValue(values.fiatValue),
                iconSize: 24,
                rowPadding: 12,
                showsLabel: false,
                isActive: false
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}

private struct CalculatorWidgetRow: View {
    let currencySymbol: String
    let value: String
    var placeholder: String = ""
    var label: String?
    let iconSize: CGFloat
    let rowPadding: CGFloat
    let showsLabel: Bool
    let isActive: Bool
    var onTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.gray6)

                Text(CalculatorWidgetFormatter.displaySymbol(currencySymbol))
                    .font(Fonts.semiBold(size: iconSize >= 32 ? 17 : 15))
                    .foregroundColor(.brandAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: iconSize, height: iconSize)

            HStack(spacing: 0) {
                Text(displayValue)
                    .font(Fonts.semiBold(size: 17))
                    .foregroundColor(value.isEmpty ? .white50 : .textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if isActive {
                    CalculatorCursor()
                        .frame(width: 0)
                        .offset(x: -1)
                }

                if !placeholder.isEmpty {
                    Text(placeholder)
                        .font(Fonts.semiBold(size: 17))
                        .foregroundColor(.white50)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            if showsLabel, let label {
                CaptionBText(label.uppercased(), textColor: .textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(rowPadding)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    private var displayValue: String {
        value.isEmpty ? "0" : value
    }
}

private struct CalculatorCursor: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Rectangle()
                .fill(isVisible(at: context.date) ? Color.brandAccent : Color.clear)
                .frame(width: 2, height: 22)
        }
        .frame(width: 2, height: 22)
    }

    private func isVisible(at date: Date) -> Bool {
        Int(date.timeIntervalSince1970 * 2) % 2 == 0
    }
}

#Preview("Default") {
    CalculatorWidget()
        .padding()
        .background(Color.black)
        .environment(CalculatorInputManager())
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
}

#Preview("Editing") {
    CalculatorWidget(isEditing: true)
        .padding()
        .background(Color.black)
        .environment(CalculatorInputManager())
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
}
