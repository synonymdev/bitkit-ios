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
                            BodySText("<accent>\(sign)</accent>", textColor: .textSecondary, accentColor: .textSecondary)
                        }
                        BodySText(
                            "<accent>\(converted.symbol)</accent> \(converted.formatted)", textColor: .textSecondary, accentColor: .textSecondary
                        )
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
                            DisplayText("<accent>\(sign)</accent> \(btcComponents.value)", accentColor: .textSecondary)
                        } else {
                            DisplayText(
                                "\(showBitcoinSymbol ? "<accent>\(btcComponents.symbol)</accent> " : "")\(btcComponents.value)",
                                accentColor: .textSecondary)
                        }
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
                            BodySText("<accent>\(sign)</accent>", textColor: .textSecondary, accentColor: .textSecondary)
                        }
                        BodySText(
                            "<accent>\(btcComponents.symbol)</accent> \(btcComponents.value)", textColor: .textSecondary, accentColor: .textSecondary
                        )
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
                            DisplayText("<accent>\(sign) \(converted.symbol)</accent> \(converted.formatted)", accentColor: .textSecondary)
                        } else {
                            DisplayText("<accent>\(converted.symbol)</accent> \(converted.formatted)", accentColor: .textSecondary)
                        }
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
            BalanceHeaderView(sats: 123_456)
                .environmentObject(
                    {
                        let vm = CurrencyViewModel()
                        vm.primaryDisplay = .bitcoin
                        vm.displayUnit = .modern
                        vm.selectedCurrency = "ZAR"
                        return vm
                    }())

            Spacer()

            BalanceHeaderView(sats: 123_456)
                .environmentObject(
                    {
                        let vm = CurrencyViewModel()
                        vm.primaryDisplay = .fiat
                        vm.selectedCurrency = "USD"
                        vm.displayUnit = .modern
                        return vm
                    }())

            Spacer()

            BalanceHeaderView(sats: 123_456)
                .environmentObject(
                    {
                        let vm = CurrencyViewModel()
                        vm.primaryDisplay = .fiat
                        vm.selectedCurrency = "EUR"
                        vm.displayUnit = .modern
                        return vm
                    }())

            Spacer()

            BalanceHeaderView(sats: 123_456, sign: "+")
                .environmentObject(
                    {
                        let vm = CurrencyViewModel()
                        vm.primaryDisplay = .bitcoin
                        vm.displayUnit = .modern
                        vm.selectedCurrency = "CHF"
                        return vm
                    }())

            Spacer()

            BalanceHeaderView(sats: 123_456, showBitcoinSymbol: false)
                .environmentObject(
                    {
                        let vm = CurrencyViewModel()
                        vm.primaryDisplay = .fiat
                        vm.displayUnit = .classic
                        vm.selectedCurrency = "BHD"
                        return vm
                    }())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
