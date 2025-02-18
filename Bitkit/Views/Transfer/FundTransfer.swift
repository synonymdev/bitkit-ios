import SwiftUI

struct FundTransfer: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var isCreatingOrder = false
    @State private var newOrder: IBtOrder? = nil
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__spending_amount__title", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                // Visible balance display that acts as a button
                TransferAmount(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                    print("satsAmount: \(satsAmount)")
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        BodySText(NSLocalizedString("wallet__send_available", comment: "").uppercased(), textColor: .textSecondary)
                        BodySText("\(wallet.totalBalanceSats) sats")
                    }

                    Spacer()

                    amountButtons
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Divider()

            Spacer()

            if let order = newOrder {
                NavigationLink(destination: ConfirmOrderView_OLD(order: order), isActive: $showConfirmation) {
                    EmptyView()
                }
            }

            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                do {
                    newOrder = try await blocktank.createOrder(spendingBalanceSats: satsAmount)
                    // Sleep for 1 second
                    try await Task.sleep(nanoseconds: 100_000_000)
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
        .task {
            primaryDisplay = currency.primaryDisplay
        }
    }

    private var amountButtons: some View {
        HStack {
            Button(action: {
                primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
            }) {
                Text(primaryDisplay == .bitcoin ? currency.selectedCurrency : "BTC")
            }
            .padding(.trailing, 16)

            Button(action: {
                overrideSats = UInt64(wallet.totalBalanceSats) / 4
            }) {
                Text("25%")
            }
            .padding(.trailing, 16)

            Button(action: {
                // Handle MAX tap
            }) {
                Text("MAX")
            }
        }
    }
}

#Preview("USD") {
    NavigationView {
        FundTransfer()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.selectedCurrency = "USD"
                vm.primaryDisplay = .fiat
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}

#Preview("EUR") {
    NavigationView {
        FundTransfer()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.selectedCurrency = "EUR"
                vm.primaryDisplay = .fiat
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Bitcoin") {
    NavigationView {
        FundTransfer()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject({
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .bitcoin
                vm.displayUnit = .modern
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}
