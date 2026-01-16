import SwiftUI

struct WalletBalanceView: View {
    let type: WalletType
    let sats: UInt64
    var amountTestIdentifier: String?

    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading) {
            CaptionMText(type.title)
                .padding(.bottom, 4)

            HStack(spacing: 4) {
                Image(type.imageAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .padding(.trailing, 4)

                MoneyText(
                    sats: Int(sats),
                    size: .subtitle,
                    enableHide: true,
                    symbolColor: .textPrimary,
                    testIdentifier: amountTestIdentifier
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 32) {
        // Bitcoin display (modern)
        HStack {
            WalletBalanceView(
                type: .onchain,
                sats: 123_456
            )

            Divider()
                .frame(height: 50)

            WalletBalanceView(
                type: .lightning,
                sats: 123_456
            )
        }
        .environmentObject(
            {
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .bitcoin
                vm.displayUnit = .modern
                return vm
            }()
        )

        // Bitcoin display (modern) - with transfer icon
        HStack {
            WalletBalanceView(type: .onchain, sats: 123_456)

            Divider()
                .frame(height: 50)

            WalletBalanceView(type: .lightning, sats: 123_456)
        }
        .environmentObject(
            {
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .bitcoin
                vm.displayUnit = .modern
                return vm
            }()
        )

        Spacer()

        // USD display
        HStack {
            WalletBalanceView(type: .onchain, sats: 123_456)

            Divider()
                .frame(height: 50)

            WalletBalanceView(type: .lightning, sats: 123_456)
        }
        .environmentObject(
            {
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .fiat
                vm.selectedCurrency = "USD"
                vm.displayUnit = .modern
                return vm
            }()
        )

        Spacer()

        // EUR display
        HStack {
            WalletBalanceView(type: .onchain, sats: 123_456)

            Divider()
                .frame(height: 50)

            WalletBalanceView(type: .lightning, sats: 123_456)
        }
        .environmentObject(
            {
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .fiat
                vm.selectedCurrency = "EUR"
                vm.displayUnit = .modern
                return vm
            }()
        )

        Spacer()

        // Bitcoin display with classic unit
        HStack {
            WalletBalanceView(type: .onchain, sats: 123_456)

            Divider()
                .frame(height: 50)

            WalletBalanceView(type: .lightning, sats: 123_456)
        }
        .environmentObject(
            {
                let vm = CurrencyViewModel()
                vm.primaryDisplay = .bitcoin
                vm.displayUnit = .classic
                return vm
            }()
        )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .preferredColorScheme(.dark)
}
