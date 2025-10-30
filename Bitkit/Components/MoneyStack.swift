import SwiftUI

// MoneyStack - Stacked display with toggle functionality, optional eye icon and swipe gestures
struct MoneyStack: View {
    let sats: Int
    var prefix: String?
    var showSymbol: Bool = false
    var showEyeIcon: Bool = false
    var enableSwipeGesture: Bool = false

    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel

    // MARK: - Constants

    private let springAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            secondaryBalance
            primaryBalance
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TotalBalance")
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(springAnimation) {
                currency.togglePrimaryDisplay()
            }
            Haptics.play(.medium)
        }
        .animation(springAnimation, value: currency.primaryDisplay)
        .conditionalGesture(enableSwipeGesture) {
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    let horizontalAmount = value.translation.width
                    let verticalAmount = value.translation.height

                    // Only trigger if horizontal swipe is more significant than vertical
                    if abs(horizontalAmount) > abs(verticalAmount) {
                        withAnimation(springAnimation) {
                            settings.hideBalance.toggle()
                        }
                        Haptics.play(.medium)
                    }
                }
        }
        .animation(enableSwipeGesture ? springAnimation : nil, value: settings.hideBalance)
    }
}

// MARK: - Helper Views

private extension MoneyStack {
    var secondaryBalance: some View {
        let components = displayComponents(for: .secondary, size: .caption)

        return VStack(alignment: .leading, spacing: 0) {
            MoneyText(
                sats: sats,
                unitType: .secondary,
                size: .caption,
                symbol: true,
                color: .textSecondary
            )
            .accessibilityHidden(true)
            .contentTransition(.numericText())
            .transition(
                .move(edge: .bottom)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 1.5, anchor: .topLeading))
            )
            .overlay(alignment: .leading) {
                BalanceAccessibilityProxy(
                    valueText: components.value,
                    symbolText: components.symbol,
                    includeSymbol: true
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TotalBalance-secondary")
    }

    var primaryBalance: some View {
        let shouldShowSymbol = currency.primaryDisplay == .bitcoin ? showSymbol : true
        let components = displayComponents(for: .primary, size: .display, includeSymbol: shouldShowSymbol)

        return HStack {
            MoneyText(
                sats: sats,
                unitType: .primary,
                size: .display,
                symbol: shouldShowSymbol,
                prefix: prefix,
                color: .textPrimary
            )
            .accessibilityHidden(true)
            .contentTransition(.numericText())
            .overlay(alignment: .leading) {
                BalanceAccessibilityProxy(
                    valueText: components.value,
                    symbolText: components.symbol,
                    includeSymbol: shouldShowSymbol
                )
            }

            Spacer()

            if showEyeIcon && settings.hideBalance {
                eyeIconButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TotalBalance-primary")
        .transition(
            .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.5, anchor: .topLeading))
        )
    }

    var eyeIconButton: some View {
        Button(action: revealBalance) {
            Image("eye")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.textPrimary)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Helper Methods

private extension MoneyStack {
    func revealBalance() {
        withAnimation(springAnimation) {
            settings.hideBalance = false
        }
        Haptics.play(.medium)
    }

    func displayComponents(for unitType: MoneyUnitType, size: MoneySize, includeSymbol: Bool = true) -> (symbol: String, value: String) {
        let displayUnit: PrimaryDisplay = {
            switch unitType {
            case .primary:
                return currency.primaryDisplay
            case .secondary:
                return currency.primaryDisplay == .bitcoin ? .fiat : .bitcoin
            }
        }()

        let hiddenDots: String = {
            switch size {
            case .display:
                return " • • • • • • • • •"
            default:
                return " • • • • •"
            }
        }()

        if settings.hideBalance {
            return (symbol(for: displayUnit), hiddenDots)
        }

        guard let converted = currency.convert(sats: UInt64(abs(sats))) else {
            return (symbol(for: displayUnit), "0")
        }

        let prefixString: String = {
            guard let prefix else { return "" }
            return prefix.isEmpty ? "" : "\(prefix) "
        }()

        switch displayUnit {
        case .fiat:
            let formatted = converted.formatted
            let trimmed = formatted.removingFirstOccurrence(of: converted.symbol).trimmingCharacters(in: balanceTrimCharacterSet)
            return (symbol(for: displayUnit), prefixString + trimmed)
        case .bitcoin:
            let components = converted.bitcoinDisplay(unit: currency.displayUnit)
            let value = includeSymbol ? components.value : components.value
            return (components.symbol, prefixString + value)
        }
    }

    func symbol(for displayUnit: PrimaryDisplay) -> String {
        switch displayUnit {
        case .bitcoin:
            return "₿"
        case .fiat:
            return currency.symbol
        }
    }
}

// MARK: - Helper View Modifier

extension View {
    @ViewBuilder
    func conditionalGesture(_ condition: Bool, gesture: () -> some Gesture) -> some View {
        if condition {
            self.gesture(gesture())
        } else {
            self
        }
    }
}

// MARK: - Preview Helpers

private let balanceTrimCharacterSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00a0}"))

private extension String {
    func removingFirstOccurrence(of substring: String) -> String {
        guard let range = range(of: substring) else { return self }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }
}

private struct BalanceAccessibilityProxy: View {
    let valueText: String
    let symbolText: String
    let includeSymbol: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(valueText.isEmpty ? "0" : valueText)
                .foregroundColor(.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("MoneyText")

            if includeSymbol {
                Text(symbolText)
                    .foregroundColor(.clear)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("MoneyFiatSymbol")
            }
        }
        .allowsHitTesting(false)
    }
}

private extension MoneyStack {
    static func previewCurrencyVM(
        primaryDisplay: PrimaryDisplay,
        currency: String,
        displayUnit: BitcoinDisplayUnit = .modern
    ) -> CurrencyViewModel {
        let vm = CurrencyViewModel()
        vm.primaryDisplay = primaryDisplay
        vm.selectedCurrency = currency
        vm.displayUnit = displayUnit
        return vm
    }

    static func previewSettingsVM(hideBalance: Bool = false) -> SettingsViewModel {
        let vm = SettingsViewModel()
        vm.hideBalance = hideBalance
        return vm
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            // Large amounts to show dramatic transitions
            MoneyStack(sats: 1_234_567_890, prefix: "+", showSymbol: false)
                .environmentObject(MoneyStack.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyStack.previewSettingsVM())

            // With symbol and different amount
            MoneyStack(sats: 987_654_321, prefix: "-", showSymbol: true)
                .environmentObject(MoneyStack.previewCurrencyVM(primaryDisplay: .fiat, currency: "EUR"))
                .environmentObject(MoneyStack.previewSettingsVM())

            // Medium amount with eye icon
            MoneyStack(sats: 456_789_123, showEyeIcon: true)
                .environmentObject(MoneyStack.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD", displayUnit: .classic))
                .environmentObject(MoneyStack.previewSettingsVM(hideBalance: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
