import SwiftUI

struct FundTransferView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var isCreatingOrder = false
    @State private var showConfirmation = false

    // TODO: Calculate the maximum amount that can be transferred once we can get fees from a tx without sending it
    // https://github.com/synonymdev/bitkit/blob/aa7271970282675068cc9edda4455d74aa3b6c3c/src/screens/Transfer/SpendingAmount.tsx

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__spending_amount__title", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                // Visible balance display that acts as a button
                AmountInput(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                    print("satsAmount: \(satsAmount)")
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        BodySText(NSLocalizedString("wallet__send_available", comment: "").uppercased(), textColor: .textSecondary)

                        if let converted = currency.convert(sats: UInt64(wallet.totalBalanceSats)) {
                            if primaryDisplay == .bitcoin {
                                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                                BodySText("\(btcComponents.symbol) \(btcComponents.value)")
                            } else {
                                BodySText("\(converted.symbol) \(converted.formatted)")
                            }
                        }
                    }

                    Spacer()

                    amountButtons
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Divider()

            Spacer()

            NavigationLink(destination: SpendingConfirmationView(), isActive: $showConfirmation) {
                EmptyView()
            }

            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                do {
                    let newOrder = try await blocktank.createOrder(spendingBalanceSats: satsAmount)
                    transfer.onOrderCreated(order: newOrder)
                    showConfirmation = true
                } catch {
                    app.toast(error)
                }
            }
            .disabled(satsAmount == 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .backToWalletButton()
        .task {
            primaryDisplay = currency.primaryDisplay
        }
    }

    private var amountButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(
                text: primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "transfer-purple"
            ) {
                withAnimation {
                    primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
                }
            }

            NumberPadActionButton(text: "25%") {
                overrideSats = UInt64(wallet.totalBalanceSats) / 4
            }

            NumberPadActionButton(text: NSLocalizedString("common__max", comment: "")) {
                overrideSats = UInt64(Double(wallet.totalBalanceSats) * 0.9) // TODO: can't actually use max, need to estimate fees
            }
        }
    }
}

#Preview("USD") {
    NavigationStack {
        FundTransferView()
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
                }())
    }
    .preferredColorScheme(.dark)
}

#Preview("EUR") {
    NavigationStack {
        FundTransferView()
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
                }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Bitcoin modern") {
    NavigationStack {
        FundTransferView()
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
                }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Bitcoin classic") {
    NavigationStack {
        FundTransferView()
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
                }())
    }
    .preferredColorScheme(.dark)
}
