import SwiftUI

struct SpendingAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?

    // TODO: Calculate the maximum amount that can be transferred once we can get fees from a tx without sending it
    // https://github.com/synonymdev/bitkit/blob/aa7271970282675068cc9edda4455d74aa3b6c3c/src/screens/Transfer/SpendingAmount.tsx

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(localizedString("lightning__spending_amount__title"), accentColor: .purpleAccent)

            AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats) { newSats in
                satsAmount = newSats
                overrideSats = nil
            }
            .padding(.top, 32)

            Spacer()

            HStack(alignment: .bottom) {
                AvailableAmount(label: localizedString("wallet__send_available"), amount: wallet.totalBalanceSats)
                Spacer()
                actionButtons
            }
            .padding(.vertical, 8)

            Divider()

            CustomButton(title: localizedString("common__continue"), isDisabled: satsAmount == 0) {
                do {
                    let newOrder = try await blocktank.createOrder(spendingBalanceSats: satsAmount)
                    transfer.onOrderCreated(order: newOrder)
                    navigation.navigate(.spendingConfirm)
                } catch {
                    app.toast(error)
                }
            }
            .padding(.top, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "transfer"
            ) {
                withAnimation {
                    currency.togglePrimaryDisplay()
                }
            }

            NumberPadActionButton(text: localizedString("lightning__spending_amount__quarter")) {
                overrideSats = UInt64(wallet.totalBalanceSats) / 4
            }

            NumberPadActionButton(text: localizedString("common__max")) {
                overrideSats = UInt64(Double(wallet.totalBalanceSats) * 0.9) // TODO: can't actually use max, need to estimate fees
            }
        }
    }
}

#Preview("USD") {
    NavigationStack {
        SpendingAmount()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(
                {
                    let vm = CurrencyViewModel()
                    vm.selectedCurrency = "USD"
                    vm.primaryDisplay = .fiat
                    return vm
                }()
            )
    }
    .preferredColorScheme(.dark)
}

#Preview("EUR") {
    NavigationStack {
        SpendingAmount()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(
                {
                    let vm = CurrencyViewModel()
                    vm.selectedCurrency = "EUR"
                    vm.primaryDisplay = .fiat
                    return vm
                }()
            )
    }
    .preferredColorScheme(.dark)
}

#Preview("Bitcoin modern") {
    NavigationStack {
        SpendingAmount()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(
                {
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .bitcoin
                    vm.displayUnit = .modern
                    return vm
                }()
            )
    }
    .preferredColorScheme(.dark)
}

#Preview("Bitcoin classic") {
    NavigationStack {
        SpendingAmount()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(
                {
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .bitcoin
                    vm.displayUnit = .classic
                    return vm
                }()
            )
    }
    .preferredColorScheme(.dark)
}
