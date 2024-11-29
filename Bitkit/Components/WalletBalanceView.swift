import SwiftUI

struct WalletBalanceView: View {
    let title: String
    let sats: UInt64
    let icon: String
    let iconColor: Color
    
    @EnvironmentObject var currency: CurrencyViewModel
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .padding(.bottom, 4)
            
            if let converted = currency.convert(sats: sats) {
                if currency.primaryDisplay == .bitcoin {
                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundColor(iconColor)
                            .padding(.trailing, 4)
                        Text(btcComponents.value)
                    }
                    .font(.title3)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundColor(iconColor)
                            .padding(.trailing, 4)
                        Text(converted.symbol)
                            .opacity(0.6)
                        Text(converted.formatted)
                    }
                    .font(.title3)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
} 