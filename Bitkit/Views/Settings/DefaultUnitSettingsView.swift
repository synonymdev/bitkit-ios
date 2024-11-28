import SwiftUI

struct DefaultUnitSettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        List {
            Section("Display Amounts In") {
                HStack {
                    Label("Bitcoin", systemImage: "bitcoinsign.circle")
                    Spacer()
                    if currency.primaryDisplay == .bitcoin {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    currency.primaryDisplay = .bitcoin
                }
                
                if let rate = currency.convert(sats: 1)?.currency {
                    HStack {
                        Label(rate, systemImage: "globe")
                        Spacer()
                        if currency.primaryDisplay == .fiat {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        currency.primaryDisplay = .fiat
                    }
                }
            }

            Section("Bitcoin Denomination") {
                ForEach(BitcoinDisplayUnit.allCases, id: \.self) { unit in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(unit.rawValue)
                            Text(unit == .modern ? "Display in satoshis" : "Display in bitcoin")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if currency.displayUnit == unit {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        currency.displayUnit = unit
                    }
                }
            }
        }
        .navigationTitle("Default Unit")
    }
}

// Helper for conditional modifiers
extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
} 