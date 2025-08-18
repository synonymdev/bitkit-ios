import SwiftUI

struct WalletBalanceView: View {
    let type: WalletType
    let sats: UInt64

    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading) {
            CaptionMText(type.title)
                .padding(.bottom, 4)

            if let converted = currency.convert(sats: sats) {
                if currency.primaryDisplay == .bitcoin {
                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack(spacing: 4) {
                        Image(type.imageAsset)
                            .font(.title3)
                            .padding(.trailing, 4)

                        SubtitleText(btcComponents.value)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(type.imageAsset)
                            .font(.title3)
                            .padding(.trailing, 4)

                        SubtitleText(converted.symbol)
                            .frame(maxWidth: 12)
                        SubtitleText(converted.formatted)
                    }
                }
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

        Spacer()

        // USD display
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
                vm.primaryDisplay = .fiat
                vm.selectedCurrency = "USD"
                vm.displayUnit = .modern
                return vm
            }()
        )

        Spacer()

        // EUR display
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
                vm.primaryDisplay = .fiat
                vm.selectedCurrency = "EUR"
                vm.displayUnit = .modern
                return vm
            }()
        )

        Spacer()

        // Bitcoin display with classic unit
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
                vm.displayUnit = .classic
                return vm
            }()
        )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .preferredColorScheme(.dark)
}
