import SwiftUI

// MoneyCell - Cell/row style display for lists (right-aligned, compact layout)
struct MoneyCell: View {
    let sats: Int
    let prefix: String

    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            MoneyText(
                sats: sats,
                unitType: .primary,
                size: .bodyMSB,
                prefix: prefix,
                color: .textPrimary,
                symbolColor: .textSecondary
            )
            .overlay(alignment: .trailing) {
                HStack(spacing: 4) {
                    Text(prefix)
                        .foregroundColor(.clear)
                        .accessibilityIdentifier("ActivityPrefix")

                    Text(primaryValue)
                        .foregroundColor(.clear)
                        .accessibilityIdentifier("ActivityAmount")
                }
                .allowsHitTesting(false)
            }

            MoneyText(
                sats: sats,
                unitType: .secondary,
                size: .caption,
                color: .textSecondary
            )
            .overlay(alignment: .trailing) {
                HStack(spacing: 4) {
                    Text(secondarySymbol)
                        .foregroundColor(.clear)
                        .accessibilityIdentifier("ActivityFiatSymbol")

                    Text(secondaryValue)
                        .foregroundColor(.clear)
                        .accessibilityIdentifier("ActivityFiatAmount")
                }
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Helpers

private extension MoneyCell {
    var hiddenDots: String { " • • • • •" }

    var convertedAmount: ConvertedAmount? {
        currency.convert(sats: UInt64(abs(sats)))
    }

    var primaryValue: String {
        guard !settings.hideBalance, let convertedAmount else { return hiddenDots }

        switch currency.primaryDisplay {
        case .bitcoin:
            return convertedAmount.bitcoinDisplay(unit: currency.displayUnit).value
        case .fiat:
            return convertedAmount.formatted
                .removingFirstOccurrence(of: convertedAmount.symbol)
                .trimmingCharacters(in: balanceTrimCharacterSet)
        }
    }

    var secondarySymbol: String {
        guard !settings.hideBalance, let convertedAmount else {
            return currency.primaryDisplay == .bitcoin ? currency.symbol : "₿"
        }

        switch currency.primaryDisplay {
        case .bitcoin:
            return convertedAmount.symbol
        case .fiat:
            return convertedAmount.bitcoinDisplay(unit: currency.displayUnit).symbol
        }
    }

    var secondaryValue: String {
        guard !settings.hideBalance, let convertedAmount else { return hiddenDots }

        switch currency.primaryDisplay {
        case .bitcoin:
            return convertedAmount.formatted
                .removingFirstOccurrence(of: convertedAmount.symbol)
                .trimmingCharacters(in: balanceTrimCharacterSet)
        case .fiat:
            return convertedAmount.bitcoinDisplay(unit: currency.displayUnit).value
        }
    }
}

private let balanceTrimCharacterSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00a0}"))

private extension String {
    func removingFirstOccurrence(of substring: String) -> String {
        guard let range = range(of: substring) else { return self }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }
}

// MARK: - Preview Helpers

private extension MoneyCell {
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
            // With toggle enabled
            MoneyCell(sats: 123_456, prefix: "+")
                .environmentObject(MoneyCell.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyCell.previewSettingsVM())

            // With symbol
            MoneyCell(sats: 123_456, prefix: "-")
                .environmentObject(MoneyCell.previewCurrencyVM(primaryDisplay: .fiat, currency: "EUR"))
                .environmentObject(MoneyCell.previewSettingsVM())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
