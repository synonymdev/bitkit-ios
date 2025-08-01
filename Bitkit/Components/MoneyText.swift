import SwiftUI

// MoneyText - Single text display component for monetary values
enum MoneySize {
    case display
    case title
    case bodyMSB
    case bodySSB
    case caption
}

enum MoneyUnitType {
    case primary
    case secondary
}

struct MoneyText: View {
    let sats: Int
    var unitType: MoneyUnitType = .primary
    var size: MoneySize = .display
    var symbol: Bool? = nil
    var enableHide: Bool = true
    var prefix: String? = nil
    var color: Color = .textPrimary
    var symbolColor: Color? = nil

    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel

    // MARK: - Computed Properties
    private var unit: PrimaryDisplay {
        unitType == .secondary ? (currency.primaryDisplay == .bitcoin ? .fiat : .bitcoin) : currency.primaryDisplay
    }

    private var showSymbol: Bool {
        symbol ?? (unit == .fiat)
    }

    private var hideBalance: Bool {
        enableHide && settings.hideBalance
    }

    private var displayDots: String {
        size == .display ? " • • • • • • • • •" : " • • • • •"
    }

    private var displayText: String {
        if showSymbol {
            let baseSymbol = unit == .bitcoin ? "₿" : fiatSymbol
            let symbolPart = prefix != nil ? "<accent>\(prefix!) \(baseSymbol)</accent>" : "<accent>\(baseSymbol)</accent>"
            return "\(symbolPart) \(formattedValue)"
        } else {
            return prefix != nil ? "<accent>\(prefix!)</accent> \(formattedValue)" : formattedValue
        }
    }

    var body: some View {
        textComponent(displayText)
            .foregroundColor(color)
    }
}

// MARK: - Helper Views
extension MoneyText {

    @ViewBuilder
    private func textComponent(_ text: String) -> some View {
        switch size {
        case .display:
            DisplayText(
                // Cap symbol font weight to ExtraBold
                text, textColor: color, accentColor: symbolColor ?? .textSecondary, accentFont: size == .display ? Fonts.extraBold : nil)
        case .title:
            TitleText(text, textColor: color, accentColor: symbolColor ?? .textSecondary)
        case .bodyMSB:
            BodyMSBText(text, textColor: color, accentColor: symbolColor ?? .textSecondary)
        case .bodySSB:
            BodySSBText(text, textColor: color, accentColor: symbolColor ?? .textSecondary)
        case .caption:
            CaptionMText(text, textColor: color, accentColor: symbolColor ?? .textSecondary)
        }
    }
}

// MARK: - Helper Methods
extension MoneyText {
    private var fiatSymbol: String {
        guard let converted = currency.convert(sats: UInt64(abs(sats))) else { return "$" }
        return converted.symbol
    }

    private var formattedValue: String {
        guard let converted = currency.convert(sats: UInt64(abs(sats))) else { return "0" }

        if hideBalance {
            return displayDots
        }

        switch unit {
        case .fiat:
            return converted.formatted
        case .bitcoin:
            let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
            return btcComponents.value
        }
    }
}

// MARK: - Preview Helpers
extension MoneyText {
    fileprivate static func previewCurrencyVM(
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

    fileprivate static func previewSettingsVM(hideBalance: Bool = false) -> SettingsViewModel {
        let vm = SettingsViewModel()
        vm.hideBalance = hideBalance
        return vm
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            // Primary display (Bitcoin)
            MoneyText(sats: 123_456, unitType: .primary, size: .display)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM())

            // Secondary display (Fiat)
            MoneyText(sats: 123_456, unitType: .secondary, size: .caption)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM())

            // With prefix
            MoneyText(sats: 123_456, prefix: "+", color: .green)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .fiat, currency: "EUR"))
                .environmentObject(MoneyText.previewSettingsVM())

            // Hidden balance
            MoneyText(sats: 123_456, enableHide: true)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM(hideBalance: true))

            // No symbol
            MoneyText(sats: 123_456, symbol: false)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .fiat, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
