import SwiftUI

// MoneyCell - Cell/row style display for lists (right-aligned, compact layout)
struct MoneyCell: View {
    let sats: Int
    let prefix: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            MoneyText(
                sats: sats,
                unitType: .primary,
                size: .bodyMSB,
                prefix: prefix,
                color: .textPrimary,
                symbolColor: .textPrimary
            )

            MoneyText(
                sats: sats,
                unitType: .secondary,
                size: .caption,
                color: .textSecondary
            )
        }
    }
}

// MARK: - Preview Helpers
extension MoneyCell {
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

    fileprivate static func previewWalletVM(hideBalance: Bool = false) -> WalletViewModel {
        let vm = WalletViewModel()
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
                .environmentObject(MoneyCell.previewWalletVM())

            // With symbol
            MoneyCell(sats: 123_456, prefix: "-")
                .environmentObject(MoneyCell.previewCurrencyVM(primaryDisplay: .fiat, currency: "EUR"))
                .environmentObject(MoneyCell.previewWalletVM())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
