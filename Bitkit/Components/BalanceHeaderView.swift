import SwiftUI

struct BalanceHeaderView: View {
    let sats: UInt64
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let converted = currency.convert(sats: sats) {
                if currency.primaryDisplay == .bitcoin {
                    HStack {
                        Text(converted.symbol)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                        Text(converted.formatted)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }

                    Text(converted.bitcoinDisplay(unit: currency.displayUnit)) // TODO: display unit separately to add opacity
                        .font(.largeTitle)
                        .bold()
                } else {
                    Text(converted.bitcoinDisplay(unit: currency.displayUnit))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
        }
    }
}
