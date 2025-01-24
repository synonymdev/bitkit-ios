import SwiftUI

struct BalanceHeaderView: View {
    let sats: Int
    var sign: String? = nil
    var showBitcoinSymbol: Bool = true
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let converted = currency.convert(sats: UInt64(sats)) {
                if currency.primaryDisplay == .bitcoin {
                    HStack {
                        if let sign {
                            BodySText(sign, textColor: .textSecondary)
                        }
                        BodySText("\(converted.symbol) \(converted.formatted)", textColor: .textSecondary)
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
                        if let sign {
                            DisplayText(sign, textColor: .textPrimary.opacity(0.6))
                                .frame(maxWidth: 30)
                        }
                        if showBitcoinSymbol {
                            DisplayText(btcComponents.symbol, textColor: .textPrimary.opacity(0.6))
                                .frame(maxWidth: 30)
                        }
                        DisplayText(btcComponents.value)
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
                        if let sign {
                            BodySText(sign, textColor: .textSecondary)
                        }
                        BodySText("\(btcComponents.symbol) \(btcComponents.value)", textColor: .textSecondary)
                            .padding(.bottom, 4)
                    }
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 1.5, anchor: .center))
                            .combined(with: .offset(x: 20, y: 0))
                    )

                    HStack {
                        if let sign {
                            DisplayText(sign, textColor: .textPrimary.opacity(0.6))
                                .frame(maxWidth: 30)
                        }
                        DisplayText(converted.symbol, textColor: .textPrimary.opacity(0.6))
                            .frame(maxWidth: 30)
                        DisplayText(converted.formatted)
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

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            BalanceHeaderView(sats: 123456)
                .environmentObject({
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .bitcoin
                    return vm
                }())
            
            Spacer()

            BalanceHeaderView(sats: 123456)
                .environmentObject({
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .fiat
                    vm.selectedCurrency = "USD"
                    return vm
                }())

            Spacer()

            BalanceHeaderView(sats: 123456)
                .environmentObject({
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .fiat
                    vm.selectedCurrency = "EUR"
                    return vm
                }())

            Spacer()

            BalanceHeaderView(sats: 123456, sign: "+")
                .environmentObject({
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .bitcoin
                    return vm
                }())

            Spacer()

            BalanceHeaderView(sats: 123456, showBitcoinSymbol: false)
                .environmentObject({
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .bitcoin
                    return vm
                }())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
