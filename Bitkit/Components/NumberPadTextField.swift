import SwiftUI

// NumberPadTextField - Amount view to be used with number pad
struct NumberPadTextField: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @ObservedObject var viewModel: AmountInputViewModel

    var showConversion: Bool = true
    var isFocused: Bool = true

    private let springAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if currency.primaryDisplay == .bitcoin {
                if showConversion {
                    // Secondary display (fiat)
                    MoneyText(
                        sats: Int(viewModel.amountSats),
                        unitType: .secondary,
                        size: .caption,
                        symbol: true,
                        color: .textSecondary
                    )
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 1.5, anchor: .topLeading))
                    )
                }

                // Primary display (bitcoin)
                HStack {
                    primaryDisplayView
                    Spacer()
                }
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.5, anchor: .topLeading))
                )
            } else {
                if showConversion {
                    // Secondary display (bitcoin)
                    MoneyText(
                        sats: Int(viewModel.amountSats),
                        unitType: .secondary,
                        size: .caption,
                        symbol: true,
                        color: .textSecondary
                    )
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 1.5, anchor: .topLeading))
                    )
                }

                // Primary display (fiat)
                HStack {
                    primaryDisplayView
                    Spacer()
                }
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.5, anchor: .topLeading))
                )
            }
        }
        .contentShape(Rectangle())
        .animation(springAnimation, value: currency.primaryDisplay)
    }

    @ViewBuilder
    private var primaryDisplayView: some View {
        let font = Font.custom(Fonts.black, size: 44)
        let placeholder = viewModel.getPlaceholder(currency: currency)

        let valueText: Text = {
            if !viewModel.displayText.isEmpty {
                let entered = Text(viewModel.displayText)
                    .font(font)
                    .foregroundColor(.textPrimary)
                let remainder = Text(placeholder)
                    .font(font)
                    .foregroundColor(isFocused ? .textSecondary : .textPrimary)
                return entered + remainder
            } else {
                return Text(placeholder)
                    .font(font)
                    .foregroundColor(isFocused ? .textSecondary : .textPrimary)
            }
        }()

        HStack(spacing: 6) {
            // Symbol
            Text(currency.primaryDisplay == .bitcoin ? "₿" : currency.symbol)
                .font(.custom(Fonts.extraBold, size: 44))
                .foregroundColor(.textSecondary)

            // Value and placeholder
            valueText
        }
    }
}
