import SwiftUI

struct AvailableAmount: View {
    let label: String
    let amount: Int
    var testIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(label)
            MoneyText(
                sats: amount,
                size: .bodySSB,
                symbol: true,
                testIdentifier: testIdentifier != nil ? "MoneyText" : nil
            )
            .padding(.bottom, 5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(testIdentifier ?? "")
    }
}
