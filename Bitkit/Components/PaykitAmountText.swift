import SwiftUI

struct PaykitAmountText: View {
    let amount: PaykitAmount
    var size: MoneySize = .bodyMSB
    var prefix = ""
    var color: Color = .textPrimary

    private var displayValue: String {
        switch amount.asset {
        case .usd: usdDisplayAmount(amount.atomic)
        case .usdt: usdtOverviewAmount(amount.atomic)
        case .btc: amount.value
        }
    }

    var body: some View {
        if amount.asset == .btc {
            MoneyText(sats: Int(clamping: amount.atomic), size: size, symbol: true,
                      prefix: prefix, color: color, symbolColor: .textSecondary, fillsWidth: false)
        } else if size == .display {
            NumberPadAmountText(value: prefix + displayValue, symbol: "$")
        } else {
            BodyMSBText(prefix + "$" + displayValue, textColor: color)
        }
    }
}

func usdDisplayAmount(_ cents: UInt64, locale: Locale = .current) -> String {
    (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(2)).locale(locale))
}
