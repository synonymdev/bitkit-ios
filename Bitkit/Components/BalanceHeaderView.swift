import SwiftUI

struct BalanceHeaderView: View {
    let sats: Int
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let converted = currency.convert(sats: UInt64(sats)) {
                if currency.primaryDisplay == .bitcoin {
                    HStack {
                        Text("\(converted.symbol) \(converted.formatted)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 1.5, anchor: .center))
                            .combined(with: .offset(x: 20, y: 0))
                    )

                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack {
                        Text(btcComponents.symbol)
                            .font(.largeTitle)
                            .bold()
                            .opacity(0.6)
                        Text(btcComponents.value)
                            .font(.largeTitle)
                            .bold()
                    }
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.5, anchor: .center))
                            .combined(with: .offset(x: -20, y: 0))
                    )
                } else {
                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack {
                        Text("\(btcComponents.symbol) \(btcComponents.value)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                    }
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 1.5, anchor: .center))
                            .combined(with: .offset(x: 20, y: 0))
                    )

                    HStack {
                        Text(converted.symbol)
                            .font(.largeTitle)
                            .bold()
                            .opacity(0.6)
                        Text(converted.formatted)
                            .font(.largeTitle)
                            .bold()
                    }
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.5, anchor: .center))
                            .combined(with: .offset(x: -20, y: 0))
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                currency.togglePrimaryDisplay()
            }
            Haptics.play(.medium)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currency.primaryDisplay)
    }
}
