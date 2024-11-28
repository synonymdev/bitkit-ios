import SwiftUI

struct DefaultUnitSettingsView: View {
    @EnvironmentObject var forex: ForexViewModel

    var body: some View {
        List {
            Section("Display Amounts In") {
                HStack {
                    Label("Bitcoin", systemImage: "bitcoinsign.circle")
                    Spacer()
                    if forex.primaryDisplay == .bitcoin {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    forex.primaryDisplay = .bitcoin
                }
                
                if let rate = forex.convert(sats: 1)?.currency {
                    HStack {
                        Label(rate, systemImage: "globe")
                        Spacer()
                        if forex.primaryDisplay == .fiat {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        forex.primaryDisplay = .fiat
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
                        if forex.displayUnit == unit {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        forex.displayUnit = unit
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