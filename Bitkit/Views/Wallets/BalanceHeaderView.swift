import SwiftUI

struct BalanceHeaderView: View {
    let sats: UInt64
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let converted = currency.convert(sats: sats) {
                if currency.primaryDisplay == .bitcoin {
                    Text(converted.formatted)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    Text(converted.bitcoinDisplay(unit: currency.displayUnit))
                        .font(.largeTitle)
                        .bold()
                } else {
                    Text(converted.bitcoinDisplay(unit: currency.displayUnit))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    Text(converted.formatted)
                        .font(.largeTitle)
                        .bold()
                }
            }
        }
        .contentShape(Rectangle()) // Makes the entire VStack tappable
        .onTapGesture {
            currency.togglePrimaryDisplay()
        }
    }
}
