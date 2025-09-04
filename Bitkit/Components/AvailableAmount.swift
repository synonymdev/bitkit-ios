import SwiftUI

struct AvailableAmount: View {
    let label: String
    let amount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(label)

            MoneyText(sats: amount, size: .bodySSB, symbol: true)
                .padding(.bottom, 5)
        }
    }
}
