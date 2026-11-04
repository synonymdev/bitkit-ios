import SwiftUI

struct PaykitAmountText: View {
    let amount: PaykitAmount
    var size: MoneySize = .bodyMSB
    var prefix = ""
    var color: Color = .textPrimary

    var displayValue: String {
        switch amount.asset {
        case .usd: usdDisplayAmount(amount.atomic)
        case .usdt: usdtExactAmount(amount.atomic)
        case .btc: amount.value
        }
    }

    var body: some View {
        if amount.asset == .btc {
            MoneyText(sats: Int(clamping: amount.atomic), size: size, symbol: true,
                      prefix: prefix, color: color, symbolColor: .textSecondary, fillsWidth: false)
        } else if size == .display {
            DisplayText("<accent>\(prefix)$</accent> " + displayValue, textColor: color,
                        accentColor: .textSecondary, accentFont: Fonts.extraBold, fillsWidth: false)
                .lineLimit(1).minimumScaleFactor(0.5)
        } else {
            BodyMSBText(prefix + "$" + displayValue, textColor: color)
        }
    }
}

func usdDisplayAmount(_ cents: UInt64, locale: Locale = .current) -> String {
    formatFiatAmount(Decimal(cents) / 100, locale: locale)
}
