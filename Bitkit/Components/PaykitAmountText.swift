import SwiftUI

struct PaykitAmountText: View {
    let amount: PaykitAmount
    var size: MoneySize = .bodyMSB
    var prefix = ""
    var color: Color = .textPrimary

    var body: some View {
        if amount.asset == .btc {
            MoneyText(sats: Int(clamping: amount.atomic), size: size, symbol: true,
                      prefix: prefix, color: color, symbolColor: .textSecondary, fillsWidth: false)
        } else if size == .display {
            NumberPadAmountText(value: prefix + amount.value, symbol: "$")
        } else {
            BodyMSBText(prefix + "$" + amount.value, textColor: color)
        }
    }
}
