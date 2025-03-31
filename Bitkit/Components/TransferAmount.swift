import SwiftUI

struct TransferAmount: View {
    @State private var satsAmount: String
    @State private var fiatAmount: String
    @Binding var primaryDisplay: PrimaryDisplay
    @Binding var overrideSats: UInt64?
    @FocusState private var isSatsFocused: Bool
    @FocusState private var isFiatFocused: Bool
    @EnvironmentObject var currency: CurrencyViewModel
    var onSatsChange: (UInt64) -> Void

    init(
        defaultValue: UInt64 = 0, primaryDisplay: Binding<PrimaryDisplay>, overrideSats: Binding<UInt64?> = .constant(nil),
        onSatsChange: @escaping (UInt64) -> Void
    ) {
        _satsAmount = State(initialValue: defaultValue > 0 ? String(defaultValue) : "")
        _fiatAmount = State(initialValue: primaryDisplay.wrappedValue == .fiat ? "0" : "")
        _primaryDisplay = primaryDisplay
        _overrideSats = overrideSats
        self.onSatsChange = onSatsChange
    }

    private var sats: UInt64 {
        return !satsAmount.isEmpty ? UInt64(satsAmount) ?? 0 : 0
    }

    var body: some View {
        ZStack {
            // Hidden Bitcoin TextField
            TextField("0", text: $satsAmount)
                .keyboardType(.decimalPad)
                .focused($isSatsFocused)
                .opacity(0)
                .onChange(of: satsAmount) { newValue in
                    if primaryDisplay == .bitcoin {
                        let filtered = {
                            if currency.displayUnit == .modern {
                                newValue.filter { "0123456789".contains($0) }
                            } else {
                                newValue.filter { "0123456789.".contains($0) }
                            }
                        }()

                        // Limit to 8 decimal places for classic
                        if currency.displayUnit == .classic {
                            let components = filtered.components(separatedBy: ".")
                            if components.count == 2 && components[1].count > 8 {
                                satsAmount = components[0] + "." + components[1].prefix(8)
                            } else {
                                satsAmount = filtered
                            }
                        } else {
                            satsAmount = filtered
                        }

                        satsAmount = filtered
                        onSatsChange(sats)

                        // Update fiat amount
                        if let converted = currency.convert(sats: sats) {
                            fiatAmount = converted.formatted
                        }
                    }
                }

            // Hidden Fiat TextField
            TextField("0", text: $fiatAmount)
                .keyboardType(.decimalPad)
                .focused($isFiatFocused)
                .opacity(0)
                .onChange(of: fiatAmount) { newValue in
                    if primaryDisplay == .fiat {
                        // Allow one decimal point for fiat
                        let filtered = newValue.filter { "0123456789.".contains($0) }
                        if filtered.components(separatedBy: ".").count > 2 {
                            fiatAmount = String(filtered.prefix(filtered.count - 1))
                        } else {
                            // Limit to 2 decimal places for fiat
                            let components = filtered.components(separatedBy: ".")
                            if components.count == 2 && components[1].count > 2 {
                                fiatAmount = components[0] + "." + components[1].prefix(2)
                            } else {
                                fiatAmount = filtered
                            }
                        }

                        // Only convert if we have a valid number
                        if !fiatAmount.isEmpty, let fiatDouble = Double(fiatAmount),
                            let convertedSats = currency.convert(fiatAmount: fiatDouble)
                        {
                            satsAmount = String(convertedSats)
                            onSatsChange(convertedSats)
                        } else {
                            satsAmount = ""
                            onSatsChange(0)
                        }
                    }
                }

            // Visible balance display
            if let converted = currency.convert(sats: sats) {
                if primaryDisplay == .bitcoin {
                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    DisplayText("<accent>\(btcComponents.symbol)</accent> \(btcComponents.value)", accentColor: .textSecondary)
                } else {
                    DisplayText("<accent>\(converted.symbol)</accent> \(fiatAmount.isEmpty ? "0" : fiatAmount)", accentColor: .textSecondary)
                }
            }
        }
        .onChange(of: overrideSats) { newValue in
            if let exactSats = newValue {
                satsAmount = String(exactSats)
                onSatsChange(exactSats)

                // Update fiat amount if needed
                if let converted = currency.convert(sats: exactSats) {
                    fiatAmount = converted.formatted
                }
            }
        }
        .onChange(of: primaryDisplay) { newDisplay in
            if newDisplay == .bitcoin {
                isSatsFocused = true
            } else {
                isFiatFocused = true
                // Reset fiat amount to empty string if sats are 0
                if sats == 0 {
                    fiatAmount = ""
                }
            }
        }
        .onAppear {
            if primaryDisplay == .bitcoin {
                isSatsFocused = true
            } else {
                isFiatFocused = true
            }
            // Initialize fiat amount if we have a default sats value
            if sats > 0, let converted = currency.convert(sats: sats) {
                fiatAmount = converted.formatted
            }
        }
        .onTapGesture {
            if primaryDisplay == .bitcoin {
                isSatsFocused = true
            } else {
                isFiatFocused = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        TransferAmount(primaryDisplay: .constant(.bitcoin)) { _ in }
            .environmentObject(
                {
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .bitcoin
                    vm.displayUnit = .modern
                    return vm
                }())

        TransferAmount(primaryDisplay: .constant(.fiat)) { _ in }
            .environmentObject(
                {
                    let vm = CurrencyViewModel()
                    vm.primaryDisplay = .fiat
                    vm.selectedCurrency = "USD"
                    return vm
                }())
    }
    .padding()
    .preferredColorScheme(.dark)
}
