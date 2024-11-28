import SwiftUI

struct BalanceHeaderView: View {
    let sats: UInt64
    @EnvironmentObject var forex: ForexViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let converted = forex.convert(sats: sats) {
                if forex.primaryDisplay == .bitcoin {
                    Text(converted.formatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .opacity(forex.hasStaleData ? 0.5 : 1)
                    
                    Text(converted.bitcoinDisplay(unit: forex.displayUnit))
                        .font(.title)
                        .bold()
                } else {
                    Text(converted.bitcoinDisplay(unit: forex.displayUnit))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(converted.formatted)
                        .font(.title)
                        .bold()
                }
            }
        }
        .contentShape(Rectangle())  // Makes the entire VStack tappable
        .onTapGesture {
            forex.togglePrimaryDisplay()
        }
    }
}
