import SwiftUI

public struct FeeDisplayRow: View {
    let label: String
    let amount: UInt64

    @EnvironmentObject var currency: CurrencyViewModel

    private func formatAmount(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = " "
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    public var body: some View {
        VStack(alignment: .leading) {
            BodySText(label.uppercased(), textColor: .textSecondary)
                .padding(.bottom, 6)
            if let converted = currency.convert(sats: amount) {
                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                BodyMBoldText("\(btcComponents.symbol) \(formatAmount(amount))")
            }
            Divider()
        }
        .padding(.trailing, 8)
    }
    
    public init(label: String, amount: UInt64) {
        self.label = label
        self.amount = amount
    }
}

#Preview {
    FeeDisplayRow(label: "Amount", amount: 50000)
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
} 