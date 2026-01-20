import SwiftUI

/// Displays an incoming transfer indicator with amount
/// Shows when funds are being transferred (e.g., to savings from Lightning)
struct IncomingTransfer: View {
    let amount: UInt64
    /// Optional: remaining duration for force close transfers (e.g., "±14d")
    var remainingDuration: String?

    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        HStack(spacing: 0) {
            Image("arrow-up-down")
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundColor(.textSecondary)
                .padding(.trailing, 3)

            // Show duration if available (force close scenario), otherwise standard transfer text
            if let duration = remainingDuration {
                CaptionBText(t("wallet__activity_transfer_savings_pending", variables: ["duration": duration]))
            } else {
                CaptionBText(t("wallet__details_transfer_subtitle"))
            }

            if let converted = currency.convert(sats: amount) {
                let formattedAmount = formatAmount(converted)
                CaptionBText(formattedAmount)
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
