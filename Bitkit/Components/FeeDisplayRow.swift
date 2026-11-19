import SwiftUI

struct FeeDisplayRow: View {
    let label: String
    let amount: UInt64
    /// Shimmers the amount while it is being priced.
    var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(label)
                .padding(.bottom, 8)
            MoneyText(sats: Int(amount), size: .bodySSB, symbol: true, shimmer: isLoading)
                .padding(.bottom, 16)
            Divider()
        }
        .padding(.trailing, 8)
    }
}

#Preview {
    FeeDisplayRow(label: "Amount", amount: 50000)
        .preferredColorScheme(.dark)
}
