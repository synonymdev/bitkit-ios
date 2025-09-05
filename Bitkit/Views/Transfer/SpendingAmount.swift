import SwiftUI

struct SpendingAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @StateObject private var amountViewModel = AmountInputViewModel()

    var satsAmount: UInt64 {
        amountViewModel.amountSats
    }

    // TODO: Calculate the maximum amount that can be transferred once we can get fees from a tx without sending it
    // https://github.com/synonymdev/bitkit/blob/aa7271970282675068cc9edda4455d74aa3b6c3c/src/screens/Transfer/SpendingAmount.tsx

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spending_amount__title"), accentColor: .purpleAccent)

            NumberPadTextField(viewModel: amountViewModel, showConversion: false)
                .onTapGesture {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
                .padding(.top, 32)

            Spacer()

            HStack(alignment: .bottom) {
                AvailableAmount(label: t("wallet__send_available"), amount: wallet.totalBalanceSats)
                    .onTapGesture {
                        amountViewModel.updateFromSats(UInt64(wallet.totalBalanceSats), currency: currency)
                    }

                Spacer()

                actionButtons
            }
            .padding(.bottom, 12)

            Divider()

            NumberPad(
                type: amountViewModel.getNumberPadType(currency: currency),
                errorKey: amountViewModel.errorKey
            ) { key in
                amountViewModel.handleNumberPadInput(key, currency: currency)
            }

            CustomButton(title: t("common__continue"), isDisabled: satsAmount == 0) {
                do {
                    let newOrder = try await blocktank.createOrder(spendingBalanceSats: satsAmount)
                    transfer.onOrderCreated(order: newOrder)
                    navigation.navigate(.spendingConfirm)
                } catch {
                    app.toast(error)
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down"
            ) {
                withAnimation {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
            }

            NumberPadActionButton(text: t("lightning__spending_amount__quarter")) {
                amountViewModel.updateFromSats(UInt64(wallet.totalBalanceSats) / 4, currency: currency)
            }

            NumberPadActionButton(text: t("common__max")) {
                // TODO: can't actually use max, need to estimate fees
                amountViewModel.updateFromSats(UInt64(Double(wallet.totalBalanceSats) * 0.9), currency: currency)
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
