import SwiftUI

struct BalanceHeaderView: View {
    let sats: UInt64
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let converted = currency.convert(sats: sats) {
                if currency.primaryDisplay == .bitcoin {
                    HStack {
                        Text("\(converted.symbol) \(converted.formatted)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }

                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack {
                        Text(btcComponents.symbol)
                            .font(.largeTitle)
                            .bold()
                            .opacity(0.6)
                        Text(btcComponents.value)
                            .font(.largeTitle)
                            .bold()
                    }
                } else {
                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack {
                        Text("\(btcComponents.symbol) \(btcComponents.value)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 4)

                    HStack {
                        Text(converted.symbol)
                            .font(.largeTitle)
                            .bold()
                            .opacity(0.6)
                        Text(converted.formatted)
                            .font(.largeTitle)
                            .bold()
                    }
                }
            }
        }
        .contentShape(Rectangle()) // Makes the entire VStack tappable
        .onTapGesture {
            currency.togglePrimaryDisplay()
            Haptics.play(.medium)
        }
    }
}
