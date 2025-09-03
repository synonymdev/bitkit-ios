import SwiftUI

// NumberPadTextField - Amount view to be used with number pad
struct NumberPadTextField: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @ObservedObject var viewModel: AmountInputViewModel
    var isFocused: Bool = false

    private let springAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if currency.primaryDisplay == .bitcoin {
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
        HStack(spacing: 6) {
            // Symbol
            Text(currency.primaryDisplay == .bitcoin ? "₿" : currency.symbol)
                .font(.custom(Fonts.extraBold, size: 44))
                .foregroundColor(.textSecondary)

            // Value and placeholder
            HStack(spacing: 0) {
                if !viewModel.displayText.isEmpty {
                    Text(viewModel.displayText)
                        .font(.custom(Fonts.black, size: 44))
                        .foregroundColor(.textPrimary)
                }

                Text(viewModel.getPlaceholder(currency: currency))
                    .font(.custom(Fonts.black, size: 44))
                    .foregroundColor(isFocused ? .textSecondary : .textPrimary)
            }
        }
    }
}
