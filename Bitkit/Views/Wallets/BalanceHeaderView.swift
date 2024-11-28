import SwiftUI

struct BalanceHeaderView: View {
    let sats: UInt64
    @EnvironmentObject var forex: ForexViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Main balance in sats
            Text("\(sats)")
                .font(.caption)
                .foregroundColor(.secondary)

            // Forex rate if available
            if let converted = forex.convert(sats: sats) {
                HStack(spacing: 4) {
                    Text(converted.formatted)
                        .font(.title)
                        .bold()
                }
                .opacity(forex.hasStaleData ? 0.5 : 1)
            }
        }
    }
}
