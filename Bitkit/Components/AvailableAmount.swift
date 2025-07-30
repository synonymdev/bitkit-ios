import SwiftUI

struct AvailableAmount: View {
    let label: String
    let amount: Int

    var body: some View {
        VStack(alignment: .leading) {
            CaptionMText(label)
                .padding(.bottom, 5)

            MoneyText(sats: amount, size: .bodySSB, symbol: true)
                .padding(.bottom, 5)
        }
    }
}
