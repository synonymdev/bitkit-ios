import SwiftUI

/// Displays an incoming transfer indicator with amount
/// Shows when funds are being transferred (e.g., to savings from Lightning)
struct IncomingTransfer: View {
    let amount: UInt64

    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        HStack(spacing: 4) {
            Image("transfer")
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundColor(.white64)

            CaptionBText(
                t("wallet__details_transfer_subtitle"),
                textColor: .white64
            )

            if let converted = currency.convert(sats: amount) {
                let formattedAmount = formatAmount(converted)
                CaptionBText(
                    formattedAmount,
                    textColor: .white64,
                    accentColor: .white64
                )
            }
        }
    }

    // MARK: - Helper Methods

    private func formatAmount(_ converted: ConvertedAmount) -> String {
        if currency.primaryDisplay == .bitcoin {
            let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
            return btcComponents.value
        } else {
            // For fiat, don't show the symbol (showSymbol = false in Android)
            return converted.formatted
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        // Bitcoin display
        IncomingTransfer(amount: 85967)
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .bitcoin
                vm.displayUnit = .modern
                return vm
            }())

        IncomingTransfer(amount: 15_231_648)
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .bitcoin
                vm.displayUnit = .modern
                return vm
            }())

        Divider()
            .padding(.vertical, 8)

        // Fiat display
        IncomingTransfer(amount: 85967)
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .fiat
                vm.selectedCurrency = "USD"
                return vm
            }())

        IncomingTransfer(amount: 15_231_648)
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .fiat
                vm.selectedCurrency = "USD"
                return vm
            }())
    }
    .padding()
    .preferredColorScheme(.dark)
}
