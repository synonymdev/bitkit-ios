import BitkitCore
import SwiftUI

struct FeeItem: View {
    let title: String
    let subtitle: String
    let iconName: String
    let iconColor: Color
    let amount: UInt64
    /// Shown before the amount when it is a bound or an estimate ("up to", "≈").
    var amountPrefix: String?
    let isSelected: Bool
    let isDisabled: Bool
    let onPress: () -> Void

    @EnvironmentObject var currency: CurrencyViewModel

    /// - Parameter rangeOverride: When set (e.g. for custom speed with fee estimates), shown instead of `speed.range`.
    init(
        speed: TransactionSpeed,
        amount: UInt64,
        isSelected: Bool,
        isDisabled: Bool,
        rangeOverride: String? = nil,
        onPress: @escaping () -> Void
    ) {
        self.init(
            title: speed.title,
            subtitle: rangeOverride ?? speed.range,
            iconName: speed.iconName,
            iconColor: speed.iconColor,
            amount: amount,
            isSelected: isSelected,
            isDisabled: isDisabled,
            onPress: onPress
        )
    }

    init(
        title: String,
        subtitle: String,
        iconName: String,
        iconColor: Color,
        amount: UInt64,
        amountPrefix: String? = nil,
        isSelected: Bool,
        isDisabled: Bool,
        onPress: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.iconColor = iconColor
        self.amount = amount
        self.amountPrefix = amountPrefix
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.onPress = onPress
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 16)

            Button(action: onPress) {
                HStack(spacing: 16) {
                    Image(iconName)
                        .foregroundColor(isDisabled ? .gray : iconColor)
                        .frame(width: 32, height: 32)

                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            BodyMSBText(title, textColor: isDisabled ? .gray3 : .textPrimary)
                            BodySSBText(subtitle, textColor: isDisabled ? .gray3 : .textSecondary)
                        }

                        Spacer()

                        if amount > 0 {
                            FeeItemAmount(amount: amount, prefix: amountPrefix, isDisabled: isDisabled)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 90)
                .background(
                    Rectangle()
                        .fill(isSelected ? Color.white06 : Color.clear)
                )
            }
            .disabled(isDisabled)
            .buttonStyle(PlainButtonStyle())
        }
    }
}

/// The fee in both units, kept whole beside a long subtitle.
struct FeeItemAmount: View {
    let amount: UInt64
    var prefix: String?
    var isDisabled = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            MoneyText(
                sats: Int(amount),
                unitType: .primary,
                size: .bodyMSB,
                symbol: true,
                prefix: prefix,
                color: isDisabled ? .gray3 : .textPrimary
            )

            MoneyText(
                sats: Int(amount),
                unitType: .secondary,
                size: .bodySSB,
                symbol: true,
                prefix: prefix,
                color: isDisabled ? .gray3 : .textSecondary
            )
        }
        .fixedSize()
    }
}
