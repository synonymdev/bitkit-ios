import BitkitCore
import SwiftUI

struct FeeItem: View {
    let speed: TransactionSpeed
    let amount: UInt64
    let isSelected: Bool
    let isDisabled: Bool
    /// When set (e.g. for custom speed with fee estimates), shown instead of `speed.range` as the subtitle.
    var rangeOverride: String?
    let onPress: () -> Void

    @EnvironmentObject var currency: CurrencyViewModel

    private var rangeText: String {
        rangeOverride ?? speed.range
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 16)

            Button(action: onPress) {
                HStack(spacing: 16) {
                    Image(speed.iconName)
                        .foregroundColor(isDisabled ? .gray : speed.iconColor)
                        .frame(width: 32, height: 32)

                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            BodyMSBText(speed.title, textColor: isDisabled ? .gray3 : .textPrimary)
                            BodySSBText(rangeText, textColor: isDisabled ? .gray3 : .textSecondary)
                        }

                        Spacer()

                        if amount > 0 {
                            VStack(alignment: .trailing, spacing: 0) {
                                MoneyText(
                                    sats: Int(amount),
                                    unitType: .primary,
                                    size: .bodyMSB,
                                    symbol: true,
                                    color: isDisabled ? .gray3 : .textPrimary
                                )

                                MoneyText(
                                    sats: Int(amount),
                                    unitType: .secondary,
                                    size: .bodySSB,
                                    symbol: true,
                                    color: isDisabled ? .gray3 : .textSecondary
                                )
                            }
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
